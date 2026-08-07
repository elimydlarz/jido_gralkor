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

  describe "when the memory search tool runs with a query and a committed session > while the backend returns a memory block" do
    test "then the action result carries that block" do
      InMemory.set_recall({:ok, "Facts:\n- Eli likes tea"})

      assert {:ok, %{result: "Facts:\n- Eli likes tea"}} =
               MemorySearch.run(%{query: "preferences"}, %{
                 agent_id: "01USER",
                 session_id: "thr-1",
                 agent_name: "TestAgent"
               })
    end
  end

  describe "when the memory search tool runs with a query and a committed session > if the backend fails" do
    test "then the failure reason is returned to the caller unchanged" do
      InMemory.set_recall({:error, :boom})

      assert {:error, :boom} =
               MemorySearch.run(%{query: "preferences"}, %{
                 agent_id: "01USER",
                 session_id: "thr-1",
                 agent_name: "TestAgent"
               })
    end
  end

  describe "when the memory search tool runs with a query and a committed session" do
    test "then the operator's sanitised group id, the agent name, and the session id from the tool context are passed to the memory backend with the query" do
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
  end

  describe "when the memory search tool runs with a query and a committed session > where the tool context selects Lenses to search" do
    setup do
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

      assert {:ok, %{result: result}} =
               MemorySearch.run(%{query: "launch"}, %{
                 agent_id: "operator-one",
                 session_id: "thread-one",
                 agent_name: "Susu",
                 search_lenses: ["observations"]
               })

      %{result: result}
    end

    test "then the Lens search is used in place of the legacy recall" do
      assert [] = InMemory.recalls()
    end

    test "and the operator's reserved `default` Lens is searched alongside every selected Lens" do
      assert_receive {:lens_search, %{operator_id: "operator-one", lens: %{name: "default"}},
                      "launch", 20}

      assert_receive {:lens_search, %{operator_id: "operator-one", lens: %{name: "observations"}},
                      "launch", 20}
    end

    test "and the action result is JSON identifying the searched Lens that contributed every fact",
         %{
           result: result
         } do
      assert Jason.decode!(result) == [
               %{"lens" => "default", "fact" => "selected local memory"},
               %{"lens" => "observations", "fact" => "selected local memory"}
             ]
    end
  end

  describe "if the memory search tool runs without a usable query" do
    setup do
      log =
        capture_log(fn ->
          assert {:ok, %{result: result}} =
                   MemorySearch.run(%{query: ""}, %{
                     agent_id: "01USER",
                     session_id: "thr-1",
                     agent_name: "Susu"
                   })

          send(self(), {:result, result})
        end)

      assert_received {:result, result}
      %{log: log, result: result}
    end

    test "then no search is issued against any backend" do
      assert InMemory.recalls() == []
    end

    test "and the result explicitly states that no query was provided", %{result: result} do
      assert result =~ "no query was provided"
    end

    test "and the result explicitly states that it is a non-result", %{result: result} do
      assert result =~ "NON-RESULT"
    end

    test "and a warning naming the short-circuit is logged", %{log: log} do
      assert log =~ "[jido_gralkor] memory_search short-circuited"
      assert log =~ "blank query"
    end
  end

  describe "if the memory search tool runs without a usable query > while the query is only whitespace" do
    test "then it counts as no query" do
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

  describe "if the memory search tool runs with no usable session id in its tool context" do
    setup do
      log =
        capture_log(fn ->
          assert {:ok, %{result: result}} =
                   MemorySearch.run(%{query: "q"}, %{agent_id: "01USER"})

          send(self(), {:result, result})
        end)

      assert_received {:result, result}
      %{log: log, result: result}
    end

    test "then no search is issued against any backend" do
      assert InMemory.recalls() == []
    end

    test "and the result explicitly states that long-term memory was not queried", %{
      result: result
    } do
      assert result =~ "long-term memory was NOT queried"
    end

    test "and the result explicitly states that it is a non-result", %{result: result} do
      assert result =~ "NON-RESULT"
    end

    test "and a warning naming the operator is logged", %{log: log} do
      assert log =~ "[jido_gralkor] memory_search short-circuited"
      assert log =~ "01USER"
      assert log =~ "JIDO_CHANGE_SUGGESTIONS.md"
    end
  end

  describe "if the memory search tool runs with no usable session id in its tool context > while the session id is only whitespace" do
    test "then it counts as no session id" do
      log =
        capture_log(fn ->
          assert {:ok, %{result: result}} =
                   MemorySearch.run(%{query: "q"}, %{agent_id: "01USER", session_id: "   "})

          assert is_binary(result)
          assert result =~ "NON-RESULT"
        end)

      assert InMemory.recalls() == []
      assert log =~ "[jido_gralkor] memory_search short-circuited"
    end
  end
end
