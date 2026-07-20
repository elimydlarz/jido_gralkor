defmodule JidoGralkor.Actions.MemorySearchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gralkor.Client.InMemory
  alias JidoGralkor.Actions.MemorySearch

  defmodule LensOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open
  end

  defmodule RecordingStorage do
    @behaviour Gralkor.Lens.Storage

    def add_episode(_store, _content, _source), do: :ok
    def add_episode(_store, _content, _source, _opts), do: :ok
    def remove_episode(_store, _episode_id), do: :ok

    def search(store, query, max_results) do
      send(Process.whereis(:memory_search_lens_test), {:lens_search, store, query, max_results})
      {:ok, ["selected local memory"]}
    end
  end

  setup do
    InMemory.reset()

    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)

    on_exit(fn ->
      if previous_lenses,
        do: Application.put_env(:jido_gralkor, :lenses, previous_lenses),
        else: Application.delete_env(:jido_gralkor, :lenses)

      if previous_storage,
        do: Application.put_env(:jido_gralkor, :lens_storage, previous_storage),
        else: Application.delete_env(:jido_gralkor, :lens_storage)
    end)

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

  test "when context contains search_targets then default and selected Lens results are joined" do
    Process.register(self(), :memory_search_lens_test)
    Application.put_env(:jido_gralkor, :lens_storage, RecordingStorage)

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "observations",
        ontology: LensOntology,
        scope: :operator,
        ingestion: Gralkor.Lens.Ingestion.Store
      ]
    ])

    assert {:ok, %{result: "selected local memory\nselected local memory"}} =
             MemorySearch.run(%{query: "launch"}, %{
               agent_id: "operator-one",
               session_id: "thread-one",
               agent_name: "Susu",
               search_targets: ["observations"]
             })

    assert_receive {:lens_search, %{operator_id: "operator-one", lens: %{name: "default"}},
                    "launch", 10}

    assert_receive {:lens_search, %{operator_id: "operator-one", lens: %{name: "observations"}},
                    "launch", 10}

    assert [] = InMemory.recalls()
  end

  describe "when the query is blank or missing (defensive against forced-tool-call paths)" do
    test "returns an explicit no-query non-result, does not call the client, and logs a warning" do
      log =
        capture_log(fn ->
          assert {:ok, %{result: result}} =
                   MemorySearch.run(%{query: ""}, %{
                     agent_id: "01USER",
                     session_id: "thr-1",
                     agent_name: "Susu"
                   })

          assert result =~ "no query was provided"
          assert result =~ "NON-RESULT"
        end)

      assert InMemory.recalls() == []
      assert log =~ "[jido_gralkor] memory_search short-circuited"
      assert log =~ "blank query"
    end

    test "whitespace-only query is treated as blank" do
      assert {:ok, %{result: result}} =
               MemorySearch.run(%{query: "   "}, %{
                 agent_id: "01USER",
                 session_id: "thr-1",
                 agent_name: "Susu"
               })

      assert result =~ "no query was provided"
      assert InMemory.recalls() == []
    end
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
