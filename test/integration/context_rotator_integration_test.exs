defmodule JidoGralkor.ContextRotatorIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 10_000

  alias Gralkor.Client.InMemory
  alias JidoGralkor.ContextRotator
  alias JidoGralkor.LifecycleTestAgent
  alias JidoGralkor.LifecycleTestJido

  setup do
    InMemory.reset()

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
        id: id
      )

    pid
  end

  defp seed_thread(pid, thread_id) do
    :sys.replace_state(pid, fn state ->
      put_in(state.agent.state[:__thread__], Jido.Thread.new(id: thread_id))
    end)
  end

  defp seed_thread_with_entries(pid, thread_id, entry_payloads) do
    entries =
      Enum.map(entry_payloads, fn payload ->
        %{kind: :ai_message, payload: payload}
      end)

    :sys.replace_state(pid, fn state ->
      thread = Jido.Thread.append(Jido.Thread.new(id: thread_id), entries)
      put_in(state.agent.state[:__thread__], thread)
    end)
  end

  defp committed_thread_id(pid) do
    {:ok, server_state} = Jido.AgentServer.state(pid)

    case server_state.agent.state[:__thread__] do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp committed_entries(pid) do
    {:ok, server_state} = Jido.AgentServer.state(pid)

    case server_state.agent.state[:__thread__] do
      %{entries: entries} -> entries
      _ -> []
    end
  end

  describe "while a thread is committed, when rotate_now/2 is called and the flush returns :ok" do
    test "then the agent's active session id changes and the agent process is still running" do
      InMemory.set_flush_and_await(:ok)
      pid = start_agent()
      seed_thread(pid, "pre-rotation")

      assert :ok = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)

      new_id = committed_thread_id(pid)
      assert is_binary(new_id)
      refute new_id == "pre-rotation"
      assert Process.alive?(pid)
    end

    test "then InMemory records one flush_and_await for the pre-rotation session id and the configured flush timeout" do
      InMemory.set_flush_and_await(:ok)
      pid = start_agent()
      seed_thread(pid, "pre-rotation")

      :ok = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)

      assert [["pre-rotation", 1_000]] = InMemory.flush_and_awaits()
    end
  end

  describe "while no thread is committed, when rotate_now/2 is called" do
    test "then it returns :ok without invoking the flush and the agent process is still running" do
      InMemory.set_flush_and_await(:ok)
      pid = start_agent()

      assert :ok = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)
      assert InMemory.flush_and_awaits() == []
      assert Process.alive?(pid)
      assert committed_thread_id(pid) == nil
    end
  end

  describe "while a thread is committed, when rotate_now/2 is called and the flush fails" do
    test "then the error is propagated as {:error, reason} and the active session id is unchanged and the agent process is still running" do
      InMemory.set_flush_and_await({:error, :backend_down})
      pid = start_agent()
      seed_thread(pid, "pre-rotation")

      assert {:error, :backend_down} =
               ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)

      assert committed_thread_id(pid) == "pre-rotation"
      assert Process.alive?(pid)
    end
  end

  describe "while a thread has more entries than keep_last_n and the flush returns :ok" do
    test "the rotated thread is seeded with the most recent keep_last_n entries (everything before them is dropped from the in-memory context)" do
      InMemory.set_flush_and_await(:ok)
      pid = start_agent()

      seed_thread_with_entries(pid, "pre-rotation", [
        %{role: :user, content: "first"},
        %{role: :assistant, content: "second"},
        %{role: :user, content: "third"},
        %{role: :assistant, content: "fourth"},
        %{role: :user, content: "fifth"}
      ])

      :ok = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000, keep_last_n: 2)

      entries = committed_entries(pid)
      assert length(entries) == 2

      payloads = Enum.map(entries, & &1.payload)
      assert Enum.map(payloads, & &1.content) == ["fourth", "fifth"]
    end
  end

  describe "while a thread is committed and keep_last_n is 0" do
    test "the rotated thread starts empty when all pre-rotation entries were in the flushed set (nothing to preserve)" do
      InMemory.set_flush_and_await(:ok)
      pid = start_agent()

      seed_thread_with_entries(pid, "pre-rotation", [
        %{role: :user, content: "first"},
        %{role: :assistant, content: "second"}
      ])

      :ok = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000, keep_last_n: 0)

      assert committed_entries(pid) == []
    end
  end

end
