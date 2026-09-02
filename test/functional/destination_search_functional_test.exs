defmodule Gralkor.DestinationSearchFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Search

  defmodule SearchStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(destination, operator_id, query, result_type, max_results, opts) do
      test_pid = Application.fetch_env!(:jido_gralkor, :destination_search_test_pid)

      send(test_pid, {
        :destination_search,
        destination.name,
        operator_id,
        query,
        result_type,
        max_results,
        opts
      })

      if Application.get_env(:jido_gralkor, :destination_search_barrier, false) do
        send(test_pid, {:destination_search_started, destination.name, self()})

        receive do
          :continue_destination_search -> :ok
        end
      end

      responses = Application.get_env(:jido_gralkor, :destination_search_responses, %{})
      Map.get(responses, destination.name, {:ok, ["#{destination.name}:#{query}"]})
    end
  end

  setup do
    previous =
      for key <- [
            :destinations,
            :destination_storage,
            :lens_storage,
            :reflection_storage,
            :destination_search_test_pid,
            :destination_search_responses,
            :destination_search_barrier
          ],
          into: %{} do
        {key, Application.get_env(:jido_gralkor, key)}
      end

    Application.put_env(:jido_gralkor, :destinations, [
      [name: "first"],
      [name: "second"]
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
      Application.put_env(:jido_gralkor, :destination_search_barrier, true)

      search =
        Task.async(fn ->
          Client.search(%Search{
            operator_id: "operator-one",
            query: "question",
            destinations: ["first", "second"],
            result_type: :facts
          })
        end)

      assert_receive {:destination_search_started, "first", first}
      assert_receive {:destination_search_started, "second", second}
      send(first, :continue_destination_search)
      send(second, :continue_destination_search)

      assert {:ok, _results} = Task.await(search)
    end

    test "and results retain the requested Destination order" do
      assert {:ok, [%{destination: "second"}, %{destination: "first"}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["second", "first"],
                 result_type: :facts
               })
    end

    test "and every result identifies its Destination" do
      Application.put_env(:jido_gralkor, :destination_search_responses, %{
        "first" => {:ok, ["one", "two"]},
        "second" => {:ok, ["three"]}
      })

      assert {:ok,
              [
                %{destination: "first", fact: "one"},
                %{destination: "first", fact: "two"},
                %{destination: "second", fact: "three"}
              ]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first", "second"],
                 result_type: :facts
               })
    end

    test "and the same maximum result count applies independently to every Destination" do
      assert {:ok, _} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first", "second"],
                 result_type: :facts,
                 max_results: 7
               })

      assert_receive {:destination_search, "first", _, _, _, 7, _}
      assert_receive {:destination_search, "second", _, _, _, 7, _}
    end

    test "and no unselected Destination can contribute a result" do
      Application.put_env(:jido_gralkor, :destination_search_responses, %{
        "first" => {:ok, ["selected"]},
        "second" => {:ok, ["unselected"]}
      })

      assert {:ok, [%{destination: "first", fact: "selected"}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first"],
                 result_type: :facts
               })

      refute_receive {:destination_search, "second", _, _, _, _, _}
    end
  end

  describe "where a caller selects the `operator` Destination" do
    test "then another operator's graph cannot contribute a result" do
      use_in_memory_storage()
      assert :ok = add_episode("operator", "operator-one", "private memory")

      assert {:ok, []} =
               Client.search(%Search{
                 operator_id: "operator-two",
                 query: "private",
                 destinations: ["operator"]
               })
    end
  end

  describe "where a caller selects any other Destination" do
    test "then results saved by every operator to that Destination's one graph can contribute" do
      use_in_memory_storage()
      assert :ok = add_episode("first", "operator-one", "shared memory")

      assert {:ok, [%{destination: "first", fact: "shared memory"}]} =
               Client.search(%Search{
                 operator_id: "operator-two",
                 query: "shared",
                 destinations: ["first"],
                 result_type: :facts
               })
    end
  end

  describe "where the same Destination is selected more than once" do
    test "then that Destination is searched only once" do
      assert {:ok, [%{destination: "first"}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first", "first"],
                 result_type: :facts
               })

      assert_receive {:destination_search, "first", _, _, _, _, _}
      refute_receive {:destination_search, "first", _, _, _, _, _}
    end
  end

  describe "where neither Destinations nor Lenses are supplied" do
    test "then every accessible registered Destination is searched" do
      assert {:ok, results} =
               Client.search(%Search{operator_id: "operator-one", query: "question"})

      assert Enum.map(results, & &1.destination) == ["operator", "global", "first", "second"]

      for destination <- ["operator", "global", "first", "second"] do
        assert_receive {:destination_search, ^destination, "operator-one", "question", :episodes,
                        20, []}
      end
    end
  end

  describe "where a caller supplies no maximum result count" do
    test "then every resolved Destination receives the default maximum result count of twenty" do
      assert {:ok, _} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first", "second"],
                 result_type: :facts
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

      start_supervised!(Gralkor.Lens.Storage.InMemory)

      Application.put_env(
        :jido_gralkor,
        :destination_storage,
        Gralkor.Destination.Storage.InMemory
      )

      Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

      destination = Gralkor.Destination.Registry.fetch!("first")

      store = %Gralkor.Lens.Store{
        operator_id: "operator-one",
        lens: %Gralkor.Lens.Replaceable{
          name: "first-graph",
          destination: destination,
          graph_format: :property_graph
        }
      }

      graph = %Gralkor.Graph{
        format: :property_graph,
        data: %{
          nodes: [%{id: "atlas", labels: ["Project"], properties: %{title: "Atlas"}}],
          relationships: []
        }
      }

      assert :ok = Gralkor.Lens.Store.replace_graph(store, graph)

      assert {:ok, [%{destination: "first", node: %{id: "atlas"}}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "Atlas",
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

      start_supervised!(Gralkor.Lens.Storage.InMemory)

      Application.put_env(
        :jido_gralkor,
        :destination_storage,
        Gralkor.Destination.Storage.InMemory
      )

      Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

      destination = Gralkor.Destination.Registry.fetch!("first")

      store = %Gralkor.Lens.Store{
        operator_id: "operator-one",
        lens: %Gralkor.Lens{
          name: "first",
          destination: destination,
          ontology: Gralkor.DefaultOntology,
          ingestion: String
        }
      }

      assert :ok = Gralkor.Lens.Store.add(store, "stored episode", "functional")

      assert {:ok,
              [
                %{
                  destination: "first",
                  episode: %{content: "stored episode", lens: "first"}
                }
              ]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "stored",
                 destinations: ["first"],
                 result_type: :episodes
               })
    end

    test "then a Reflection episode identifies the Reflection that wrote it" do
      use_in_memory_storage()

      destination = Gralkor.Destination.Registry.fetch!("first")

      reflection = %Gralkor.Reflection{
        name: "review",
        destination: destination,
        ontology: Gralkor.DefaultOntology,
        chain_of_thought: %Gralkor.Reflection.ChainOfThought{path: "functional", steps: []}
      }

      artefact = %Gralkor.Reflection.Artefact{
        id: "review-one",
        reflection: "review",
        payload: %{"lesson" => "keep it simple"}
      }

      assert :ok = Gralkor.Reflection.Store.put(reflection, "operator-one", artefact)
      content = Jason.encode!(Map.from_struct(artefact))

      assert {:ok,
              [
                %{
                  destination: "first",
                  episode: %{content: ^content, reflection: "review"}
                }
              ]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "simple",
                 destinations: ["first"]
               })
    end
  end

  describe "where a caller selects artefacts" do
    test "then relevant Reflection artefacts from the selected Destinations are returned" do
      artefact = %Gralkor.Reflection.Artefact{
        id: "a-1",
        reflection: "review",
        payload: %{"lesson" => "keep it simple"}
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
        payload: %{}
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
                 destinations: ["first", "second"],
                 result_type: :facts
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

  defp use_in_memory_storage do
    start_supervised!(Gralkor.Lens.Storage.InMemory)
    start_supervised!(Gralkor.Reflection.Storage.InMemory)
    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)
    Application.put_env(
      :jido_gralkor,
      :reflection_storage,
      Gralkor.Reflection.Storage.InMemory
    )

    Application.put_env(
      :jido_gralkor,
      :destination_storage,
      Gralkor.Destination.Storage.InMemory
    )
  end

  defp add_episode(destination_name, operator_id, content) do
    destination = Gralkor.Destination.Registry.fetch!(destination_name)

    store = %Gralkor.Lens.Store{
      operator_id: operator_id,
      lens: %Gralkor.Lens{
        name: "writer",
        destination: destination,
        ontology: Gralkor.DefaultOntology,
        ingestion: String
      }
    }

    Gralkor.Lens.Store.add(store, content, "functional")
  end
end
