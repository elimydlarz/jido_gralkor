defmodule JidoGralkor.Actions.MemorySearchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias JidoGralkor.Actions.MemorySearch

  use Mimic

  alias Gralkor.Client
  alias Gralkor.Search
  alias JidoGralkor.MemorySearchPresentation

  setup :verify_on_exit!

  setup do
    stub(Client, :search, fn request ->
      send(self(), {:search, :compatibility, request})
      {:ok, search_results()}
    end)

    stub(Client, :search, fn owner, request ->
      send(self(), {:search, owner, request})
      {:ok, search_results()}
    end)

    stub(MemorySearchPresentation, :validate_max_bytes!, fn bytes -> bytes end)

    stub(MemorySearchPresentation, :for_model, fn results, bytes ->
      send(self(), {:presentation, results, bytes})
      {:ok, %{result: results, omissions: %{byte_budget: 0}}}
    end)

    :ok
  end

  describe "when the memory search tool runs with a usable query" do
    test "then the existing public Search capability is invoked once" do
      assert {:ok, _result} = run_search(%{query: "launch", destinations: ["observations"]})

      assert_receive {:search, :compatibility, %Search{}}
      refute_receive {:search, _, _}
    end

    test "and the Search request carries the current operator" do
      assert {:ok, _result} = run_search(%{query: "launch", destinations: ["observations"]})

      assert_receive {:search, :compatibility,
                      %Search{operator_id: "operator-one", query: "launch", result_type: :episodes}}
    end

    test "and the Search request carries the usable query unchanged" do
      query = "  launch city  "

      assert {:ok, _result} = run_search(%{query: query, destinations: ["observations"]})

      assert_receive {:search, :compatibility, %Search{query: ^query}}
    end

    test "and the Search request asks for stored episodes" do
      assert {:ok, _result} = run_search(%{query: "launch", destinations: ["observations"]})

      assert_receive {:search, :compatibility,
                      %Search{operator_id: "operator-one", query: "launch", result_type: :episodes}}
    end
  end

  describe "when the memory search tool runs with a usable query > where the tool call supplies no Destination selector > while the tool call supplies no Lens selector" do
    test "then the Search request leaves both selector dimensions unrestricted" do
      assert {:ok, _result} = run_search(%{query: "launch"})

      assert_receive {:search, :compatibility, %Search{destinations: [], lenses: []}}

      refute_receive {:search, _, _}
    end
  end

  describe "when the memory search tool runs with a usable query > where the tool call supplies Destinations" do
    test "then the Search request carries the same Destination list" do
      assert {:ok, _result} =
               run_search(%{
                 query: "launch",
                 destinations: ["observations", "decisions"]
               })

      assert_receive {:search, :compatibility,
                      %Search{destinations: ["observations", "decisions"]}}

      refute_receive {:search, _, _}
    end
  end

  describe "when the memory search tool runs with a usable query > where the tool call supplies Lenses" do
    test "then the Search request carries the same Lens list" do
      assert {:ok, _result} = run_search(%{query: "launch", lenses: ["decisions"]})

      assert_receive {:search, :compatibility, %Search{lenses: ["decisions"]}}

      refute_receive {:search, _, _}
    end
  end

  describe "when the memory search tool runs with a usable query > where the tool call supplies Destinations and Lenses" do
    test "then the Search request carries both lists unchanged" do
      assert {:ok, _result} =
               run_search(%{
                 query: "launch",
                 destinations: ["observations", "decisions"],
                 lenses: ["decisions", "observations"]
               })

      assert_receive {:search, :compatibility,
                      %Search{destinations: ["observations", "decisions"],
                              lenses: ["decisions", "observations"]}}

      refute_receive {:search, _, _}
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
    test "then the action result is the structured result list" do
      assert {:ok, %{result: result}} =
               run_search(%{
                 query: "launch",
                 destinations: ["observations", "global"]
               })

      assert [
               %{
                 destination: "observations",
                 episode: %{
                   content: "selected observations memory",
                   lens: "observations"
                 }
               },
               %{
                 destination: "global",
                 episode: %{
                   artefact: %{id: "generalisation-one", payload: %{"generalisations" => []}},
                   reflection: "generalisations"
                 }
               }
             ] = result

      assert_receive {:presentation, ^result, 65_536}
    end

    test "and every returned episode's Destination and originating Lens or declaring Reflection remain identifiable" do
      assert {:ok, %{result: result}} =
               run_search(%{
                 query: "launch",
                 destinations: ["observations", "global"]
               })

      assert [
               %{
                 destination: "observations",
                 episode: %{lens: "observations"}
               },
               %{
                 destination: "global",
                 episode: %{reflection: "generalisations"}
               }
             ] = result
    end
  end

  describe "when the memory search tool runs with a usable query > if Search fails" do
    test "then the failure reason is returned to the caller unchanged" do
      expect(Client, :search, fn %Search{} -> {:error, :boom} end)
      reject(MemorySearchPresentation, :for_model, 2)

      assert {:error, :boom} =
               run_search(%{query: "launch", destinations: ["observations"]})
    end
  end

  describe "when a consumer reads the memory search tool description" do
    test "then it directs the agent to search related observations and generalisations" do
      assert MemorySearch.__action_metadata__().description =~
               "Search related stored observations and generalisations"
    end

    test "and it directs the agent to apply relevant generalisations in light of their evolution histories and related observations" do
      assert MemorySearch.__action_metadata__().description =~
               "Apply relevant generalisations in light of their evolution histories and related observations"
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
      refute_receive {:search, _, _}
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
      refute_receive {:search, _, _}
    end
  end

  defp run_search(params) do
    MemorySearch.run(params, %{agent_id: "operator-one"})
  end

  defp prove_runtime_targeted_search do
    owner = self()
    reject(Client, :search, 1)

    assert {:ok, _result} =
             MemorySearch.run(
               %{query: "launch", destinations: ["runtime-notes"]},
               %{agent_id: "operator-one", gralkor_runtime: owner}
             )

    assert_receive {:search, ^owner,
                    %Search{operator_id: "operator-one", query: "launch",
                            destinations: ["runtime-notes"], result_type: :episodes}}
    refute_receive {:search, _, _}
  end

  defp prove_application_compatibility_search do
    reject(Client, :search, 2)

    assert {:ok, _result} =
             MemorySearch.run(
               %{query: "launch", destinations: ["compat-notes"]},
               %{agent_id: "operator-one"}
             )

    assert_receive {:search, :compatibility,
                    %Search{operator_id: "operator-one", query: "launch",
                            destinations: ["compat-notes"], result_type: :episodes}}
    refute_receive {:search, _, _}
  end

  defp search_results do
    [
      %{destination: "observations",
        episode: %{content: "selected observations memory", lens: "observations"}},
      %{destination: "global",
        episode: %{artefact: %{id: "generalisation-one", payload: %{"generalisations" => []}},
                   reflection: "generalisations"}}
    ]
  end
end
