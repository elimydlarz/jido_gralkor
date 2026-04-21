defmodule JidoGralkor.Actions.MemoryAddTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gralkor.Client.InMemory
  alias JidoGralkor.Actions.MemoryAdd

  setup do
    InMemory.reset()
    :ok
  end

  test "returns {:ok, %{result: \"Queued for storage.\"}} immediately without waiting on the client" do
    InMemory.set_memory_add(:ok)

    assert {:ok, %{result: "Queued for storage."}} =
             MemoryAdd.run(
               %{content: "Eli prefers tea", source_description: "user preference"},
               %{agent_id: "01USER"}
             )
  end

  test "spawns a background Task that calls the client with sanitized group_id, content, and source_description" do
    InMemory.set_memory_add(:ok)

    MemoryAdd.run(
      %{content: "reflection", source_description: "agent thought"},
      %{agent_id: "user-id"}
    )

    assert eventually(fn -> InMemory.adds() == [["user_id", "reflection", "agent thought"]] end)
  end

  test "if the background Task's client call fails, the failure is logged" do
    InMemory.set_memory_add({:error, :boom})

    log =
      capture_log(fn ->
        MemoryAdd.run(
          %{content: "something", source_description: "agent thought"},
          %{agent_id: "01USER"}
        )

        assert eventually(fn ->
                 InMemory.adds() == [["01USER", "something", "agent thought"]]
               end)

        # Give Logger.error time to flush after the Task's client call.
        Process.sleep(50)
      end)

    assert log =~ "[gralkor] memory_add failed"
    assert log =~ ":boom"
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
end
