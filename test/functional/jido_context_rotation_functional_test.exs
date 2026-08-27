defmodule JidoGralkor.ContextRotationFunctionalTest do
  use ExUnit.Case, async: false

  alias Gralkor.Client.InMemory
  alias JidoGralkor.ContextRotator
  alias JidoGralkor.LifecycleTestAgent
  alias JidoGralkor.LifecycleTestJido

  @moduletag :functional

  setup do
    InMemory.reset()
    {:ok, jido} = Jido.start(name: LifecycleTestJido, otp_app: :jido_gralkor)

    on_exit(fn ->
      if Process.alive?(jido) do
        try do
          GenServer.stop(jido, :normal, 5_000)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    :ok
  end

  describe "when an application rotates a running agent whose committed thread flushes successfully" do
    test "then the application receives success" do
      InMemory.set_flush_and_await(:ok)
      pid = start_agent()
      seed_thread(pid, "before-rotation")

      assert :ok = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)
    end

    test "and the committed session is flushed with the caller's timeout" do
      InMemory.set_flush_and_await(:ok)
      pid = start_agent()
      seed_thread(pid, "before-rotation")

      assert :ok = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)
      assert InMemory.flush_and_awaits() == [["before-rotation", 1_000]]
    end

    test "and the active session is replaced" do
      InMemory.set_flush_and_await(:ok)
      pid = start_agent()
      seed_thread(pid, "before-rotation")

      assert :ok = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)
      refute thread_id(pid) == "before-rotation"
    end

    test "and the fresh session retains only the requested newest committed entries" do
      InMemory.set_flush_and_await(:ok)
      pid = start_agent()

      seed_thread(pid, "before-rotation", [
        %{role: :user, content: "first"},
        %{role: :assistant, content: "second"},
        %{role: :user, content: "third"}
      ])

      assert :ok =
               ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000, keep_last_n: 2)

      assert Enum.map(thread_entries(pid), & &1.payload.content) == ["second", "third"]
    end
  end

  describe "when an application rotates a running agent whose committed thread fails to flush" do
    test "then the application receives the failure" do
      InMemory.set_flush_and_await({:error, :unavailable})
      pid = start_agent()
      seed_thread(pid, "before-rotation")

      assert {:error, :unavailable} =
               ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)
    end

    test "and the active session remains unchanged" do
      InMemory.set_flush_and_await({:error, :unavailable})
      pid = start_agent()
      seed_thread(pid, "before-rotation")

      assert {:error, :unavailable} =
               ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)

      assert thread_id(pid) == "before-rotation"
    end
  end

  describe "when an application rotates a running agent with no committed thread" do
    test "then the application receives success" do
      pid = start_agent()

      assert :ok = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)
    end

    test "and no flush is requested" do
      pid = start_agent()

      assert :ok = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)
      assert InMemory.flush_and_awaits() == []
    end

    test "and no session is committed" do
      pid = start_agent()

      assert :ok = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)
      assert thread_id(pid) == nil
    end
  end

  describe "if an application asks to rotate an agent whose state cannot be read" do
    test "then the application receives a state-read failure rather than false success" do
      pid = spawn(fn -> :ok end)
      monitor = Process.monitor(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}

      assert {:error, {:state_read_failed, _reason}} = ContextRotator.rotate_now(pid)
      assert InMemory.flush_and_awaits() == []
    end
  end

  defp start_agent do
    {:ok, pid} =
      Jido.start_agent(
        LifecycleTestJido,
        LifecycleTestAgent,
        id: "agent-#{System.unique_integer([:positive])}"
      )

    pid
  end

  defp seed_thread(pid, id, payloads \\ []) do
    :sys.replace_state(pid, fn state ->
      entries = Enum.map(payloads, &%{kind: :ai_message, payload: &1})
      thread = Jido.Thread.append(Jido.Thread.new(id: id), entries)
      put_in(state.agent.state[:__thread__], thread)
    end)
  end

  defp thread_entries(pid) do
    {:ok, state} = Jido.AgentServer.state(pid)
    state.agent.state[:__thread__].entries
  end

  defp thread_id(pid) do
    {:ok, state} = Jido.AgentServer.state(pid)

    case state.agent.state[:__thread__] do
      %{id: id} -> id
      nil -> nil
    end
  end
end
