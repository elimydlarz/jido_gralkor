defmodule Gralkor.Lens.Storage.InMemory do
  @moduledoc false

  use GenServer

  @behaviour Gralkor.Lens.Storage

  alias Gralkor.Lens
  alias Gralkor.Lens.Replaceable
  alias Gralkor.Lens.Store

  @type episode :: %{
          required(:content) => String.t(),
          required(:lens) => String.t()
        }
  @type key :: {String.t(), String.t()} | :global
  @type state :: %{key() => [episode()]}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(state), do: {:ok, state}

  @spec episodes(key()) :: [episode()]
  def episodes(key), do: GenServer.call(__MODULE__, {:episodes, key})

  @spec graph(key()) :: map()
  def graph(key), do: GenServer.call(__MODULE__, {:graph, key})

  @impl Gralkor.Lens.Storage
  def add_episode(%Store{} = store, content, _source_description) do
    GenServer.call(__MODULE__, {:add, key(store), episode(content, store.lens)})
  end

  @impl Gralkor.Lens.Storage
  def replace_graph(
        %Store{lens: %Replaceable{name: lens_name}} = store,
        %Gralkor.Graph{data: graph}
      ) do
    owned_graph = %{
      nodes: Enum.map(graph.nodes, &put_owner(&1, lens_name)),
      relationships: Enum.map(graph.relationships, &put_owner(&1, lens_name))
    }

    GenServer.call(__MODULE__, {:replace_graph, key(store), owned_graph})
  end

  @impl Gralkor.Lens.Storage
  def search(
        %Store{operator_id: operator_id, lens: %Lens{name: lens_name, scope: :operator}},
        _query,
        max_results
      ) do
    GenServer.call(__MODULE__, {:search, {operator_id, lens_name}, max_results})
  end

  def search(%Store{lens: %Lens{scope: :global}}, _query, max_results) do
    GenServer.call(__MODULE__, {:search, :global, max_results})
  end

  def search(%Store{lens: :global}, _query, max_results) do
    GenServer.call(__MODULE__, {:search, :global, max_results})
  end

  @impl true
  def handle_call({:add, key, episode}, _from, state) do
    {:reply, :ok, Map.update(state, key, [episode], &(&1 ++ [episode]))}
  end

  def handle_call({:search, key, max_results}, _from, state) do
    contents = state |> Map.get(key, []) |> Enum.take(max_results) |> Enum.map(& &1.content)
    {:reply, {:ok, contents}, state}
  end

  def handle_call({:replace_graph, key, graph}, _from, state) do
    {:reply, :ok, Map.put(state, {:graph, key}, graph)}
  end

  def handle_call({:episodes, key}, _from, state) do
    {:reply, Map.get(state, key, []), state}
  end

  def handle_call({:graph, key}, _from, state) do
    {:reply, Map.get(state, {:graph, key}, %{nodes: [], relationships: []}), state}
  end

  @spec episode(String.t(), Lens.t()) :: episode()
  defp episode(content, lens), do: %{content: content, lens: lens.name}

  defp key(%Store{operator_id: operator_id, lens: %Lens{name: lens_name, scope: :operator}}),
    do: {operator_id, lens_name}

  defp key(%Store{lens: %Lens{scope: :global}}), do: :global

  defp key(%Store{
         operator_id: operator_id,
         lens: %Replaceable{name: lens_name, scope: :operator}
       }),
    do: {operator_id, lens_name}

  defp key(%Store{lens: %Replaceable{scope: :global}}), do: :global

  defp put_owner(entity, lens_name) do
    entity
    |> Map.delete(:labels)
    |> Map.update!(:properties, &Map.put(&1, :_gralkor_lens, lens_name))
  end
end
