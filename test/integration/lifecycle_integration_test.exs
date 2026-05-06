defmodule JidoGralkor.LifecycleIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 10_000

  alias Gralkor.Client.InMemory
  alias JidoGralkor.LifecycleTestAgent
  alias JidoGralkor.LifecycleTestJido

  @idle_ms 150

  setup do
    InMemory.reset()
    InMemory.set_end_session(:ok)

    {:ok, jido} = Jido.start(name: LifecycleTestJido, otp_app: :jido_gralkor)

    on_exit(fn ->
      if Process.alive?(jido) do
        try do
          GenServer.stop(jido, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :ok
  end

  defp start_agent(opts) do
    id = "agent-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Jido.start_agent(
        LifecycleTestJido,
        LifecycleTestAgent,
        Keyword.merge([id: id, lifecycle_mod: JidoGralkor.Lifecycle], opts)
      )

    {pid, id}
  end

  defp seed_thread(pid, thread_id) do
    :sys.replace_state(pid, fn state ->
      put_in(state.agent.state[:__thread__], %{id: thread_id})
    end)
  end

  defp eventually(fun, timeout_ms \\ 2_000, interval_ms \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline, interval_ms)
  end

  defp do_eventually(fun, deadline, interval_ms) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(interval_ms)
        do_eventually(fun, deadline, interval_ms)
      end
    end
  end

  describe "while the AgentServer is wired with JidoGralkor.Lifecycle and a positive idle_timeout, while a thread is committed, when the idle window elapses without :touch" do
    test "then the AgentServer terminates and end_session fires once with the thread id" do
      {pid, _id} = start_agent(idle_timeout: @idle_ms)
      thread_id = "thread-elapse"
      seed_thread(pid, thread_id)

      assert eventually(fn -> not Process.alive?(pid) end, @idle_ms * 10)
      assert eventually(fn -> InMemory.end_sessions() == [[thread_id]] end)
    end
  end

  describe "while the AgentServer is wired with JidoGralkor.Lifecycle and a positive idle_timeout, while a thread is committed, when :touch arrives before each elapse" do
    test "then the AgentServer stays alive and end_session is not called" do
      {pid, _id} = start_agent(idle_timeout: @idle_ms)
      thread_id = "thread-touch"
      seed_thread(pid, thread_id)

      for _ <- 1..5 do
        Process.sleep(div(@idle_ms, 3))
        :ok = Jido.AgentServer.touch(pid)
      end

      assert Process.alive?(pid)
      assert InMemory.end_sessions() == []

      GenServer.stop(pid, :shutdown, 5_000)
    end
  end

  describe "while the AgentServer is wired with JidoGralkor.Lifecycle and a positive idle_timeout, while a thread is committed, when GenServer.stop(:shutdown) is invoked" do
    test "then end_session fires with the thread id" do
      {pid, _id} = start_agent(idle_timeout: @idle_ms * 100)
      thread_id = "thread-stop"
      seed_thread(pid, thread_id)

      :ok = GenServer.stop(pid, :shutdown, 5_000)

      assert eventually(fn -> InMemory.end_sessions() == [[thread_id]] end)
    end
  end

  describe "while the AgentServer is wired with JidoGralkor.Lifecycle and a positive idle_timeout, while no thread is committed (first turn), when GenServer.stop is invoked" do
    test "then the AgentServer terminates and end_session is not called" do
      {pid, _id} = start_agent(idle_timeout: @idle_ms * 100)

      :ok = GenServer.stop(pid, :shutdown, 5_000)

      Process.sleep(50)
      assert InMemory.end_sessions() == []
    end
  end

  describe "while the AgentServer is wired with a non-positive idle_timeout" do
    test "then no idle timer is armed (verified by elapsing well past any plausible window)" do
      {pid, _id} = start_agent(idle_timeout: 0)
      thread_id = "thread-no-timer"
      seed_thread(pid, thread_id)

      Process.sleep(@idle_ms * 4)

      assert Process.alive?(pid)
      assert InMemory.end_sessions() == []

      GenServer.stop(pid, :shutdown, 5_000)
    end
  end
end
