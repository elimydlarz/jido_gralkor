defmodule JidoGralkor.Runtime do
  @moduledoc false

  use GenServer

  alias Gralkor.Destination
  alias Gralkor.Lens
  alias Gralkor.Reflection
  alias Gralkor.Reflection.ChainOfThought

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

  @impl GenServer
  def init(opts) do
    configuration = Keyword.fetch!(opts, :configuration)

    with :ok <- validate_configuration(configuration),
         {:ok, definitions} <- resolve_configuration(configuration) do
      {:ok,
       %{
         owner: Keyword.fetch!(opts, :owner),
         configuration: configuration,
         definitions: definitions
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
      Enum.map(Gralkor.Reflection.Packaged.definitions() ++ configuration.reflections, fn definition ->
        {:ok, chain_of_thought} = ChainOfThought.from_config(field(definition, :chain_of_thought))

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
      end)

    {:ok,
     %{
       destinations: Map.new(destinations, &{&1.name, &1}),
       destination_list: destinations,
       lenses: Map.new(lenses, &{&1.name, &1}),
       reflections: Map.new(reflections, &{&1.name, &1})
     }}
  rescue
    error ->
      {:error, {:invalid_runtime_configuration, Exception.message(error)}}
  end

  defp fetch_definition!(owner, collection, name) do
    ensure_started(owner)

    case GenServer.call(via(owner), {:fetch, collection, name}) do
      {:ok, definition} -> definition
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(keyword, key) when is_list(keyword), do: Keyword.get(keyword, key)
  defp field(_, _), do: nil

  defp via(owner), do: {:global, {__MODULE__, owner}}
end
