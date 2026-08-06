defmodule JidoGralkor.LifecycleTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gralkor.Client.InMemory
  alias JidoGralkor.Lifecycle

  setup do
    InMemory.reset()
    :ok
  end

  defp state(agent_state) do
    %{agent: %{state: agent_state}}
  end

  defp eventually(fun, timeout_ms \\ 500, interval_ms \\ 10) do
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

  describe "when a consumer wires the module as an agent server's lifecycle" do
    test "then it declares the Jido agent-server lifecycle behaviour, so the agent server calls terminate on graceful stop" do
      assert Code.ensure_loaded?(Lifecycle)
      behaviours = Lifecycle.module_info(:attributes)[:behaviour] || []
      assert Jido.AgentServer.Lifecycle in behaviours
    end

    test "and initialisation hands back the agent server's state unchanged, so wiring it in alters nothing about the agent" do
      s = state(%{__thread__: %{id: "thread-init"}, other: :data})

      assert Lifecycle.init([], s) == s
      assert Lifecycle.init([some: :opts], s) == s
    end

    test "and every lifecycle event it is handed continues to the rest of the server with state unchanged, so it observes without intercepting" do
      s = state(%{__thread__: %{id: "thread-event"}, other: :data})

      assert Lifecycle.handle_event(%{kind: :anything}, s) == {:cont, s}
      assert Lifecycle.handle_event(:some_event, s) == {:cont, s}
    end
  end

  describe "when the agent server terminates > while a thread is committed to agent state" do
    test "then that thread's buffered memory is flushed without blocking termination" do
      InMemory.set_flush(:ok)
      thread_id = "thread-term"

      s = state(%{__thread__: %{id: thread_id}})

      assert :ok = Lifecycle.terminate(:normal, s)
      assert eventually(fn -> InMemory.flushes() == [[thread_id]] end)
    end

    test "and the flush is logged at info naming the session id and the terminate reason" do
      InMemory.set_flush(:ok)
      thread_id = "thread-log"
      s = state(%{__thread__: %{id: thread_id}})

      Logger.put_module_level(JidoGralkor.Lifecycle, :info)
      on_exit(fn -> Logger.delete_module_level(JidoGralkor.Lifecycle) end)

      log =
        capture_log([level: :info], fn ->
          assert :ok = Lifecycle.terminate({:shutdown, :idle_timeout}, s)
          assert eventually(fn -> InMemory.flushes() == [[thread_id]] end)
        end)

      assert log =~ "[info]"
      assert log =~ "[gralkor] flush — session:thread-log reason:{:shutdown, :idle_timeout}"
    end
  end

  describe "when the agent server terminates > while a thread is committed to agent state > if the flush call fails" do
    test "then the failure is logged" do
      InMemory.set_flush({:error, :boom})
      thread_id = "thread-fail"

      s = state(%{__thread__: %{id: thread_id}})

      log =
        capture_log(fn ->
          assert :ok = Lifecycle.terminate(:normal, s)
          assert eventually(fn -> InMemory.flushes() == [[thread_id]] end)
          Process.sleep(50)
        end)

      assert log =~ "[gralkor] flush failed"
      assert log =~ ":boom"
    end

    test "and termination completes normally regardless" do
      InMemory.set_flush({:error, :boom})
      s = state(%{__thread__: %{id: "thread-fail"}})

      assert :ok = Lifecycle.terminate(:normal, s)
    end
  end

  describe "when the agent server terminates > while no thread is committed to agent state" do
    test "then no flush is requested at all" do
      s = state(%{})

      assert :ok = Lifecycle.terminate(:normal, s)
      Process.sleep(20)
      assert InMemory.flushes() == []
    end
  end
end
