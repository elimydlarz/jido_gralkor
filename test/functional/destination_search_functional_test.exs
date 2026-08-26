defmodule Gralkor.DestinationSearchFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Search

  defmodule SearchStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(destination, operator_id, query, result_type, max_results, opts) do
      send(Application.fetch_env!(:jido_gralkor, :destination_search_test_pid), {
        :destination_search,
        destination.name,
        operator_id,
        query,
        result_type,
        max_results,
        opts
      })

      responses = Application.get_env(:jido_gralkor, :destination_search_responses, %{})
      Map.get(responses, destination.name, {:ok, ["#{destination.name}:#{query}"]})
    end
  end

  setup do
    previous =
      for key <- [
            :destinations,
            :destination_storage,
            :destination_search_test_pid,
            :destination_search_responses
          ],
          into: %{} do
        {key, Application.get_env(:jido_gralkor, key)}
      end

    Application.put_env(:jido_gralkor, :destinations, [
      [name: "first", address: "operator/first"],
      [name: "second", address: "global/second"]
    ])

    Application.put_env(:jido_gralkor, :destination_storage, SearchStorage)
    Application.put_env(:jido_gralkor, :destination_search_test_pid, self())
    Application.put_env(:jido_gralkor, :destination_search_responses, %{})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:jido_gralkor, key)
        {key, value} -> Application.put_env(:jido_gralkor, key, value)
      end)
    end)

    :ok
  end

  describe "when a caller searches memory naming one or more Destinations" do
    test "then every distinct Destination is searched concurrently" do
      assert {:ok,
              [
                %{destination: "first", fact: "first:question"},
                %{destination: "second", fact: "second:question"}
              ]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first", "second"],
                 result_type: :facts
               })

      assert_receive {:destination_search, "first", "operator-one", "question", :facts, 20, []}

      assert_receive {:destination_search, "second", "operator-one", "question", :facts, 20, []}
    end

    test "and results retain the requested Destination order" do
      assert {:ok, [%{destination: "second"}, %{destination: "first"}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["second", "first"]
               })
    end

    test "and the same maximum result count applies independently to every Destination" do
      assert {:ok, _} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first", "second"],
                 max_results: 7
               })

      assert_receive {:destination_search, "first", _, _, _, 7, _}
      assert_receive {:destination_search, "second", _, _, _, 7, _}
    end
  end

  describe "where the same Destination is selected more than once" do
    test "then that Destination is searched only once" do
      assert {:ok, [%{destination: "first"}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first", "first"]
               })

      assert_receive {:destination_search, "first", _, _, _, _, _}
      refute_receive {:destination_search, "first", _, _, _, _, _}
    end
  end

  describe "where no Destination is supplied" do
    test "then the packaged operator-memory Destination is searched" do
      assert {:ok, results} =
               Client.search(%Search{operator_id: "operator-one", query: "question"})

      assert Enum.any?(results, &match?(%{destination: "operator"}, &1))

      assert_receive {:destination_search, "operator", "operator-one", _, _, _, _}
    end

    test "and the packaged global-generalisations Destination is searched" do
      assert {:ok, results} =
               Client.search(%Search{operator_id: "operator-one", query: "question"})

      assert Enum.any?(results, &match?(%{destination: "generalisations"}, &1))

      assert_receive {:destination_search, "generalisations", "operator-one", _, _, _, _}
    end
  end

  describe "where a caller supplies no maximum result count" do
    test "then every resolved Destination receives the default maximum result count of twenty" do
      assert {:ok, _} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first", "second"]
               })

      assert_receive {:destination_search, "first", _, _, _, 20, _}
      assert_receive {:destination_search, "second", _, _, _, 20, _}
    end
  end

  describe "where a caller selects facts" do
    test "then relevant relationships extracted in the selected Destinations are returned" do
      assert {:ok, [%{destination: "first", fact: "first:question"}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first"],
                 result_type: :facts
               })
    end
  end

  describe "where a caller selects nodes" do
    test "then relevant entities extracted in the selected Destinations are returned" do
      assert {:ok, [%{destination: "first", node: "first:question"}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first"],
                 result_type: :nodes
               })
    end
  end

  describe "where a caller selects episodes" do
    test "then relevant episode bodies from the selected Destinations are returned" do
      assert {:ok, [%{destination: "first", episode: "first:question"}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first"],
                 result_type: :episodes
               })
    end
  end

  describe "where a caller selects artefacts" do
    test "then relevant Reflection artefacts from the selected Destinations are returned" do
      artefact = %Gralkor.Reflection.Artefact{
        id: "a-1",
        reflection: "review",
        payload: %{"lesson" => "keep it simple"},
        evidence_ids: ["e-1"]
      }

      Application.put_env(:jido_gralkor, :destination_search_responses, %{
        "first" => {:ok, [artefact]}
      })

      assert {:ok, [%{destination: "first", artefact: ^artefact}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first"],
                 result_type: :artefacts
               })
    end

    test "and every artefact identifies its declaring Reflection" do
      artefact = %Gralkor.Reflection.Artefact{
        id: "a-1",
        reflection: "review",
        payload: %{},
        evidence_ids: []
      }

      Application.put_env(:jido_gralkor, :destination_search_responses, %{
        "first" => {:ok, [artefact]}
      })

      assert {:ok, [%{artefact: %{reflection: "review"}}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first"],
                 result_type: :artefacts
               })
    end
  end

  describe "where a caller filters nodes by entity type" do
    test "then only nodes carrying a selected ontology label are returned" do
      assert {:ok, _} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first"],
                 result_type: :nodes,
                 entity_types: ["Learning"]
               })

      assert_receive {:destination_search, "first", _, _, :nodes, _, [entity_types: ["Learning"]]}
    end
  end

  describe "where a caller filters facts by edge type" do
    test "then only facts carrying a selected ontology relationship type are returned" do
      assert {:ok, _} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first"],
                 result_type: :facts,
                 edge_types: ["LEARNS_FROM"]
               })

      assert_receive {:destination_search, "first", _, _, :facts, _,
                      [edge_types: ["LEARNS_FROM"]]}
    end
  end

  describe "if a selected Destination search fails" do
    test "then the error is returned without manufacturing a partial memory response" do
      Application.put_env(:jido_gralkor, :destination_search_responses, %{
        "second" => {:error, :unavailable}
      })

      assert {:error, :unavailable} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first", "second"]
               })
    end
  end

  describe "if search supplies a maximum result count that is not a positive integer" do
    test "then search fails before any Destination query is started" do
      assert_raise ArgumentError, ~r/max_results.*positive integer/, fn ->
        Client.search(%Search{
          operator_id: "operator-one",
          query: "question",
          destinations: ["first"],
          max_results: 0
        })
      end

      refute_receive {:destination_search, _, _, _, _, _, _}
    end

    test "and the error identifies the invalid maximum result count" do
      assert_raise ArgumentError, ~r/0/, fn ->
        Client.search(%Search{operator_id: "operator-one", query: "question", max_results: 0})
      end
    end
  end

  describe "if search supplies an unsupported result type" do
    test "then search fails before any Destination query is started" do
      assert_raise ArgumentError, ~r/unsupported.*summary/, fn ->
        Client.search(%Search{
          operator_id: "operator-one",
          query: "question",
          destinations: ["first"],
          result_type: :summary
        })
      end

      refute_receive {:destination_search, _, _, _, _, _, _}
    end

    test "and the error identifies the unsupported result type" do
      assert_raise ArgumentError, ~r/summary/, fn ->
        Client.search(%Search{
          operator_id: "operator-one",
          query: "question",
          result_type: :summary
        })
      end
    end
  end

  describe "if search names a Destination that is not registered or packaged" do
    test "then search fails before any Destination query is started" do
      assert_raise ArgumentError, ~r/unknown Destination "missing"/, fn ->
        Client.search(%Search{
          operator_id: "operator-one",
          query: "question",
          destinations: ["first", "missing"]
        })
      end

      refute_receive {:destination_search, _, _, _, _, _, _}
    end

    test "and no valid subset is searched" do
      assert_raise ArgumentError, fn ->
        Client.search(%Search{
          operator_id: "operator-one",
          query: "question",
          destinations: ["first", "missing"]
        })
      end

      refute_receive {:destination_search, "first", _, _, _, _, _}
    end

    test "and the error identifies the unknown Destination" do
      assert_raise ArgumentError, ~r/missing/, fn ->
        Client.search(%Search{
          operator_id: "operator-one",
          query: "question",
          destinations: ["missing"]
        })
      end
    end
  end
end
