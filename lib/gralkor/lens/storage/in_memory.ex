defmodule Gralkor.Lens.Storage.InMemory do
  @moduledoc false

  use GenServer

  @behaviour Gralkor.Lens.Storage

  alias Gralkor.Lens
  alias Gralkor.Lens.Store

  @type state :: %{{String.t(), String.t()} => [String.t()]}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl Gralkor.Lens.Storage
  def add_episode(
        %Store{operator_id: operator_id, lens: %Lens{name: lens_name, scope: :operator}},
        content,
        _source_description
      ) do
    GenServer.call(__MODULE__, {:add, {operator_id, lens_name}, content})
  end

  @impl Gralkor.Lens.Storage
  def search(
        %Store{operator_id: operator_id, lens: %Lens{name: lens_name, scope: :operator}},
        _query,
        _max_results
      ) do
    GenServer.call(__MODULE__, {:search, {operator_id, lens_name}})
  end

  @impl true
  def handle_call({:add, key, content}, _from, state) do
    {:reply, :ok, Map.update(state, key, [content], &(&1 ++ [content]))}
  end

  def handle_call({:search, key}, _from, state) do
    {:reply, {:ok, Map.get(state, key, [])}, state}
  end
end
