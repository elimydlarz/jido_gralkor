defmodule JidoGralkor.Runtime do
  @moduledoc false

  use GenServer

  alias Gralkor.Destination
  alias Gralkor.Destination.Storage, as: DestinationStorage
  alias Gralkor.Lens
  alias Gralkor.Reflection
  alias Gralkor.Reflection.ChainOfThought
  alias Gralkor.Reflection.Runner

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
    with :ok <- validate_lens_shapes(configuration.lenses),
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
                  destination: Map.fetch!(destination_index, field(definition, :destination)),
                  graph_format: :property_graph
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

      id -> {:error, {:invalid_invocation_id, id}}
    end
  end

  defp invocation_id(invocation), do: {:error, {:invalid_invocation, invocation}}

  defp process_reflection(reflection, invocation, callback, opts) do
    case Runner.run(reflection, invocation, opts) do
      {:ok, artefact} ->
        output = Enum.find(reflection.outputs, &(&1.kind == :destination))

        case DestinationStorage.put_artefact(
               output,
               reflection.name,
               field(invocation, :operator_id),
               artefact,
               opts
             ) do
          :ok ->
            callback.(%{
              invocation_id: field(invocation, :id),
              artefact: artefact,
              outcome: :delivered
            })

          {:error, reason} ->
            callback.(%{
              invocation_id: field(invocation, :id),
              artefact: artefact,
              outcome: {:abandoned, %{stage: :delivery, reason: reason}}
            })
        end

      {:error, failure} ->
        callback.(%{
          invocation_id: field(invocation, :id),
          outcome: {:production_failed, failure}
        })
    end
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(keyword, key) when is_list(keyword), do: Keyword.get(keyword, key)
  defp field(_, _), do: nil

  defp has_field?(map, key) when is_map(map),
    do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp has_field?(keyword, key) when is_list(keyword), do: Keyword.has_key?(keyword, key)

  defp via(owner), do: {:global, {__MODULE__, owner}}
end
