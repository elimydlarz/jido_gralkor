defmodule JidoGralkor.LifecycleIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 10_000

  alias Gralkor.Client.InMemory
  alias JidoGralkor.LifecycleTestAgent
  alias JidoGralkor.LifecycleTestJido

  setup do
    InMemory.reset()
    InMemory.set_flush(:ok)

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

  defp start_agent do
    id = "agent-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Jido.start_agent(
        LifecycleTestJido,
        LifecycleTestAgent,
        id: id,
        lifecycle_mod: JidoGralkor.Lifecycle
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

  describe "when a running agent server is stopped gracefully > while a thread is committed to its agent state" do
    test "then that thread's buffered memory is flushed exactly once, under the committed thread id" do
      {pid, _id} = start_agent()
      thread_id = "thread-stop"
      seed_thread(pid, thread_id)

      :ok = GenServer.stop(pid, :shutdown, 5_000)

      assert eventually(fn -> InMemory.flushes() == [[thread_id]] end)
    end
  end

  describe "when a running agent server is stopped gracefully > while no thread is committed to its agent state" do
    test "then no flush is requested at all" do
      {pid, _id} = start_agent()

      :ok = GenServer.stop(pid, :shutdown, 5_000)

      Process.sleep(50)
      assert InMemory.flushes() == []
    end
  end
end
