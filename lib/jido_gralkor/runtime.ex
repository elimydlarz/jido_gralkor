defmodule JidoGralkor.Runtime do
  @moduledoc false

  use GenServer

  alias Gralkor.Destination
  alias Gralkor.Destination.Storage, as: DestinationStorage
  alias Gralkor.Lens
  alias Gralkor.Reflection
  alias Gralkor.Reflection.ChainOfThought
  alias Gralkor.Reflection.Runner

  @reflection_retry_deadline_ms 86_400_000
  @maximum_reflection_backoff_ms 3_600_000

  def start_link(opts) do
    owner = Keyword.fetch!(opts, :owner)
    GenServer.start_link(__MODULE__, opts, name: via(owner))
  end

  def snapshot(owner) do
    ensure_started(owner)
    GenServer.call(via(owner), :snapshot)
  end

  def replace(owner, configuration) do
    ensure_started(owner)
    GenServer.call(via(owner), {:replace, configuration})
  end

  def destination!(owner, name), do: fetch_definition!(owner, :destinations, name)
  def lens!(owner, name), do: fetch_definition!(owner, :lenses, name)
  def reflection!(owner, name), do: fetch_definition!(owner, :reflections, name)

  def destinations(owner) do
    ensure_started(owner)
    GenServer.call(via(owner), {:all, :destinations})
  end

  def submit_reflection(owner, name, invocation, callback, opts) do
    ensure_started(owner)
    GenServer.call(via(owner), {:submit_reflection, name, invocation, callback, opts})
  end

  def validate(configuration) do
    with :ok <- validate_configuration(configuration),
         {:ok, _definitions} <- resolve_configuration(configuration) do
      :ok
    end
  end

  @impl GenServer
  def init(opts) do
    configuration = Keyword.fetch!(opts, :configuration)

    with :ok <- validate_configuration(configuration),
         {:ok, definitions} <- resolve_configuration(configuration) do
      {:ok, reflection_supervisor} = Task.Supervisor.start_link()

      {:ok,
       %{
         owner: Keyword.fetch!(opts, :owner),
         configuration: configuration,
         definitions: definitions,
         reflection_supervisor: reflection_supervisor
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, state.configuration, state}

  def handle_call({:replace, configuration}, _from, state) do
    with :ok <- validate_configuration(configuration),
         {:ok, definitions} <- resolve_configuration(configuration) do
      {:reply, :ok, %{state | configuration: configuration, definitions: definitions}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fetch, collection, name}, _from, state) do
    reply =
      case get_in(state.definitions, [collection, name]) do
        nil -> {:error, {:unknown_definition, collection, name}}
        definition -> {:ok, definition}
      end

    {:reply, reply, state}
  end

  def handle_call({:all, :destinations}, _from, state) do
    {:reply, state.definitions.destination_list, state}
  end

  def handle_call({:submit_reflection, name, invocation, callback, opts}, _from, state) do
    reply =
      with :ok <- validate_invocation_callback(callback),
           {:ok, invocation_id} <- invocation_id(invocation),
           {:ok, reflection} <- Map.fetch(state.definitions.reflections, name),
           {:ok, _task} <-
             Task.Supervisor.start_child(state.reflection_supervisor, fn ->
               process_reflection(reflection, invocation, callback, opts)
             end) do
        {:ok, invocation_id}
      else
        :error -> {:error, {:unknown_definition, :reflections, name}}
        {:error, _reason} = error -> error
      end

    {:reply, reply, state}
  end

  defp ensure_started(owner) do
    case :global.whereis_name({__MODULE__, owner}) do
      :undefined ->
        {:ok, _state} = Jido.AgentServer.state(owner)
        :ok

      _pid ->
        :ok
    end
  end

  defp validate_configuration(configuration) when is_map(configuration) do
    Enum.reduce_while([:destinations, :lenses, :reflections], :ok, fn collection, :ok ->
      case Map.fetch(configuration, collection) do
        {:ok, definitions} when is_list(definitions) ->
          {:cont, :ok}

        {:ok, invalid} ->
          {:halt, {:error, {:invalid_collection, collection, invalid}}}

        :error ->
          {:halt, {:error, {:missing_collection, collection}}}
      end
    end)
  end

  defp validate_configuration(configuration),
    do: {:error, {:invalid_configuration, configuration}}

  defp resolve_configuration(configuration) do
    with :ok <- validate_definition_fields(configuration),
         :ok <- validate_reserved_names(configuration),
         :ok <- validate_lens_shapes(configuration.lenses),
         :ok <- validate_reserved_entity_kinds(configuration) do
      destinations =
        [%Destination{name: "operator"}, %Destination{name: "global"}] ++
          Enum.map(configuration.destinations, fn definition ->
            %Destination{name: field(definition, :name)}
          end)

      destination_index = Map.new(destinations, &{&1.name, &1})

      lenses =
        [
          %Lens{
            name: "operator",
            destination: Map.fetch!(destination_index, "operator"),
            ontology: Gralkor.DefaultOntology,
            ingestion: Gralkor.Lens.Ingestion.Store
          }
        ] ++
          Enum.map(configuration.lenses, fn definition ->
            case field(definition, :write) do
              :replace_graph ->
                %Gralkor.Lens.Replaceable{
                  name: field(definition, :name),
                  destination: Map.fetch!(destination_index, field(definition, :destination))
                }

              _ ->
                %Lens{
                  name: field(definition, :name),
                  destination: Map.fetch!(destination_index, field(definition, :destination)),
                  ontology: field(definition, :ontology) || Gralkor.DefaultOntology,
                  ingestion: field(definition, :ingestion)
                }
            end
          end)

      reflections =
        Enum.map(
          Gralkor.Reflection.Packaged.definitions() ++ configuration.reflections,
          fn definition ->
            {:ok, chain_of_thought} =
              ChainOfThought.from_config(field(definition, :chain_of_thought))

            outputs =
              Enum.map(field(definition, :outputs), fn output ->
                %{
                  kind: :destination,
                  destination: Map.fetch!(destination_index, field(output, :destination)),
                  ontology: field(output, :ontology) || Gralkor.DefaultOntology
                }
              end)

            %Reflection{
              name: field(definition, :name),
              outputs: outputs,
              chain_of_thought: chain_of_thought
            }
          end
        )

      {:ok,
       %{
         destinations: Map.new(destinations, &{&1.name, &1}),
         destination_list: destinations,
         lenses: Map.new(lenses, &{&1.name, &1}),
         reflections: Map.new(reflections, &{&1.name, &1})
       }}
    end
  rescue
    error ->
      {:error, {:invalid_runtime_configuration, Exception.message(error)}}
  end

  defp validate_definition_fields(configuration) do
    allowed = %{
      destinations: [:name],
      lenses: [:name, :destination, :write, :ingestion, :ontology],
      reflections: [:name, :outputs, :chain_of_thought]
    }

    Enum.reduce_while(allowed, :ok, fn {collection, fields}, :ok ->
      case Enum.find_value(Map.fetch!(configuration, collection), fn definition ->
             case definition_keys(definition) do
               {:ok, keys} ->
                 case Enum.reject(keys, &known_field?(&1, fields)) do
                   [] ->
                     nil

                   unknown ->
                     {:unknown_definition_fields, collection, field(definition, :name), unknown}
                 end

               :error ->
                 {:invalid_definition, collection, definition}
             end
           end) do
        nil -> {:cont, :ok}
        reason -> {:halt, {:error, reason}}
      end
    end)
  end

  defp definition_keys(definition) when is_map(definition), do: {:ok, Map.keys(definition)}

  defp definition_keys(definition) when is_list(definition) do
    if Keyword.keyword?(definition), do: {:ok, Keyword.keys(definition)}, else: :error
  end

  defp definition_keys(_definition), do: :error

  defp known_field?(key, fields) when is_atom(key), do: key in fields

  defp known_field?(key, fields) when is_binary(key),
    do: key in Enum.map(fields, &Atom.to_string/1)

  defp known_field?(_key, _fields), do: false

  defp validate_reserved_names(configuration) do
    packaged = %{
      destinations: ["operator", "global"],
      lenses: ["operator"],
      reflections: Enum.map(Gralkor.Reflection.Packaged.definitions(), &field(&1, :name))
    }

    Enum.reduce_while(packaged, :ok, fn {collection, reserved}, :ok ->
      case Enum.find(Map.fetch!(configuration, collection), &(field(&1, :name) in reserved)) do
        nil ->
          {:cont, :ok}

        definition ->
          {:halt, {:error, {:reserved_definition_name, collection, field(definition, :name)}}}
      end
    end)
  end

  defp validate_lens_shapes(lenses) do
    case Enum.find(lenses, fn definition ->
           field(definition, :write) == :replace_graph and
             (has_field?(definition, :ingestion) or has_field?(definition, :ontology))
         end) do
      nil -> :ok
      definition -> {:error, {:incompatible_lens_definition, field(definition, :name)}}
    end
  end

  defp validate_reserved_entity_kinds(configuration) do
    lens_ontologies =
      Enum.map(configuration.lenses, &(field(&1, :ontology) || Gralkor.DefaultOntology))

    reflection_ontologies =
      Enum.flat_map(configuration.reflections, fn reflection ->
        case field(reflection, :outputs) do
          outputs when is_list(outputs) ->
            Enum.map(outputs, &(field(&1, :ontology) || Gralkor.DefaultOntology))

          _ ->
            []
        end
      end)

    Enum.reduce_while(lens_ontologies ++ reflection_ontologies, :ok, fn ontology, :ok ->
      case reserved_entity_kind(ontology) do
        nil -> {:cont, :ok}
        kind -> {:halt, {:error, {:reserved_entity_kind, kind}}}
      end
    end)
  end

  defp reserved_entity_kind(ontology)
       when is_atom(ontology) do
    if Code.ensure_loaded?(ontology) and function_exported?(ontology, :__ontology__, 0) do
      ontology.__ontology__()
      |> Map.get(:entity_types, [])
      |> Enum.find_value(fn
        %{name: name} when name in ["Entity", "Episodic", "Community"] -> name
        _ -> nil
      end)
    end
  end

  defp reserved_entity_kind(_ontology), do: nil

  defp fetch_definition!(owner, collection, name) do
    ensure_started(owner)

    case GenServer.call(via(owner), {:fetch, collection, name}) do
      {:ok, definition} -> definition
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  defp validate_invocation_callback(callback) when is_function(callback, 1), do: :ok

  defp validate_invocation_callback(callback),
    do: {:error, {:invalid_invocation_callback, callback}}

  defp invocation_id(invocation) when is_map(invocation) do
    case field(invocation, :id) do
      id when is_binary(id) ->
        if String.trim(id) == "",
          do: {:error, {:invalid_invocation_id, id}},
          else: {:ok, id}

      id ->
        {:error, {:invalid_invocation_id, id}}
    end
  end

  defp invocation_id(invocation), do: {:error, {:invalid_invocation, invocation}}

  defp process_reflection(reflection, invocation, callback, opts) do
    production = fn -> Runner.run(reflection, invocation, opts) end

    case retry(production, &match?({:ok, _artefact}, &1), opts) do
      {:ok, {:ok, artefact}} ->
        output = Enum.find(reflection.outputs, &(&1.kind == :destination))

        delivery = fn ->
          DestinationStorage.put_artefact(
            output,
            reflection.name,
            field(invocation, :operator_id),
            artefact,
            opts
          )
        end

        case retry(delivery, &(&1 == :ok), opts) do
          {:ok, :ok} ->
            callback.(%{
              invocation_id: field(invocation, :id),
              artefact: artefact,
              outcome: :delivered
            })

          {:abandoned, {:error, reason}} ->
            callback.(%{
              invocation_id: field(invocation, :id),
              artefact: artefact,
              outcome: {:abandoned, %{stage: :delivery, reason: reason}}
            })
        end

      {:abandoned, {:error, failure}} ->
        outcome =
          if retryable_server_failure?({:error, failure}) do
            {:abandoned, %{stage: :production, reason: failure}}
          else
            {:production_failed, failure}
          end

        callback.(%{
          invocation_id: field(invocation, :id),
          outcome: outcome
        })
    end
  end

  defp retry(operation, success?, opts) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    started_at = clock.()
    retry(operation, success?, opts, clock, started_at, 1_000)
  end

  defp retry(operation, success?, opts, clock, started_at, delay) do
    result = operation.()

    cond do
      success?.(result) ->
        {:ok, result}

      retryable_server_failure?(result) and
          clock.() - started_at + delay <
            Keyword.get(opts, :retry_deadline_ms, @reflection_retry_deadline_ms) ->
        sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
        sleep.(delay)

        retry(
          operation,
          success?,
          opts,
          clock,
          started_at,
          min(delay * 2, @maximum_reflection_backoff_ms)
        )

      true ->
        {:abandoned, result}
    end
  end

  defp retryable_server_failure?({:error, reason}), do: server_status(reason) in 500..599
  defp retryable_server_failure?(_result), do: false

  defp server_status(%{status: status}), do: normalize_status(status)
  defp server_status(%{"status" => status}), do: normalize_status(status)

  defp server_status(value) when is_map(value),
    do: value |> Map.values() |> Enum.find_value(&server_status/1)

  defp server_status(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.find_value(&server_status/1)
  end

  defp server_status(value) when is_list(value), do: Enum.find_value(value, &server_status/1)
  defp server_status(_value), do: nil

  defp normalize_status(status) when is_integer(status), do: status

  defp normalize_status(status) when is_binary(status) do
    case Integer.parse(status) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp normalize_status(_status), do: nil

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(keyword, key) when is_list(keyword), do: Keyword.get(keyword, key)
  defp field(_, _), do: nil

  defp has_field?(map, key) when is_map(map),
    do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp has_field?(keyword, key) when is_list(keyword), do: Keyword.has_key?(keyword, key)

  defp via(owner), do: {:global, {__MODULE__, owner}}
end
