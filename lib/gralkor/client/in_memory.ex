defmodule Gralkor.Client.InMemory do
  @moduledoc """
  In-memory twin of `Gralkor.Client` for tests.

  Configure responses per operation before exercising the code under test;
  inspect the calls that were made after. Operations with no configured
  response return `{:error, :not_configured}` — tests should set every
  response they expect the code under test to hit.
  """

  @behaviour Gralkor.Client

  use GenServer

  # ── Test API ────────────────────────────────────────────────

  def start_link(_opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Reset all state — call in `setup`."
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "Set the response for the next (and all subsequent) `recall/4` calls."
  def set_recall(response), do: GenServer.call(__MODULE__, {:set, :recall, response})

  @doc "Set the response for the next (and all subsequent) `memory_add/3` calls."
  def set_memory_add(response), do: GenServer.call(__MODULE__, {:set, :memory_add, response})

  @doc "Set the response for the next (and all subsequent) `build_indices/0` calls."
  def set_build_indices(response),
    do: GenServer.call(__MODULE__, {:set, :build_indices, response})

  @doc "Set the response for the next (and all subsequent) `build_communities/1` calls."
  def set_build_communities(response),
    do: GenServer.call(__MODULE__, {:set, :build_communities, response})

  def recalls, do: GenServer.call(__MODULE__, {:calls, :recall})
  def adds, do: GenServer.call(__MODULE__, {:calls, :memory_add})
  def indices_builds, do: GenServer.call(__MODULE__, {:calls, :build_indices})
  def communities_builds, do: GenServer.call(__MODULE__, {:calls, :build_communities})

  # ── Client behaviour ────────────────────────────────────────

  @impl Gralkor.Client
  def recall(group_id, agent_name, session_id, query) do
    raise_if_blank!(:agent_name, agent_name)
    GenServer.call(__MODULE__, {:call, :recall, [group_id, agent_name, session_id, query]})
  end

  @impl Gralkor.Client
  def memory_add(group_id, content, source),
    do: GenServer.call(__MODULE__, {:call, :memory_add, [group_id, content, source]})

  @impl Gralkor.Client
  def memory_add(group_id, content, source, source_kind),
    do: GenServer.call(__MODULE__, {:call, :memory_add, [group_id, content, source, source_kind]})

  @impl Gralkor.Client
  def build_indices,
    do: GenServer.call(__MODULE__, {:call, :build_indices, []})

  @impl Gralkor.Client
  def build_communities(group_id),
    do: GenServer.call(__MODULE__, {:call, :build_communities, [group_id]})

  # ── GenServer ──────────────────────────────────────────────

  @impl GenServer
  def init(:ok), do: {:ok, empty_state()}

  @impl GenServer
  def handle_call(:reset, _from, _state), do: {:reply, :ok, empty_state()}

  def handle_call({:set, op, response}, _from, state),
    do: {:reply, :ok, put_in(state.responses[op], response)}

  def handle_call({:calls, op}, _from, state),
    do: {:reply, Enum.reverse(Map.get(state.calls, op, [])), state}

  def handle_call({:call, op, args}, _from, state) do
    state = update_in(state.calls[op], &[args | &1 || []])
    response = Map.get(state.responses, op, {:error, :not_configured})
    {:reply, response, state}
  end

  defp empty_state, do: %{responses: %{}, calls: %{}}

  defp raise_if_blank!(field, value) when is_binary(value) do
    if String.trim(value) == "" do
      raise ArgumentError,
            "Gralkor.Client.InMemory: #{field} must be a non-blank string, got #{inspect(value)}"
    end

    :ok
  end

  defp raise_if_blank!(field, value) do
    raise ArgumentError,
          "Gralkor.Client.InMemory: #{field} must be a non-blank string, got #{inspect(value)}"
  end
end
