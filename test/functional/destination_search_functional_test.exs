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
            :lenses,
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

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "first-alpha",
        destination: "first",
        ingestion: Gralkor.Lens.Ingestion.Store
      ],
      [
        name: "first-beta",
        destination: "first",
        ingestion: Gralkor.Lens.Ingestion.Store
      ],
      [
        name: "second-beta",
        destination: "second",
        ingestion: Gralkor.Lens.Ingestion.Store
      ]
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

  describe "when a caller searches memory" do
    test "then every distinct selected Destination is searched concurrently" do
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

    test "and results retain the selected Destination order" do
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

    test "and unselected writers cannot consume the result allowance for selected-Lens results" do
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

  describe "where the selected Destinations include `operator`" do
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

  describe "where the selected Destinations include any shared Destination" do
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

  describe "when a caller searches memory > where the Destination selector is omitted or empty" do
    test "and the Lens selector is omitted or empty" do
      assert {:ok, _results} =
               Client.search(%Search{operator_id: "operator-one", query: "question"})

      assert_receive {:destination_search, "operator", _, _, _, _, []}
    end

    test "then every accessible registered Destination is selected" do
      assert {:ok, results} =
               Client.search(%Search{operator_id: "operator-one", query: "question"})

      assert Enum.map(results, & &1.destination) == ["operator", "global", "first", "second"]

      for destination <- ["operator", "global", "first", "second"] do
        assert_receive {:destination_search, ^destination, "operator-one", "question", :episodes,
                        20, []}
      end
    end

    test "and results written by every Lens or Destination artefact output can contribute" do
      use_in_memory_storage()
      assert :ok = add_episode("operator", "operator-one", "current operator", "operator")
      assert :ok = add_episode("operator", "operator-two", "other operator", "operator")

      assert {:ok,
              [
                %{
                  destination: "operator",
                  episode: %{content: "current operator", lens: "operator"}
                }
              ]} =
               Client.search(%Search{operator_id: "operator-one", query: "operator"})
    end
  end

  describe "when a caller searches memory > where the Destination selector is omitted or empty > while one or more Lenses are supplied" do
    test "then every accessible registered Destination is selected" do
      assert {:ok, _results} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 lenses: ["first-alpha"]
               })

      for destination <- ["operator", "global", "first", "second"] do
        assert_receive {:destination_search, ^destination, _, _, _, _, _}
      end
    end

    test "and results originating in any supplied Lens can contribute" do
      use_in_memory_storage()
      assert :ok = add_episode("first", "operator-one", "alpha memory", "first-alpha")
      assert :ok = add_episode("first", "operator-one", "unselected memory", "first-beta")
      assert :ok = add_episode("second", "operator-one", "beta memory", "second-beta")

      assert {:ok,
              [
                %{
                  destination: "first",
                  episode: %{content: "alpha memory", lens: "first-alpha"}
                },
                %{
                  destination: "second",
                  episode: %{content: "beta memory", lens: "second-beta"}
                }
              ]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 lenses: ["first-alpha", "second-beta"]
               })
    end

    test "and unselected writers cannot consume the result allowance for selected-Lens results" do
      use_in_memory_storage()
      assert :ok = add_episode("first", "operator-one", "unselected one", "first-beta")
      assert :ok = add_episode("first", "operator-one", "unselected two", "first-beta")
      assert :ok = add_episode("first", "operator-one", "selected one", "first-alpha")
      assert :ok = add_episode("first", "operator-one", "selected two", "first-alpha")

      assert {:ok,
              [
                %{episode: %{content: "selected one", lens: "first-alpha"}},
                %{episode: %{content: "selected two", lens: "first-alpha"}}
              ]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 destinations: ["first"],
                 lenses: ["first-alpha"],
                 max_results: 2
               })
    end

    test "but no result from another Lens or from a Destination artefact output can contribute" do
      use_in_memory_storage()
      assert :ok = add_episode("first", "operator-one", "selected memory", "first-alpha")

      output = %{
        kind: :destination,
        destination: Gralkor.Destination.Registry.fetch!("first"),
        ontology: Gralkor.DefaultOntology
      }

      assert :ok =
               Gralkor.Destination.Storage.put_artefact(
                 output,
                 "review",
                 "operator-one",
                 Gralkor.Artefact.new("review-one", %{"content" => "artefact memory"})
               )

      assert {:ok,
              [
                %{
                  destination: "first",
                  episode: %{content: "selected memory", lens: "first-alpha"}
                }
              ]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 lenses: ["first-alpha"]
               })
    end
  end

  describe "when a caller searches memory > where one or more Destinations are supplied > and one or more Lenses are supplied" do
    test "and one or more Lenses are supplied" do
      assert {:ok, _} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 destinations: ["first"],
                 lenses: ["first-alpha"]
               })

      assert_receive {:destination_search, "first", _, _, :episodes, _,
                      [lenses: ["first-alpha"]]}
    end

    test "then only results whose Destination matches any supplied Destination and whose originating Lens matches any supplied Lens can contribute" do
      use_in_memory_storage()
      assert :ok = add_episode("first", "operator-one", "selected", "first-alpha")
      assert :ok = add_episode("first", "operator-one", "wrong Lens", "first-beta")
      assert :ok = add_episode("second", "operator-one", "wrong Destination", "second-beta")

      assert {:ok,
              [
                %{
                  destination: "first",
                  episode: %{content: "selected", lens: "first-alpha"}
                }
              ]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 destinations: ["first"],
                 lenses: ["first-alpha", "second-beta"]
               })
    end

    test "and selecting a Lens does not add that Lens's Destination to the supplied Destinations" do
      assert {:ok, _} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 destinations: ["first"],
                 lenses: ["second-beta"]
               })

      assert_receive {:destination_search, "first", _, _, _, _, _}
      refute_receive {:destination_search, "second", _, _, _, _, _}
    end
  end

  describe "where the same Lens is selected more than once" do
    test "then that Lens contributes no duplicate result" do
      assert {:ok, _} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 destinations: ["first"],
                 lenses: ["first-alpha", "first-alpha"]
               })

      assert_receive {:destination_search, "first", _, _, :episodes, _, [lenses: ["first-alpha"]]}
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

  describe "where a caller explicitly selects facts" do
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

  describe "where a caller explicitly selects nodes" do
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

  describe "when a caller omits the result type or explicitly selects episodes" do
    test "then relevant stored episode content is returned" do
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

    test "and every episode written through a Lens identifies that originating Lens" do
      use_in_memory_storage()
      assert :ok = add_episode("first", "operator-one", "alpha", "first-alpha")
      assert :ok = add_episode("first", "operator-one", "beta", "first-beta")

      assert {:ok,
              [
                %{destination: "first", episode: %{content: "alpha", lens: "first-alpha"}},
                %{destination: "first", episode: %{content: "beta", lens: "first-beta"}}
              ]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 destinations: ["first"]
               })
    end

    test "and every episode written through a Destination artefact output retains its artefact identifier" do
      use_in_memory_storage()

      destination = Gralkor.Destination.Registry.fetch!("first")

      reflection = %Gralkor.Reflection{
        name: "review",
        outputs: [
          %{
            kind: :destination,
            destination: destination,
            ontology: Gralkor.DefaultOntology
          }
        ],
        chain_of_thought: %Gralkor.Reflection.ChainOfThought{path: "functional", steps: []}
      }

      artefact = %Gralkor.Artefact{
        id: "review-one",
        payload: %{"lesson" => "keep it simple"}
      }

      assert :ok =
               Gralkor.Destination.Storage.put_artefact(
                 Enum.find(reflection.outputs, &(&1.kind == :destination)),
                 reflection.name,
                 "operator-one",
                 artefact
               )

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

  describe "where a caller explicitly selects artefacts" do
    test "then relevant artefacts from the selected Destinations are returned" do
      artefact = %Gralkor.Artefact{
        id: "a-1",
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

    test "and every artefact contains exactly its stable identifier and structured payload" do
      artefact = %Gralkor.Artefact{
        id: "a-1",
        payload: %{}
      }

      Application.put_env(:jido_gralkor, :destination_search_responses, %{
        "first" => {:ok, [artefact]}
      })

      assert {:ok, [%{artefact: returned}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "question",
                 destinations: ["first"],
                 result_type: :artefacts
               })

      assert Map.from_struct(returned) == %{id: "a-1", payload: %{}}
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

  describe "if search supplies any Destination or Lens selection that is not a list of registered non-blank names" do
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

    test "and the error identifies whether the rejected selection was for Destinations or Lenses" do
      assert_raise ArgumentError, ~r/missing/, fn ->
        Client.search(%Search{
          operator_id: "operator-one",
          query: "question",
          destinations: ["missing"]
        })
      end
    end
  end

  describe "if search supplies any Destination or Lens selection that is not a list of registered non-blank names" do
    test "and the error identifies the rejected value" do
      assert_raise ArgumentError, ~r/unknown Lens "missing"/, fn ->
        Client.search(%Search{
          operator_id: "operator-one",
          query: "question",
          destinations: ["first"],
          lenses: ["first-alpha", "missing"]
        })
      end

      refute_receive {:destination_search, _, _, _, _, _, _}
    end
  end

  describe "if search combines one or more Lenses with a non-episode result type" do
    test "then search fails before any Destination query is started" do
      assert_raise ArgumentError, ~r/Lens selection requires episode results/, fn ->
        Client.search(%Search{
          operator_id: "operator-one",
          query: "question",
          lenses: ["first-alpha"],
          result_type: :facts
        })
      end

      refute_receive {:destination_search, _, _, _, _, _, _}
    end

    test "and the error identifies that Lens selection requires episode results" do
      assert_raise ArgumentError, ~r/Lens selection requires episode results/, fn ->
        Client.search(%Search{
          operator_id: "operator-one",
          query: "question",
          lenses: ["first-alpha"],
          result_type: :facts
        })
      end
    end
  end

  defp use_in_memory_storage do
    start_supervised!(Gralkor.Lens.Storage.InMemory)
    start_supervised!(Gralkor.Destination.Storage.InMemory)
    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

    Application.put_env(
      :jido_gralkor,
      :destination_storage,
      Gralkor.Destination.Storage.InMemory
    )
  end

  defp add_episode(destination_name, operator_id, content, lens_name \\ "writer") do
    destination = Gralkor.Destination.Registry.fetch!(destination_name)

    store = %Gralkor.Lens.Store{
      operator_id: operator_id,
      lens: %Gralkor.Lens{
        name: lens_name,
        destination: destination,
        ontology: Gralkor.DefaultOntology,
        ingestion: String
      }
    }

    Gralkor.Lens.Store.add(store, content, "functional")
  end
end
