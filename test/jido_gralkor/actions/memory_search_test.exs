defmodule JidoGralkor.Actions.MemorySearchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gralkor.Client.InMemory
  alias JidoGralkor.Actions.MemorySearch

  setup do
    InMemory.reset()
    :ok
  end

  test "when the client returns {:ok, memory_block} the result wraps the block" do
    InMemory.set_recall({:ok, "Facts:\n- Eli likes tea"})

    assert {:ok, %{result: "Facts:\n- Eli likes tea"}} =
             MemorySearch.run(%{query: "preferences"}, %{
               agent_id: "01USER",
               session_id: "thr-1",
               agent_name: "TestAgent"
             })
  end

  test "when the client errors the action propagates {:error, reason}" do
    InMemory.set_recall({:error, :boom})

    assert {:error, :boom} =
             MemorySearch.run(%{query: "preferences"}, %{
               agent_id: "01USER",
               session_id: "thr-1",
               agent_name: "TestAgent"
             })
  end

  test "passes sanitized group_id, agent_name, and session_id from context to recall" do
    InMemory.set_recall({:ok, "<gralkor-memory>x</gralkor-memory>"})

    MemorySearch.run(%{query: "q"}, %{
      agent_id: "user-with-hyphens",
      session_id: "thr-xyz",
      agent_name: "Susu"
    })

    assert [[group_id, agent_name, session_id, "q"]] = InMemory.recalls()
    assert group_id == "user_with_hyphens"
    assert agent_name == "Susu"
    assert session_id == "thr-xyz"
  end

  describe "when session_id is absent from context (first query before a thread is committed)" do
    test "returns an explicit non-result message, does not call the client, and logs a warning" do
      log =
        capture_log(fn ->
          assert {:ok, %{result: result}} =
                   MemorySearch.run(%{query: "q"}, %{agent_id: "01USER"})

          assert is_binary(result)
          assert result =~ "NON-RESULT"
          assert result =~ "long-term memory was NOT queried"
        end)

      assert InMemory.recalls() == []
      assert log =~ "[jido_gralkor] memory_search short-circuited"
      assert log =~ "01USER"
      assert log =~ "JIDO_CHANGE_SUGGESTIONS.md"
    end

    test "same when session_id is blank" do
      log =
        capture_log(fn ->
          assert {:ok, %{result: result}} =
                   MemorySearch.run(%{query: "q"}, %{agent_id: "01USER", session_id: ""})

          assert is_binary(result)
          assert result =~ "NON-RESULT"
        end)

      assert InMemory.recalls() == []
      assert log =~ "[jido_gralkor] memory_search short-circuited"
    end
  end
end
