defmodule JidoGralkor.LifecycleTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Gralkor.Client.InMemory
  alias JidoGralkor.Lifecycle

  setup do
    InMemory.reset()
    :ok
  end

  defp state(agent_state \\ %{}) do
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

  test "then implements `Jido.AgentServer.Lifecycle` so the AgentServer calls `terminate/2` on graceful stop" do
    assert Code.ensure_loaded?(Lifecycle)
    behaviours = Lifecycle.module_info(:attributes)[:behaviour] || []
    assert Jido.AgentServer.Lifecycle in behaviours
  end

  describe "when the AgentServer terminates with a committed thread" do
    test "then `Gralkor.Client.flush(thread_id)` is invoked without blocking termination" do
      InMemory.set_flush(:ok)
      thread_id = "thread-term"

      s = state(%{__thread__: %{id: thread_id}})

      assert :ok = Lifecycle.terminate(:normal, s)
      assert eventually(fn -> InMemory.flushes() == [[thread_id]] end)
    end

    test "and the flush is logged at :info naming the session id and the terminate reason" do
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

  describe "when the AgentServer terminates with a committed thread, if the background flush call fails" do
    test "then the failure is logged and termination is unaffected" do
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
  end

  describe "when the AgentServer terminates without a committed thread" do
    test "then Gralkor is not called" do
      s = state(%{})

      assert :ok = Lifecycle.terminate(:normal, s)
      Process.sleep(20)
      assert InMemory.flushes() == []
    end
  end
end
