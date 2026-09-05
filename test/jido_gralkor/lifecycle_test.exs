defmodule JidoGralkor.LifecycleTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gralkor.Client.InMemory
  alias JidoGralkor.Lifecycle

  defmodule FailingClient do
    def flush(session_id) do
      send(
        Application.fetch_env!(:jido_gralkor, :lifecycle_test_pid),
        {:failing_flush, session_id}
      )

      {:error, :boom}
    end
  end

  defmodule DelayedIngestionClient do
    def flush(session_id) do
      test_pid = Application.fetch_env!(:jido_gralkor, :lifecycle_test_pid)
      send(test_pid, {:flush_scheduled, session_id})

      Task.start(fn ->
        send(test_pid, {:ingestion_waiting, self()})

        receive do
          :finish_ingestion -> :ok
        end
      end)

      :ok
    end
  end

  setup do
    InMemory.reset()
    :ok
  end

  defp state(agent_state) do
    %{agent: %{state: agent_state}}
  end

  defp use_failing_client do
    previous = Application.get_env(:jido_gralkor, :client)
    previous_test_pid = Application.get_env(:jido_gralkor, :lifecycle_test_pid)
    Application.put_env(:jido_gralkor, :client, FailingClient)
    Application.put_env(:jido_gralkor, :lifecycle_test_pid, self())

    on_exit(fn ->
      if previous do
        Application.put_env(:jido_gralkor, :client, previous)
      else
        Application.delete_env(:jido_gralkor, :client)
      end

      if previous_test_pid do
        Application.put_env(:jido_gralkor, :lifecycle_test_pid, previous_test_pid)
      else
        Application.delete_env(:jido_gralkor, :lifecycle_test_pid)
      end
    end)
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
    test "then that thread's buffered-memory flush is scheduled before termination returns" do
      InMemory.set_flush(:ok)
      thread_id = "thread-term"

      s = state(%{__thread__: %{id: thread_id}})

      assert :ok = Lifecycle.terminate(:normal, s)
      assert InMemory.flushes() == [[thread_id]]
    end

    test "and termination does not wait for the scheduled ingestion to complete" do
      use_client(DelayedIngestionClient)
      s = state(%{__thread__: %{id: "thread-delayed"}})

      assert :ok = Lifecycle.terminate(:normal, s)
      assert_receive {:flush_scheduled, "thread-delayed"}
      assert_receive {:ingestion_waiting, ingestion}
      assert Process.alive?(ingestion)

      send(ingestion, :finish_ingestion)
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

  defp use_client(client) do
    previous = Application.get_env(:jido_gralkor, :client)
    previous_test_pid = Application.get_env(:jido_gralkor, :lifecycle_test_pid)
    Application.put_env(:jido_gralkor, :client, client)
    Application.put_env(:jido_gralkor, :lifecycle_test_pid, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:jido_gralkor, :client, previous),
        else: Application.delete_env(:jido_gralkor, :client)

      if previous_test_pid,
        do: Application.put_env(:jido_gralkor, :lifecycle_test_pid, previous_test_pid),
        else: Application.delete_env(:jido_gralkor, :lifecycle_test_pid)
    end)
  end

  describe "when the agent server terminates > while a thread is committed to agent state > if the flush call fails" do
    test "then the failure is logged" do
      use_failing_client()
      thread_id = "thread-fail"

      s = state(%{__thread__: %{id: thread_id}})

      log =
        capture_log(fn ->
          assert :ok = Lifecycle.terminate(:normal, s)
          assert_receive {:failing_flush, ^thread_id}
        end)

      assert log =~ "[gralkor] flush failed"
      assert log =~ ":boom"
    end

    test "and termination completes normally regardless" do
      use_failing_client()
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
