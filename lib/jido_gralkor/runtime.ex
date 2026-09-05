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
    call!(owner, :snapshot)
  end

  def replace(owner, configuration) do
    call!(owner, {:replace, configuration})
  end

  def destination!(owner, name), do: fetch_definition!(owner, :destinations, name)
  def lens!(owner, name), do: fetch_definition!(owner, :lenses, name)
  def reflection!(owner, name), do: fetch_definition!(owner, :reflections, name)

  def destinations(owner) do
    call!(owner, {:all, :destinations})
  end

  def lenses!(owner, names), do: fetch_definitions!(owner, :lenses, names)

  def resolve_search!(owner, lens_names, destination_names) do
    case call!(owner, {:resolve_search, lens_names, destination_names}) do
      {:ok, resolved} -> resolved
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  def ensure_available!(owner) do
    _runtime = runtime_pid!(owner)
    owner
  end

  def started?(owner) when is_pid(owner),
    do: :global.whereis_name({__MODULE__, owner}) != :undefined

  def started?(_owner), do: false

  def submit_reflection(owner, name, invocation, callback, opts) do
    call!(owner, {:submit_reflection, name, invocation, callback, opts})
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

  def handle_call({:fetch_many, collection, names}, _from, state) do
    {:reply, fetch_definitions(Map.fetch!(state.definitions, collection), collection, names), state}
  end

  def handle_call({:all, :destinations}, _from, state) do
    {:reply, state.definitions.destination_list, state}
  end

  def handle_call({:resolve_search, lens_names, destination_names}, _from, state) do
    reply =
      with {:ok, lenses} <- fetch_definitions(state.definitions.lenses, :lenses, lens_names),
           {:ok, destinations} <-
             resolve_search_destinations(state.definitions, destination_names) do
        {:ok, {lenses, destinations}}
      end

    {:reply, reply, state}
  end

  def handle_call({:submit_reflection, name, invocation, callback, opts}, _from, state) do
    reply =
      with :ok <- validate_invocation_callback(callback),
           {:ok, invocation_id} <- invocation_id(invocation),
           :ok <- validate_operator_id(invocation),
           {:ok, reflection} <- Map.fetch(state.definitions.reflections, name),
           {:ok, _task} <-
             Task.Supervisor.start_child(state.reflection_supervisor, fn ->
               process_reflection(reflection, invocation, callback, opts, state.owner)
             end) do
        {:ok, invocation_id}
      else
        :error -> {:error, {:unknown_definition, :reflections, name}}
        {:error, _reason} = error -> error
      end

    {:reply, reply, state}
  end

  defp validate_configuration(configuration) when is_map(configuration) do
    collections = [:destinations, :lenses, :reflections]
    unknown = Map.keys(configuration) -- collections

    if unknown != [] do
      {:error, {:unknown_configuration_fields, unknown}}
    else
      Enum.reduce_while(collections, :ok, fn collection, :ok ->
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
  end

  defp validate_configuration(configuration),
    do: {:error, {:invalid_configuration, configuration}}

  defp resolve_configuration(configuration) do
    with :ok <- validate_definition_fields(configuration),
         :ok <- validate_definition_names(configuration),
         :ok <- validate_reserved_names(configuration),
         :ok <- validate_lens_shapes(configuration.lenses),
         :ok <- validate_reflection_shapes(configuration.reflections),
         :ok <- validate_destination_references(configuration),
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
                  ontology: ontology(definition),
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
                  ontology: ontology(output)
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
      lenses: ["operator", "global"],
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

  defp validate_definition_names(configuration) do
    Enum.reduce_while([:destinations, :lenses, :reflections], :ok, fn collection, :ok ->
      names = Enum.map(Map.fetch!(configuration, collection), &field(&1, :name))

      reserved_destination =
        if collection == :destinations,
          do: Enum.find(names, &(is_binary(&1) and String.starts_with?(&1, "operator/")))

      reserved_provenance =
        if collection in [:lenses, :reflections],
          do: Enum.find(names, &(is_binary(&1) and String.contains?(&1, " [lens: ")))

      cond do
        blank = Enum.find(names, &(not non_blank?(&1))) ->
          {:halt, {:error, {:blank_definition_name, collection, blank}}}

        duplicate = duplicate(names) ->
          {:halt, {:error, {:duplicate_definition_name, collection, duplicate}}}

        reserved_destination ->
          {:halt, {:error, {:reserved_destination_namespace, reserved_destination}}}

        collection == :lenses and "default" in names ->
          {:halt, {:error, {:retired_definition_name, :lenses, "default", "operator"}}}

        reserved_provenance ->
          {:halt, {:error, {:reserved_provenance_syntax, collection, reserved_provenance}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_lens_shapes(lenses) do
    Enum.reduce_while(lenses, :ok, fn definition, :ok ->
      name = field(definition, :name)

      result =
        case field(definition, :write) do
          :append ->
            ingestion = field(definition, :ingestion)
            ontology = ontology(definition)

            cond do
              not valid_ingestion?(ingestion) ->
                {:error, {:invalid_lens_ingestion, name, ingestion}}

              not valid_ontology?(ontology) ->
                {:error, {:invalid_lens_ontology, name, ontology}}

              true ->
                :ok
            end

          :replace_graph ->
            if has_field?(definition, :ingestion) or has_field?(definition, :ontology),
              do: {:error, {:incompatible_lens_definition, name}},
              else: :ok

          write ->
            {:error, {:invalid_lens_write, name, write}}
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp valid_ingestion?(ingestion),
    do:
      is_atom(ingestion) and Code.ensure_loaded?(ingestion) and
        function_exported?(ingestion, :ingest, 2)

  defp valid_ontology?(ontology),
    do:
      is_atom(ontology) and Code.ensure_loaded?(ontology) and
        function_exported?(ontology, :__ontology__, 0)

  defp validate_reflection_shapes(reflections) do
    Enum.reduce_while(reflections, :ok, fn definition, :ok ->
      case validate_reflection_shape(definition) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_reflection_shape(definition) do
    name = field(definition, :name)
    outputs = field(definition, :outputs)

    with :ok <- validate_reflection_outputs(name, outputs),
         {:ok, _chain_of_thought} <- validate_chain_of_thought(name, definition) do
      :ok
    end
  end

  defp validate_reflection_outputs(name, outputs) when not is_list(outputs),
    do: {:error, {:invalid_reflection_outputs, name, outputs}}

  defp validate_reflection_outputs(name, outputs) do
    unknown_fields =
      Enum.find_value(outputs, fn output ->
        case definition_keys(output) do
          {:ok, keys} ->
            case Enum.reject(keys, &known_field?(&1, [:kind, :destination, :ontology])) do
              [] -> nil
              unknown -> unknown
            end

          :error ->
            :invalid_output
        end
      end)

    destinations = Enum.filter(outputs, &(field(&1, :kind) == :destination))
    unsupported = Enum.find(outputs, &(field(&1, :kind) != :destination))
    output = List.first(destinations)
    destination = field(output, :destination)
    ontology = ontology(output)

    cond do
      unknown_fields == :invalid_output ->
        {:error, {:invalid_reflection_output, name}}

      is_list(unknown_fields) ->
        {:error, {:unknown_reflection_output_fields, name, unknown_fields}}

      unsupported ->
        {:error, {:unsupported_reflection_output, name, field(unsupported, :kind)}}

      destinations == [] ->
        {:error, {:missing_destination_output, name}}

      length(destinations) > 1 ->
        {:error, {:duplicate_destination_output, name}}

      not non_blank?(destination) ->
        {:error, {:missing_reflection_destination, name, destination}}

      not valid_ontology?(ontology) ->
        {:error, {:invalid_reflection_ontology, name, ontology}}

      true ->
        :ok
    end
  end

  defp validate_chain_of_thought(name, definition) do
    configuration = field(definition, :chain_of_thought)

    cond do
      is_nil(configuration) ->
        {:error, {:missing_chain_of_thought, name}}

      not definition_shape?(configuration) ->
        {:error, {:invalid_chain_of_thought, name, configuration}}

      unknown = unknown_fields(configuration, [:steps]) ->
        {:error, {:unknown_chain_of_thought_fields, name, unknown}}

      nested = unknown_step_fields(configuration) ->
        {label, fields} = nested
        {:error, {:unknown_chain_of_thought_step_fields, name, label, fields}}

      true ->
        case ChainOfThought.from_config(configuration) do
          {:ok, chain_of_thought} -> {:ok, chain_of_thought}
          {:error, reason} -> {:error, {:invalid_chain_of_thought, name, reason}}
        end
    end
  end

  defp definition_shape?(value) when is_map(value), do: true
  defp definition_shape?(value) when is_list(value), do: Keyword.keyword?(value)
  defp definition_shape?(_value), do: false

  defp unknown_fields(definition, allowed) do
    case definition_keys(definition) do
      {:ok, keys} ->
        case Enum.reject(keys, &known_field?(&1, allowed)) do
          [] -> nil
          unknown -> unknown
        end

      :error ->
        nil
    end
  end

  defp unknown_step_fields(configuration) do
    case field(configuration, :steps) do
      steps when is_list(steps) ->
        Enum.find_value(steps, fn step ->
          if definition_shape?(step) do
            case unknown_fields(step, [:label, :directions, :output]) do
              nil -> nil
              fields -> {field(step, :label), fields}
            end
          end
        end)

      _ ->
        nil
    end
  end

  defp validate_destination_references(configuration) do
    destination_names =
      MapSet.new(
        ["operator", "global"] ++ Enum.map(configuration.destinations, &field(&1, :name))
      )

    with :ok <- validate_lens_destinations(configuration.lenses, destination_names) do
      validate_reflection_destinations(configuration.reflections, destination_names)
    end
  end

  defp validate_lens_destinations(lenses, destination_names) do
    case Enum.find(lenses, fn definition ->
           not MapSet.member?(destination_names, field(definition, :destination))
         end) do
      nil ->
        :ok

      definition ->
        {:error,
         {:unknown_destination, :lenses, field(definition, :name),
          field(definition, :destination)}}
    end
  end

  defp validate_reflection_destinations(reflections, destination_names) do
    Enum.reduce_while(reflections, :ok, fn reflection, :ok ->
      outputs = field(reflection, :outputs)

      missing =
        if is_list(outputs) do
          Enum.find(outputs, fn output ->
            field(output, :kind) == :destination and
              not MapSet.member?(destination_names, field(output, :destination))
          end)
        end

      if missing do
        {:halt,
         {:error,
          {:unknown_destination, :reflections, field(reflection, :name),
           field(missing, :destination)}}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp validate_reserved_entity_kinds(configuration) do
    lens_ontologies =
      Enum.map(configuration.lenses, &ontology/1)

    reflection_ontologies =
      Enum.flat_map(configuration.reflections, fn reflection ->
        case field(reflection, :outputs) do
          outputs when is_list(outputs) ->
            Enum.map(outputs, &ontology/1)

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
    case call!(owner, {:fetch, collection, name}) do
      {:ok, definition} -> definition
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  defp fetch_definitions!(owner, collection, names) do
    case call!(owner, {:fetch_many, collection, names}) do
      {:ok, definitions} -> definitions
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  defp fetch_definitions(index, collection, names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, definitions} ->
      case Map.fetch(index, name) do
        {:ok, definition} -> {:cont, {:ok, [definition | definitions]}}
        :error -> {:halt, {:error, {:unknown_definition, collection, name}}}
      end
    end)
    |> case do
      {:ok, definitions} -> {:ok, Enum.reverse(definitions)}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_search_destinations(definitions, []) do
    {:ok, definitions.destination_list}
  end

  defp resolve_search_destinations(definitions, names) do
    fetch_definitions(definitions.destinations, :destinations, names)
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

  defp validate_operator_id(invocation) do
    operator_id = field(invocation, :operator_id)

    if non_blank?(operator_id),
      do: :ok,
      else: {:error, {:invalid_operator_id, operator_id}}
  end

  defp process_reflection(reflection, invocation, callback, opts, runtime_owner) do
    production_opts = Keyword.put(opts, :runtime_owner, runtime_owner)
    production = fn -> Runner.run(reflection, invocation, production_opts) end

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
          if retryable_server_failure?({:error, failure}) or
               non_retryable_client_failure?({:error, failure}) do
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

  defp non_retryable_client_failure?({:error, reason}), do: server_status(reason) in 400..499

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

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(keyword, key) when is_list(keyword), do: Keyword.get(keyword, key)
  defp field(_, _), do: nil

  defp has_field?(map, key) when is_map(map),
    do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp has_field?(keyword, key) when is_list(keyword), do: Keyword.has_key?(keyword, key)

  defp ontology(definition) do
    case field(definition, :ontology) do
      nil -> Gralkor.DefaultOntology
      configured -> configured
    end
  end

  defp non_blank?(value), do: is_binary(value) and String.trim(value) != ""

  defp duplicate(values) do
    values
    |> Enum.frequencies()
    |> Enum.find_value(fn {value, count} -> if count > 1, do: value end)
  end

  defp call!(owner, message) do
    runtime = runtime_pid!(owner)

    try do
      GenServer.call(runtime, message)
    catch
      :exit, _reason -> runtime_unavailable!(owner)
    end
  end

  defp runtime_pid!(owner) when is_pid(owner) do
    case :global.whereis_name({__MODULE__, owner}) do
      runtime when is_pid(runtime) -> runtime
      :undefined -> runtime_unavailable!(owner)
    end
  end

  defp runtime_pid!(owner) do
    raise ArgumentError,
          "Gralkor runtime target must be an owning AgentServer PID, got #{inspect(owner)}"
  end

  defp runtime_unavailable!(owner) do
    raise ArgumentError, "Gralkor runtime unavailable for owning AgentServer #{inspect(owner)}"
  end

  defp via(owner), do: {:global, {__MODULE__, owner}}
end
