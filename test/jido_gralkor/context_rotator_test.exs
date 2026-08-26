defmodule JidoGralkor.ContextRotatorTest do
  use ExUnit.Case, async: false

  alias Gralkor.Client.InMemory
  alias JidoGralkor.ContextRotator

  defmodule AgentServerDouble do
    use GenServer

    def start_link(thread), do: GenServer.start_link(__MODULE__, thread)

    @impl true
    def init(thread), do: {:ok, thread}

    @impl true
    def handle_call(:get_state, _from, thread) do
      {:reply, {:ok, %{agent: %{state: %{__thread__: thread}}}}, thread}
    end
  end

  defmodule ExitingClient do
    def flush_and_await(_session_id, _timeout_ms), do: exit(:flush_crashed)
  end

  setup do
    previous_client = Application.get_env(:jido_gralkor, :client)

    if Process.whereis(InMemory) == nil do
      start_supervised!(InMemory)
    end

    InMemory.reset()
    Application.put_env(:jido_gralkor, :client, InMemory)

    on_exit(fn ->
      if previous_client,
        do: Application.put_env(:jido_gralkor, :client, previous_client),
        else: Application.delete_env(:jido_gralkor, :client)
    end)

    :ok
  end

  defp entry(seq, content),
    do: %{kind: :ai_message, seq: seq, payload: %{role: :user, content: content}}

  describe "when a rotation seed is computed > while every current entry was in the flushed set" do
    test "then the seed is the most recent entries up to the retention count" do
      pre = [entry(0, "a"), entry(1, "b"), entry(2, "c"), entry(3, "d")]

      assert ContextRotator.compute_seed(pre, pre, 2) == [entry(2, "c"), entry(3, "d")]
    end
  end

  describe "when a rotation seed is computed > while every current entry was in the flushed set > while the retention count is zero" do
    test "then the seed is empty rather than falling back to any default retention" do
      pre = [entry(0, "a"), entry(1, "b")]

      assert ContextRotator.compute_seed(pre, pre, 0) == []
    end
  end

  describe "when a rotation seed is computed > while the current entries include in-flight entries that arrived after the flushed ones" do
    test "then those in-flight entries are seeded whatever the retention count is, so nothing mid-turn is lost" do
      pre = [entry(0, "a"), entry(1, "b")]
      current = pre ++ [entry(2, "in-flight-1"), entry(3, "in-flight-2")]

      assert ContextRotator.compute_seed(pre, current, 0) ==
               [entry(2, "in-flight-1"), entry(3, "in-flight-2")]
    end

    test "and the retained entries precede the in-flight entries in the seed" do
      pre = [entry(0, "a"), entry(1, "b"), entry(2, "c")]
      current = pre ++ [entry(3, "inflight")]

      assert ContextRotator.compute_seed(pre, current, 1) ==
               [entry(2, "c"), entry(3, "inflight")]
    end
  end

  describe "when a rotation seed is computed > while the current entries include in-flight entries that arrived after the flushed ones > while there were no flushed entries at all" do
    test "then the seed is exactly the in-flight entries" do
      current = [entry(0, "inflight-only")]

      assert ContextRotator.compute_seed([], current, 4) == [entry(0, "inflight-only")]
    end
  end

  describe "when a rotation seed is computed > while every current entry was in the flushed set > while the retention count exceeds the number of flushed entries" do
    test "then every flushed entry is seeded" do
      pre = [entry(0, "a")]
      current = pre

      assert ContextRotator.compute_seed(pre, current, 10) == pre
    end

    test "and no more are invented" do
      pre = [entry(0, "a")]

      assert length(ContextRotator.compute_seed(pre, pre, 10)) == length(pre)
    end
  end

  describe "when rotation is requested without option overrides" do
    test "then the flush uses a thirty-second timeout" do
      entries = Enum.map(0..5, &entry(&1, "entry-#{&1}"))
      {:ok, agent} = AgentServerDouble.start_link(%{id: "session-one", entries: entries})
      InMemory.set_flush_and_await(:ok)

      assert :ok =
               ContextRotator.rotate_now(agent,
                 install_thread_fn: fn _pid, _new_id, _pre, keep_last_n ->
                   {:ok, keep_last_n}
                 end
               )

      assert InMemory.flush_and_awaits() == [["session-one", 30_000]]
    end

    test "and the fresh thread retains the four newest pre-flush entries" do
      entries = Enum.map(0..5, &entry(&1, "entry-#{&1}"))
      {:ok, agent} = AgentServerDouble.start_link(%{id: "session-one", entries: entries})
      InMemory.set_flush_and_await(:ok)
      test_pid = self()

      assert :ok =
               ContextRotator.rotate_now(agent,
                 install_thread_fn: fn _pid, _new_id, pre, keep_last_n ->
                   seed = ContextRotator.compute_seed(pre, pre, keep_last_n)
                   send(test_pid, {:seed, seed})
                   {:ok, length(seed)}
                 end
               )

      expected = Enum.map(2..5, &entry(&1, "entry-#{&1}"))
      assert_receive {:seed, ^expected}
    end
  end

  describe "if the configured flush call exits" do
    test "then rotation returns an error carrying the flush exit reason" do
      Application.put_env(:jido_gralkor, :client, ExitingClient)
      {:ok, agent} = AgentServerDouble.start_link(%{id: "session-one", entries: [entry(0, "a")]})

      assert {:error, {:flush_exit, :flush_crashed}} = ContextRotator.rotate_now(agent)
    end

    test "and the active session remains unchanged" do
      Application.put_env(:jido_gralkor, :client, ExitingClient)
      thread = %{id: "session-one", entries: [entry(0, "a")]}
      {:ok, agent} = AgentServerDouble.start_link(thread)

      assert {:error, {:flush_exit, :flush_crashed}} = ContextRotator.rotate_now(agent)
      assert {:ok, %{agent: %{state: %{__thread__: ^thread}}}} = Jido.AgentServer.state(agent)
    end
  end
end
