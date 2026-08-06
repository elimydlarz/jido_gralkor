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

  describe "when context rotation is requested > while the agent has a committed thread > while its session flush succeeds" do
    test "then exactly one flush is requested, naming the pre-rotation session id and the caller's flush timeout" do
      InMemory.set_flush_and_await(:ok)
      pid = start_agent()
      seed_thread(pid, "pre-rotation")

      :ok = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)

      assert [["pre-rotation", 1_000]] = InMemory.flush_and_awaits()
    end

    test "and the agent's active session id becomes a new one" do
      InMemory.set_flush_and_await(:ok)
      pid = start_agent()
      seed_thread(pid, "pre-rotation")

      assert :ok = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)

      new_id = committed_thread_id(pid)
      assert is_binary(new_id)
      refute new_id == "pre-rotation"
    end

    test "and the agent process is still running afterwards" do
      InMemory.set_flush_and_await(:ok)
      pid = start_agent()
      seed_thread(pid, "pre-rotation")

      :ok = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)

      assert Process.alive?(pid)
    end
  end

  describe "when context rotation is requested > while the agent has no committed thread" do
    test "then rotation succeeds without requesting any flush" do
      InMemory.set_flush_and_await(:ok)
      pid = start_agent()

      assert :ok = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)
      assert InMemory.flush_and_awaits() == []
    end

    test "and no session is committed as a side effect" do
      InMemory.set_flush_and_await(:ok)
      pid = start_agent()

      assert :ok = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)
      assert committed_thread_id(pid) == nil
    end

    test "and the agent process is still running afterwards" do
      InMemory.set_flush_and_await(:ok)
      pid = start_agent()

      assert :ok = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)
      assert Process.alive?(pid)
    end
  end

  describe "when context rotation is requested > while the agent has a committed thread > if its session flush fails" do
    test "then the failure reason is returned to the caller" do
      InMemory.set_flush_and_await({:error, :backend_down})
      pid = start_agent()
      seed_thread(pid, "pre-rotation")

      assert {:error, :backend_down} =
               ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)
    end

    test "and the active session id is left unchanged" do
      InMemory.set_flush_and_await({:error, :backend_down})
      pid = start_agent()
      seed_thread(pid, "pre-rotation")

      assert {:error, :backend_down} = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)
      assert committed_thread_id(pid) == "pre-rotation"
    end

    test "and the agent process is still running afterwards" do
      InMemory.set_flush_and_await({:error, :backend_down})
      pid = start_agent()
      seed_thread(pid, "pre-rotation")

      assert {:error, :backend_down} = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)
      assert Process.alive?(pid)
    end
  end

  describe "when context rotation is requested > while the agent has a committed thread > if installing the fresh thread fails after flushing" do
    test "then the failure reason is returned to the caller" do
      InMemory.set_flush_and_await(:ok)
      pid = start_agent()
      seed_thread(pid, "pre-rotation")
      force_install_failure(pid)

      assert {:error, _reason} = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)
    end

    test "and the agent process is still running afterwards" do
      InMemory.set_flush_and_await(:ok)
      pid = start_agent()
      seed_thread(pid, "pre-rotation")
      force_install_failure(pid)

      assert {:error, _reason} = ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000)
      assert Process.alive?(pid)
    end
  end

  describe "when context rotation is requested > while the agent has a committed thread > while its session flush succeeds > while recent entries are retained > and the thread holds more" do
    test "then only that many newest entries seed the rotated thread" do
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

  describe "when context rotation is requested > while the agent has a committed thread > while its session flush succeeds > while no entries are retained > and every prior entry was flushed" do
    test "then the rotated thread is empty" do
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

  describe "when context rotation is requested > while the agent has a committed thread > while its session flush succeeds > while entries arrive before installation" do
    test "then each arrives in the fresh thread once" do
      InMemory.set_flush_and_await(:ok)
      pid = start_agent()
      seed_thread_with_entries(pid, "pre-rotation", [%{role: :user, content: "flushed"}])
      pause_second_state_read(pid, self())

      rotation =
        Task.async(fn ->
          ContextRotator.rotate_now(pid, flush_timeout_ms: 1_000, keep_last_n: 0)
        end)

      assert_receive :second_state_read

      append =
        Task.async(fn ->
          append_thread_entry(pid, %{role: :assistant, content: "in-flight"})
        end)

      send(pid, :continue_rotation)

      assert :ok = Task.await(append)
      assert :ok = Task.await(rotation)

      assert [%{payload: %{content: "in-flight"}}] = committed_entries(pid)
    end
  end

  defp force_install_failure(pid) do
    block_second_get_state_reply = fn count, event, _proc_state ->
      case event do
        {:out, {:ok, %Jido.AgentServer.State{}}, _from, _state} ->
          count = count + 1
          if count == 2, do: Process.sleep(6_000)
          count

        _ ->
          count
      end
    end

    assert :ok = :sys.install(pid, {block_second_get_state_reply, 0})
  end

  defp pause_second_state_read(pid, test_pid) do
    pause = fn count, event, _proc_state ->
      case event do
        {:out, {:ok, %Jido.AgentServer.State{}}, _from, _state} ->
          count = count + 1

          if count == 2 do
            send(test_pid, :second_state_read)

            receive do
              :continue_rotation -> :ok
            end
          end

          count

        _ ->
          count
      end
    end

    assert :ok = :sys.install(pid, {pause, 0})
  end

  defp append_thread_entry(pid, payload) do
    :sys.replace_state(pid, fn state ->
      thread = Jido.Thread.append(state.agent.state[:__thread__], [%{kind: :ai_message, payload: payload}])
      put_in(state.agent.state[:__thread__], thread)
    end)

    :ok
  end
end
