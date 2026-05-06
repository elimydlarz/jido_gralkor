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

  defp state(opts) do
    %{
      lifecycle: %{
        idle_timeout: Keyword.get(opts, :idle_timeout, 100),
        idle_timer: Keyword.get(opts, :idle_timer)
      },
      agent: %{state: Keyword.get(opts, :agent_state, %{})}
    }
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

  test "then implements `Jido.AgentServer.Lifecycle` so the AgentServer's built-in idle-timer machinery owns the timer" do
    assert Code.ensure_loaded?(Lifecycle)
    behaviours = Lifecycle.module_info(:attributes)[:behaviour] || []
    assert Jido.AgentServer.Lifecycle in behaviours
  end

  describe "when the AgentServer initialises with a positive idle_timeout" do
    test "then an idle timer is armed for that window" do
      result = Lifecycle.init([], state(idle_timeout: 250))
      assert result.lifecycle.idle_timer != nil
      :erlang.cancel_timer(result.lifecycle.idle_timer)
    end
  end

  describe "when the AgentServer initialises with a non-positive or absent idle_timeout" do
    test "then no idle timer is armed (consumer has opted out of idle-driven shutdown; only external GenServer.stop will trigger end_session)" do
      assert Lifecycle.init([], state(idle_timeout: 0)).lifecycle.idle_timer == nil
      assert Lifecycle.init([], state(idle_timeout: -1)).lifecycle.idle_timer == nil
      assert Lifecycle.init([], state(idle_timeout: nil)).lifecycle.idle_timer == nil
    end
  end

  describe "when a `:touch` event arrives" do
    test "then the idle timer is cancelled and re-armed for a fresh window" do
      first = Lifecycle.init([], state(idle_timeout: 250))
      first_ref = first.lifecycle.idle_timer

      assert {:cont, second} = Lifecycle.handle_event(:touch, first)
      second_ref = second.lifecycle.idle_timer

      refute second_ref == first_ref
      assert second_ref != nil
      :erlang.cancel_timer(second_ref)
    end
  end

  describe "when the idle timer elapses without a touch" do
    test "then the lifecycle returns `{:stop, {:shutdown, :idle_timeout}, state}` so the AgentServer terminates cleanly" do
      s = state(idle_timeout: 100)
      assert {:stop, {:shutdown, :idle_timeout}, ^s} = Lifecycle.handle_event(:idle_timeout, s)
    end
  end

  describe "when the AgentServer terminates with a committed thread" do
    test "then `Gralkor.Client.end_session(thread_id)` is fire-and-forgotten via Task.start" do
      InMemory.set_end_session(:ok)
      thread_id = "thread-term"

      s = state(agent_state: %{__thread__: %{id: thread_id}})

      assert :ok = Lifecycle.terminate(:normal, s)
      assert eventually(fn -> InMemory.end_sessions() == [[thread_id]] end)
    end

    test "and a [gralkor] end_session — session:<thread_id> reason:<terminate_reason> line is emitted at :info before the Task is spawned" do
      InMemory.set_end_session(:ok)
      thread_id = "thread-log"
      s = state(agent_state: %{__thread__: %{id: thread_id}})

      Logger.put_module_level(JidoGralkor.Lifecycle, :info)
      on_exit(fn -> Logger.delete_module_level(JidoGralkor.Lifecycle) end)

      log =
        capture_log([level: :info], fn ->
          assert :ok = Lifecycle.terminate({:shutdown, :idle_timeout}, s)
          assert eventually(fn -> InMemory.end_sessions() == [[thread_id]] end)
        end)

      assert log =~ "[info]"
      assert log =~ "[gralkor] end_session — session:thread-log reason:{:shutdown, :idle_timeout}"
    end
  end

  describe "when the AgentServer terminates with a committed thread, if the background Gralkor.Client.end_session call fails" do
    test "then the failure is logged (best-effort flush; termination is unaffected)" do
      InMemory.set_end_session({:error, :boom})
      thread_id = "thread-fail"

      s = state(agent_state: %{__thread__: %{id: thread_id}})

      log =
        capture_log(fn ->
          assert :ok = Lifecycle.terminate(:normal, s)
          assert eventually(fn -> InMemory.end_sessions() == [[thread_id]] end)
          Process.sleep(50)
        end)

      assert log =~ "[gralkor] end_session failed"
      assert log =~ ":boom"
    end
  end

  describe "when the AgentServer terminates without a committed thread (first-turn agent that never appended)" do
    test "then Gralkor is not called" do
      s = state(agent_state: %{})

      assert :ok = Lifecycle.terminate(:normal, s)
      Process.sleep(20)
      assert InMemory.end_sessions() == []
    end
  end
end
