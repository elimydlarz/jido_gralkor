defmodule JidoGralkor.Actions.MemorySearchTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  import ExUnit.CaptureLog

  alias JidoGralkor.Actions.MemorySearch

  defmodule RecordingStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(destination, operator_id, query, opts) do
      send(
        Process.whereis(:memory_search_destination_test),
        {:destination_search, destination.name, operator_id, query, Keyword.delete(opts, :limits)}
      )

      source =
        if destination.name == "global",
          do: %{reflection: "generalisations"},
          else: %{lens: destination.name}

      {:ok,
       %{
         facts: [%{fact: "selected #{destination.name} memory", sources: [source]}],
         nodes: [%{name: "#{destination.name} entity", summary: "an entity", attributes: %{}}],
         episodes: [Map.put(source, :content, "#{destination.name} episode")]
       }}
    end
  end

  defmodule LargeResultStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(_destination, _operator_id, _query, _opts) do
      {:ok,
       %{
         facts:
           for index <- 1..200 do
             %{
               fact: "fact #{index} " <> String.duplicate("𝄞", 300),
               sources: [%{lens: "observations"}]
             }
           end,
         nodes: [],
         episodes: []
       }}
    end
  end

  defmodule FailingDestinationStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(_destination, _operator_id, _query, _opts), do: {:error, :boom}
  end

  setup do
    Process.register(self(), :memory_search_destination_test)

    previous =
      for key <- [:destinations, :destination_storage, :lenses], into: %{} do
        {key, Application.get_env(:jido_gralkor, key)}
      end

    Application.put_env(:jido_gralkor, :destination_storage, RecordingStorage)
    Application.put_env(:jido_gralkor, :destinations, [])
    Application.put_env(:jido_gralkor, :lenses, [])

    start_supervised!(
      {JidoGralkor.Runtime,
       owner: self(),
       configuration: %{
         destinations: [[name: "observations"], [name: "decisions"]],
         lenses: [
           [
             name: "observations",
             destination: "observations",
             ingestion: Gralkor.Lens.Ingestion.Store
           ],
           [
             name: "decisions",
             destination: "decisions",
             ingestion: Gralkor.Lens.Ingestion.Store
           ]
         ],
         reflections: []
       }}
    )

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:jido_gralkor, key)
        {key, value} -> Application.put_env(:jido_gralkor, key, value)
      end)
    end)

    :ok
  end

  describe "when the memory search tool runs with a usable query" do
    test "then the existing public Search capability is invoked once" do
      assert {:ok, _result} = run_search(%{query: "launch"})

      assert Enum.sort(received_destination_searches()) ==
               Enum.sort(["personal", "global", "generalisations", "observations", "decisions"])
    end

    test "and the Search request carries the current operator" do
      assert {:ok, _result} = run_search(%{query: "launch", destinations: ["observations"]})

      assert_receive {:destination_search, "observations", "operator-one", "launch", []}
    end

    test "and the Search request carries the usable query unchanged" do
      query = "  launch city  "

      assert {:ok, _result} = run_search(%{query: query, destinations: ["observations"]})

      assert_receive {:destination_search, "observations", "operator-one", ^query, []}
    end

    test "and the Search request carries no entity or relationship type filter" do
      assert {:ok, _result} = run_search(%{query: "launch", destinations: ["observations"]})

      assert_receive {:destination_search, "observations", "operator-one", "launch", []}
    end
  end

  describe "when the memory search tool runs with a usable query > where the tool call supplies no Destination selector" do
    test "then the Search request leaves the Destination selector unrestricted" do
      assert {:ok, _result} = run_search(%{query: "launch"})

      for destination <- ["personal", "global", "generalisations", "observations", "decisions"] do
        assert_receive {:destination_search, ^destination, "operator-one", "launch", []}
      end

      refute_receive {:destination_search, _, _, _, _}
    end
  end

  describe "when the memory search tool runs with a usable query > where the tool call supplies Destinations" do
    test "then the Search request carries the same Destination list" do
      assert {:ok, _result} =
               run_search(%{
                 query: "launch",
                 destinations: ["observations", "decisions"]
               })

      for destination <- ["observations", "decisions"] do
        assert_receive {:destination_search, ^destination, "operator-one", "launch", []}
      end

      refute_receive {:destination_search, _, _, _, _}
    end
  end

  describe "when the memory search tool runs with a usable query > while the tool context identifies an owning AgentServer as the Gralkor runtime target" do
    test "then Search receives that owning AgentServer as its runtime target" do
      prove_runtime_targeted_search()
    end
  end

  describe "when the memory search tool runs with a usable query > while the tool context has no Gralkor runtime target" do
    test "then Search uses the untargeted application compatibility boundary" do
      prove_application_compatibility_search()
    end
  end

  describe "when the memory search tool runs with a usable query > while Search returns results" do
    test "then the action result is readable text with memories under their writers and entities last" do
      assert {:ok, %{result: text}} =
               run_search(%{query: "launch", destinations: ["observations", "global"]})

      assert text ==
               """
               Lens: observations
               - selected observations memory
               - observations episode

               Reflection: generalisations
               - selected global memory
               - global episode

               Entities
               - observations entity: an entity
               - global entity: an entity\
               """
    end

    test "and each named originating Lens or Reflection is identified by its source heading" do
      assert {:ok, %{result: text}} =
               run_search(%{query: "launch", destinations: ["observations", "global"]})

      assert text =~ "Lens: observations\n"
      assert text =~ "Reflection: generalisations\n"
    end
  end

  describe "when the memory search tool runs with a usable query > while Search returns results > while the tool context supplies no byte budget" do
    test "then the response fits within 65,536 bytes" do
      Application.put_env(:jido_gralkor, :destination_storage, LargeResultStorage)

      assert {:ok, %{result: text} = result} =
               run_search(%{query: "launch", destinations: ["observations"]})

      assert text =~ "omitted (response limit)."
      assert byte_size(Jason.encode!(%{ok: true, result: result})) <= 65_536
    end
  end

  describe "when the memory search tool runs with a usable query > if Search fails" do
    test "then the failure reason is returned to the caller unchanged" do
      Application.put_env(
        :jido_gralkor,
        :destination_storage,
        FailingDestinationStorage
      )

      assert {:error, :boom} =
               run_search(%{query: "launch", destinations: ["observations"]})
    end
  end

  describe "when a consumer reads the memory search tool description" do
    test "then it directs the agent to search related observations and generalisations" do
      assert MemorySearch.__action_metadata__().description =~
               "Search related stored observations and generalisations"
    end

    test "and it directs the agent to use the returned memories" do
      assert MemorySearch.__action_metadata__().description =~
               "Use the returned memories"
    end

    test "and it offers a Destination selector but no Lens selector" do
      schema = MemorySearch.__action_metadata__().schema
      assert Keyword.has_key?(schema, :destinations)
      refute Keyword.has_key?(schema, :lenses)
    end
  end

  describe "if the memory search tool runs without a usable query" do
    setup do
      log =
        capture_log(fn ->
          assert {:ok, %{result: result}} = run_search(%{query: ""})
          send(self(), {:result, result})
        end)

      assert_received {:result, result}
      %{log: log, result: result}
    end

    test "then no Search is issued" do
      refute_receive {:destination_search, _, _, _, _}
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
      assert {:ok, %{result: result}} = run_search(%{query: "   "})

      assert result =~ "no query was provided"
      refute_receive {:destination_search, _, _, _, _}
    end
  end

  defp run_search(params) do
    MemorySearch.run(params, %{agent_id: "operator-one", gralkor_runtime: self()})
  end

  defp received_destination_searches do
    receive do
      {:destination_search, destination, _, _, _} ->
        [destination | received_destination_searches()]
    after
      100 -> []
    end
  end

  defp prove_runtime_targeted_search do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(owner, :stop) end)

    start_supervised!(
      {JidoGralkor.Runtime,
       owner: owner,
       configuration: %{
         destinations: [[name: "runtime-notes"]],
         lenses: [],
         reflections: []
       }},
      id: :targeted_runtime
    )

    assert {:ok, _result} =
             MemorySearch.run(
               %{query: "launch", destinations: ["runtime-notes"]},
               %{agent_id: "operator-one", gralkor_runtime: owner}
             )

    assert_receive {:destination_search, "runtime-notes", "operator-one", "launch", []}

    refute_receive {:destination_search, _, _, _, _}
  end

  defp prove_application_compatibility_search do
    configure_application_destinations()

    assert {:ok, _result} =
             MemorySearch.run(
               %{query: "launch", destinations: ["compat-notes"]},
               %{agent_id: "operator-one"}
             )

    assert_receive {:destination_search, "compat-notes", "operator-one", "launch", []}
  end

  defp configure_application_destinations do
    Application.put_env(:jido_gralkor, :destinations, [[name: "compat-notes"]])
    Application.put_env(:jido_gralkor, :lenses, [])
  end
end
