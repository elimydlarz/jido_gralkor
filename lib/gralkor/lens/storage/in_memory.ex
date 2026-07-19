defmodule Gralkor.Lens.Storage.InMemory do
  @moduledoc false

  use GenServer

  @behaviour Gralkor.Lens.Storage

  alias Gralkor.Lens
  alias Gralkor.Lens.Store

  @type episode :: %{
          required(:content) => String.t(),
          required(:lens) => String.t(),
          optional(:id) => String.t()
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

  @impl Gralkor.Lens.Storage
  def add_episode(%Store{} = store, content, source_description) do
    add_episode(store, content, source_description, [])
  end

  @impl Gralkor.Lens.Storage
  def add_episode(
        %Store{operator_id: operator_id, lens: %Lens{name: lens_name, scope: :operator} = lens},
        content,
        _source_description,
        opts
      ) do
    GenServer.call(__MODULE__, {:add, {operator_id, lens_name}, episode(content, lens, opts)})
  end

  def add_episode(
        %Store{lens: %Lens{scope: :global} = lens},
        content,
        _source_description,
        opts
      ) do
    GenServer.call(__MODULE__, {:add, :global, episode(content, lens, opts)})
  end

  @impl Gralkor.Lens.Storage
  def remove_episode(%Store{} = store, episode_id) do
    GenServer.call(__MODULE__, {:remove, key(store), episode_id})
  end

  @impl Gralkor.Lens.Storage
  def search(
        %Store{operator_id: operator_id, lens: %Lens{name: lens_name, scope: :operator}},
        _query,
        _max_results
      ) do
    GenServer.call(__MODULE__, {:search, {operator_id, lens_name}})
  end

  def search(%Store{lens: %Lens{scope: :global}}, _query, _max_results) do
    GenServer.call(__MODULE__, {:search, :global})
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

  def handle_call({:remove, key, episode_id}, _from, state) do
    episodes = state |> Map.get(key, []) |> Enum.reject(&episode_id?(&1, episode_id))
    {:reply, :ok, Map.put(state, key, episodes)}
  end

  def handle_call({:episodes, key}, _from, state) do
    {:reply, Map.get(state, key, []), state}
  end

  @spec episode(String.t(), Lens.t(), keyword()) :: episode()
  defp episode(content, lens, opts) do
    case Keyword.fetch(opts, :uuid) do
      {:ok, id} -> %{id: id, content: content, lens: lens.name}
      :error -> %{content: content, lens: lens.name}
    end
  end

  defp key(%Store{operator_id: operator_id, lens: %Lens{name: lens_name, scope: :operator}}),
    do: {operator_id, lens_name}

  defp key(%Store{lens: %Lens{scope: :global}}), do: :global

  defp episode_id?(%{id: id}, episode_id), do: id == episode_id

  defp episode_id?(episode, episode_id) do
    case Gralkor.Generalisation.decode(episode.content) do
      {:ok, %{id: ^episode_id}, _plain} -> true
      _ -> false
    end
  end
end
