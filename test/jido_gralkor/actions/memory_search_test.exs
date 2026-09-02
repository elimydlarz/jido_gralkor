defmodule JidoGralkor.Actions.MemorySearchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias JidoGralkor.Actions.MemorySearch

  defmodule RecordingStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(destination, operator_id, query, result_type, max_results, opts) do
      send(
        Process.whereis(:memory_search_destination_test),
        {:destination_search, destination.name, operator_id, query, result_type, max_results,
         opts}
      )

      episode =
        if destination.name == "global" do
          %{content: ~s({"payload":{"generalisations":[]}}), reflection: "generalisations"}
        else
          %{content: "selected #{destination.name} memory", lens: destination.name}
        end

      {:ok, [episode]}
    end
  end

  defmodule FailingDestinationStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(_destination, _operator_id, _query, _result_type, _max_results, _opts),
      do: {:error, :boom}
  end

  setup do
    Process.register(self(), :memory_search_destination_test)

    previous =
      for key <- [:destinations, :destination_storage, :lenses], into: %{} do
        {key, Application.get_env(:jido_gralkor, key)}
      end

    Application.put_env(:jido_gralkor, :destination_storage, RecordingStorage)

    Application.put_env(:jido_gralkor, :destinations, [
      [name: "observations"],
      [name: "decisions"]
    ])

    Application.put_env(:jido_gralkor, :lenses, [
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
    ])

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
      assert {:ok, _result} = run_search(%{query: "launch", destinations: ["observations"]})

      assert_receive {:destination_search, "observations", _, _, _, _, _}
      refute_receive {:destination_search, _, _, _, _, _, _}
    end

    test "and the Search request carries the current operator" do
      assert {:ok, _result} = run_search(%{query: "launch", destinations: ["observations"]})

      assert_receive {:destination_search, "observations", "operator-one", "launch", :episodes,
                      20, []}
    end

    test "and the Search request carries the usable query unchanged" do
      query = "  launch city  "

      assert {:ok, _result} = run_search(%{query: query, destinations: ["observations"]})

      assert_receive {:destination_search, "observations", "operator-one", ^query, :episodes, 20,
                      []}
    end

    test "and the Search request asks for stored episodes" do
      assert {:ok, _result} = run_search(%{query: "launch", destinations: ["observations"]})

      assert_receive {:destination_search, "observations", "operator-one", "launch", :episodes,
                      20, []}
    end

    test "where neither selector is supplied then both selector dimensions remain unrestricted" do
      assert {:ok, _result} = run_search(%{query: "launch"})

      for destination <- ["operator", "global", "observations", "decisions"] do
        assert_receive {:destination_search, ^destination, "operator-one", "launch", :episodes,
                        20, []}
      end

      refute_receive {:destination_search, _, _, _, _, _, _}
    end

    test "where the tool call supplies Destinations then the Search request carries the same Destination list" do
      assert {:ok, _result} =
               run_search(%{
                 query: "launch",
                 destinations: ["observations", "decisions"]
               })

      for destination <- ["observations", "decisions"] do
        assert_receive {:destination_search, ^destination, "operator-one", "launch", :episodes,
                        20, []}
      end

      refute_receive {:destination_search, _, _, _, _, _, _}
    end

    test "where the tool call supplies Lenses then the Search request carries the same Lens list" do
      assert {:ok, _result} = run_search(%{query: "launch", lenses: ["decisions"]})

      for destination <- ["operator", "global", "observations", "decisions"] do
        assert_receive {:destination_search, ^destination, "operator-one", "launch", :episodes,
                        20, [lenses: ["decisions"]]}
      end

      refute_receive {:destination_search, _, _, _, _, _, _}
    end

    test "where the tool call supplies Destinations and Lenses then the Search request carries both lists unchanged" do
      assert {:ok, _result} =
               run_search(%{
                 query: "launch",
                 destinations: ["observations", "decisions"],
                 lenses: ["decisions", "observations"]
               })

      for destination <- ["observations", "decisions"] do
        assert_receive {:destination_search, ^destination, "operator-one", "launch", :episodes,
                        20, [lenses: ["decisions", "observations"]]}
      end

      refute_receive {:destination_search, _, _, _, _, _, _}
    end

    test "while Search returns results then the action JSON preserves Destination and writer provenance" do
      assert {:ok, %{result: result}} =
               run_search(%{
                 query: "launch",
                 destinations: ["observations", "global"]
               })

      assert Jason.decode!(result) == [
               %{
                 "destination" => "observations",
                 "episode" => %{
                   "content" => "selected observations memory",
                   "lens" => "observations"
                 }
               },
               %{
                 "destination" => "global",
                 "episode" => %{
                   "content" => ~s({"payload":{"generalisations":[]}}),
                   "reflection" => "generalisations"
                 }
               }
             ]
    end

    test "if Search fails then the failure reason is returned to the caller unchanged" do
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
      refute_receive {:destination_search, _, _, _, _, _, _}
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

    test "while the query is only whitespace then it counts as no query" do
      assert {:ok, %{result: result}} = run_search(%{query: "   "})

      assert result =~ "no query was provided"
      refute_receive {:destination_search, _, _, _, _, _, _}
    end
  end

  defp run_search(params) do
    MemorySearch.run(params, %{agent_id: "operator-one"})
  end
end
