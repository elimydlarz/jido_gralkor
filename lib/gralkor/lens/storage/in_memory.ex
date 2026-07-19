defmodule Gralkor.Lens.Storage.InMemory do
  @moduledoc false

  use GenServer

  @behaviour Gralkor.Lens.Storage

  alias Gralkor.Lens
  alias Gralkor.Lens.Store

  @type episode :: %{content: String.t(), lens: String.t()}
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

  @impl Gralkor.Lens.Storage
  def add_episode(
        %Store{operator_id: operator_id, lens: %Lens{name: lens_name, scope: :operator} = lens},
        content,
        _source_description
      ) do
    GenServer.call(__MODULE__, {:add, {operator_id, lens_name}, episode(content, lens)})
  end

  def add_episode(
        %Store{lens: %Lens{scope: :global} = lens},
        content,
        _source_description
      ) do
    GenServer.call(__MODULE__, {:add, :global, episode(content, lens)})
  end

  @impl Gralkor.Lens.Storage
  def search(
        %Store{operator_id: operator_id, lens: %Lens{name: lens_name, scope: :operator}},
        _query,
        _max_results
      ) do
    GenServer.call(__MODULE__, {:search, {operator_id, lens_name}})
  end

  def search(%Store{lens: :global}, _query, _max_results) do
    GenServer.call(__MODULE__, {:search, :global})
  end

  @impl true
  def handle_call({:add, key, episode}, _from, state) do
    {:reply, :ok, Map.update(state, key, [episode], &(&1 ++ [episode]))}
  end

  def handle_call({:search, key}, _from, state) do
    contents = state |> Map.get(key, []) |> Enum.map(& &1.content)
    {:reply, {:ok, contents}, state}
  end

  def handle_call({:episodes, key}, _from, state) do
    {:reply, Map.get(state, key, []), state}
  end

  @spec episode(String.t(), Lens.t()) :: episode()
  defp episode(content, lens), do: %{content: content, lens: lens.name}
end
