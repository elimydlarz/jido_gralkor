defmodule Gralkor.DestinationSearchFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional
  @moduletag timeout: 120_000

  alias Gralkor.Client
  alias Gralkor.Search

  defmodule SearchStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(destination, operator_id, query, opts) do
      test_pid = Application.fetch_env!(:jido_gralkor, :destination_search_test_pid)
      send(test_pid, {:destination_search, destination.name, operator_id, query, opts})

      if Application.get_env(:jido_gralkor, :destination_search_barrier, false) do
        send(test_pid, {:destination_search_started, destination.name, self()})

        receive do
          :continue_destination_search -> :ok
        end
      end

      responses = Application.get_env(:jido_gralkor, :destination_search_responses, %{})

      Map.get(
        responses,
        destination.name,
        {:ok, %{facts: ["#{destination.name}:#{query}"], nodes: [], episodes: []}}
      )
    end
  end

  setup do
    previous =
      for key <- [
            :client,
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
            destinations: ["first", "second"]
          })
        end)

      assert_receive {:destination_search_started, "first", first}
      assert_receive {:destination_search_started, "second", second}
      send(first, :continue_destination_search)
      send(second, :continue_destination_search)

      assert {:ok, _results} = Task.await(search)
    end

    test "and the search returns one result per selected Destination in the selected Destination order" do
      assert {:ok, [%{destination: "second"}, %{destination: "first"}]} =
               search(destinations: ["second", "first"])
    end

    test "and every Destination result names its Destination" do
      assert {:ok,
              [
                %{destination: "first", facts: ["first:question"]},
                %{destination: "second", facts: ["second:question"]}
              ]} = search(destinations: ["first", "second"])
    end

    test "and every Destination result carries its relevant facts, its relevant nodes, and its relevant episodes together" do
      start_native_graph() |> seed_typed_graph()

      assert {:ok, [%{destination: "first", facts: facts, nodes: nodes, episodes: episodes}]} =
               search(query: "amber", destinations: ["first"])

      assert facts |> Enum.map(& &1.fact) |> Enum.sort() == [
               "amber lesson learns from amber project",
               "amber project owns amber lesson"
             ]

      assert nodes |> Enum.map(& &1.name) |> Enum.sort() == ["amber lesson", "amber project"]
      assert [%{content: "amber seed", writer: :direct}] = episodes
    end

    test "and each Destination contributes at most twenty facts, twenty nodes, and five episodes" do
      start_native_graph() |> seed_lens_graph() |> seed_competing_direct_memory()

      assert {:ok, [%{facts: facts, nodes: nodes, episodes: episodes}]} =
               search(query: "amber", destinations: ["first"])

      assert {length(facts), length(nodes), length(episodes)} == {20, 20, 5}
      assert Search.limits() == %{facts: 20, nodes: 20, episodes: 5}
    end

    test "and facts, nodes, and episodes each keep relevance order within their Destination" do
      Application.put_env(:jido_gralkor, :destination_search_responses, %{
        "first" =>
          {:ok,
           %{facts: ["fact-1", "fact-2"], nodes: ["node-1", "node-2"], episodes: ["ep-1", "ep-2"]}}
      })

      assert {:ok,
              [
                %{
                  facts: ["fact-1", "fact-2"],
                  nodes: ["node-1", "node-2"],
                  episodes: ["ep-1", "ep-2"]
                }
              ]} = search(destinations: ["first"])

      assert_receive {:destination_search, "first", _, _, opts}
      assert Keyword.fetch!(opts, :limits) == %{facts: 20, nodes: 20, episodes: 5}
    end
  end

  describe "when a caller searches memory > where the Destination selector is omitted or empty" do
    test "then every accessible registered Destination is selected" do
      assert {:ok, results} =
               Client.search(%Search{operator_id: "operator-one", query: "question"})

      assert Enum.map(results, & &1.destination) == [
               "personal",
               "global",
               "generalisations",
               "first",
               "second"
             ]

      for destination <- ["personal", "global", "generalisations", "first", "second"] do
        assert_receive {:destination_search, ^destination, "operator-one", "question", _opts}
      end
    end

    test "and results follow the order `personal`, `global`, `generalisations`, then application Destinations" do
      Application.put_env(:jido_gralkor, :destinations, [
        [name: "first"],
        [name: "second"],
        [name: "alpha"]
      ])

      for destinations <- [[], nil] do
        request =
          if destinations,
            do: %Search{
              operator_id: "operator-one",
              query: "question",
              destinations: destinations
            },
            else: %Search{operator_id: "operator-one", query: "question"}

        assert {:ok, results} = Client.search(request)

        assert Enum.map(results, & &1.destination) ==
                 ["personal", "global", "generalisations", "first", "second", "alpha"]
      end
    end

    test "and a Lens selector does not narrow the search to that Lens's Destination" do
      every_destination =
        Enum.map(Gralkor.Destination.Registry.configured!(), & &1.name)

      assert "second" in every_destination
      assert {:ok, results} = search(lenses: ["second-beta"])

      assert Enum.map(results, & &1.destination) == every_destination

      for destination <- every_destination do
        assert_receive {:destination_search, ^destination, "operator-one", "question", opts}
        assert Keyword.fetch!(opts, :lenses) == ["second-beta"]
      end
    end
  end

  describe "when a caller searches memory > where one or more Destinations are supplied" do
    test "then results from any supplied Destination can contribute" do
      assert {:ok,
              [
                %{destination: "first", facts: ["first:question"]},
                %{destination: "second", facts: ["second:question"]}
              ]} = search(destinations: ["first", "second"])
    end

    test "but no result from another Destination can contribute" do
      assert {:ok, [%{destination: "first"}]} = search(destinations: ["first"])
      refute_receive {:destination_search, "second", _, _, _}
    end

    test "and a Lens selector does not add that Lens's Destination to the supplied Destinations" do
      assert {:ok, [%{destination: "second"}]} =
               search(destinations: ["second"], lenses: ["first-alpha"])

      assert_receive {:destination_search, "second", _, _, opts}
      assert Keyword.fetch!(opts, :lenses) == ["first-alpha"]
      refute_receive {:destination_search, "first", _, _, _}
    end
  end

  describe "when a caller searches memory > where the Lens selector is omitted or empty" do
    test "then results written directly or by every Lens or Destination artefact output can contribute" do
      start_native_graph()

      assert :ok =
               Gralkor.Client.Native.memory_add(
                 "personal/operator-one",
                 "amber direct memory",
                 "manual"
               )

      assert :ok =
               Client.ingest(%Gralkor.Ingest{
                 id: "amber-lens",
                 operator_id: "operator-one",
                 lens: "first-alpha",
                 source_kind: :document,
                 content: "amber lens memory",
                 source_description: "notes"
               })

      output = %{
        kind: :destination,
        destination: Gralkor.Destination.Registry.fetch!("second"),
        ontology: Gralkor.DefaultOntology
      }

      artefact = Gralkor.Artefact.new("amber-review", %{"lesson" => "amber artefact memory"})

      assert :ok =
               Gralkor.Destination.Storage.put_artefact(
                 output,
                 "review",
                 "operator-one",
                 artefact
               )

      assert {:ok, results} = Client.search(%Search{operator_id: "operator-one", query: "amber"})
      episodes = Map.new(results, &{&1.destination, &1.episodes})

      assert [%{content: "amber direct memory", writer: :direct}] = episodes["personal"]
      assert [%{content: "amber lens memory", lens: "first-alpha"}] = episodes["first"]

      assert [
               %{
                 artefact: %{id: "amber-review", payload: %{"lesson" => "amber artefact memory"}},
                 reflection: "review"
               }
             ] = episodes["second"]
    end
  end

  describe "when a caller searches memory > where one or more Lenses are supplied" do
    test "then only episodes written through any supplied Lens are returned" do
      start_native_graph() |> seed_lens_graph()

      assert {:ok, [%{episodes: episodes}]} = lens_search(["first-alpha"])
      assert [%{content: "amber alpha memory", lens: "first-alpha"}] = episodes

      assert {:ok, [%{episodes: episodes}]} = lens_search(["first-alpha", "first-beta"])

      assert episodes |> Enum.map(& &1.content) |> Enum.sort() == [
               "amber alpha memory",
               "amber beta memory"
             ]
    end

    test "and only facts drawn from an episode written through any supplied Lens are returned" do
      start_native_graph() |> seed_lens_graph()

      assert {:ok, [%{facts: facts}]} = lens_search(["first-alpha"])

      assert facts |> Enum.map(& &1.fact) |> Enum.sort() == [
               "amber alpha lesson learns from amber alpha project",
               "amber alpha project owns amber alpha lesson",
               "amber shared lesson fact"
             ]
    end

    test "and only entities mentioned by an episode written through any supplied Lens are returned" do
      start_native_graph() |> seed_lens_graph()

      assert {:ok, [%{nodes: nodes}]} = lens_search(["first-alpha"])

      assert nodes |> Enum.map(& &1.name) |> Enum.sort() == [
               "amber alpha lesson",
               "amber alpha project"
             ]
    end

    test "but no result written directly, through another Lens, or through a Destination artefact output can contribute" do
      use_in_memory_storage()
      assert :ok = add_episode("first", "operator-one", "amber alpha", "first-alpha")
      assert :ok = add_episode("first", "operator-one", "amber beta", "first-beta")

      seed_first_episode(%{
        content: "amber direct",
        source_description: "manual",
        writer: :direct
      })

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
                 Gralkor.Artefact.new("amber-review", %{"lesson" => "amber artefact"})
               )

      assert {:ok, [%{facts: facts, nodes: nodes, episodes: episodes}]} =
               lens_search(["first-alpha"])

      assert Enum.map(episodes, & &1.content) == ["amber alpha"]
      assert Enum.map(facts, & &1.fact) == ["amber alpha"]
      assert nodes == []
    end

    test "and results from other writers cannot consume any per-Destination limit" do
      start_native_graph() |> seed_lens_graph() |> seed_competing_direct_memory()

      assert {:ok, [%{facts: facts, nodes: nodes, episodes: episodes}]} =
               lens_search(["first-alpha"])

      assert length(facts) == 3
      assert length(nodes) == 2
      assert [%{content: "amber alpha memory"}] = episodes

      assert {:ok, [%{facts: unfiltered, episodes: unfiltered_episodes}]} =
               search(query: "amber", destinations: ["first"])

      assert length(unfiltered) == 20
      assert length(unfiltered_episodes) == 5
    end

    test "and each returned fact's sources name only supplied Lenses" do
      start_native_graph() |> seed_lens_graph()

      assert {:ok, [%{facts: facts}]} = lens_search(["first-alpha"])
      shared = Enum.find(facts, &(&1.fact == "amber shared lesson fact"))

      assert Enum.map(shared.sources, & &1.lens) == ["first-alpha"]

      assert {:ok, [%{facts: facts}]} = lens_search(["first-alpha", "first-beta"])
      shared = Enum.find(facts, &(&1.fact == "amber shared lesson fact"))

      assert shared.sources |> Enum.map(& &1.lens) |> Enum.sort() == [
               "first-alpha",
               "first-beta"
             ]
    end

    test "and entity and edge type filters further restrict the supplied Lenses' results" do
      start_native_graph() |> seed_lens_graph()

      assert {:ok, [%{facts: facts}]} = lens_search(["first-alpha"], edge_types: ["OWNS"])
      assert Enum.map(facts, & &1.fact) == ["amber alpha project owns amber alpha lesson"]

      assert {:ok, [%{nodes: nodes, facts: facts}]} =
               lens_search(["first-alpha"], entity_types: ["Learning"])

      assert Enum.map(nodes, & &1.name) == ["amber alpha lesson"]
      assert Enum.map(facts, & &1.fact) == ["amber shared lesson fact"]
    end

    test "and a Lens supplied more than once is applied once" do
      assert {:ok, [%{destination: "first"}]} =
               search(
                 destinations: ["first"],
                 lenses: ["first-alpha", "first-beta", "first-alpha"]
               )

      assert_receive {:destination_search, "first", _, _, opts}
      assert Keyword.fetch!(opts, :lenses) == ["first-alpha", "first-beta"]
    end
  end

  describe "when a caller searches memory > where one or more Lenses are supplied > while the search is made through an agent's runtime" do
    test "then Lens names resolve from that runtime's configuration" do
      start_supervised!(
        {JidoGralkor.Runtime,
         owner: self(),
         configuration: %{
           destinations: [%{name: "runtime-memory"}],
           lenses: [
             %{
               name: "runtime-lens",
               destination: "runtime-memory",
               ingestion: Gralkor.Lens.Ingestion.Store
             }
           ],
           reflections: []
         }}
      )

      request = %Search{
        operator_id: "operator-one",
        query: "question",
        destinations: ["runtime-memory"],
        lenses: ["runtime-lens", "runtime-lens"]
      }

      assert {:ok, [%{destination: "runtime-memory"}]} = Client.search(self(), request)
      assert_receive {:destination_search, "runtime-memory", _, _, opts}
      assert Keyword.fetch!(opts, :lenses) == ["runtime-lens"]

      assert_raise ArgumentError, ~r/runtime-lens/, fn ->
        Client.search(%Search{request | destinations: ["first"]})
      end

      assert_raise ArgumentError, ~r/first-alpha/, fn ->
        Client.search(self(), %Search{request | lenses: ["first-alpha"]})
      end
    end
  end

  describe "where the selected Destinations include `personal`" do
    test "then only the current operator's `personal/<operator id>` graph is searched" do
      use_in_memory_storage()
      assert :ok = add_episode("personal", "operator-one", "private memory")

      assert {:ok, [%{destination: "personal", episodes: [%{content: "private memory"}]}]} =
               search(query: "private", destinations: ["personal"])
    end

    test "and another operator's graph cannot contribute a result" do
      use_in_memory_storage()
      assert :ok = add_episode("personal", "operator-one", "private memory")

      assert {:ok, [%{destination: "personal", facts: [], nodes: [], episodes: []}]} =
               search(operator_id: "operator-two", query: "private", destinations: ["personal"])
    end
  end

  describe "where the selected Destinations include any shared Destination" do
    test "then results saved by every operator to that Destination's one graph can contribute" do
      use_in_memory_storage()
      assert :ok = add_episode("first", "operator-one", "shared memory")

      assert {:ok, [%{destination: "first", facts: [%{fact: "shared memory"}]}]} =
               search(operator_id: "operator-two", query: "shared", destinations: ["first"])
    end
  end

  describe "where the same Destination is selected more than once" do
    test "then that Destination is searched only once" do
      assert {:ok, [%{destination: "first"}]} = search(destinations: ["first", "first"])

      assert_receive {:destination_search, "first", _, _, _}
      refute_receive {:destination_search, "first", _, _, _}
    end
  end

  describe "when a Destination result carries episodes" do
    test "then relevant stored episode content is returned" do
      use_in_memory_storage()
      assert :ok = add_episode("first", "operator-one", "stored episode", "first")

      assert {:ok,
              [%{destination: "first", episodes: [%{content: "stored episode", lens: "first"}]}]} =
               search(query: "stored", destinations: ["first"])
    end

    test "and every episode written through a Lens identifies that originating Lens" do
      use_in_memory_storage()
      assert :ok = add_episode("first", "operator-one", "alpha", "first-alpha")
      assert :ok = add_episode("first", "operator-one", "beta", "first-beta")

      assert {:ok,
              [
                %{
                  destination: "first",
                  episodes: [
                    %{content: "alpha", lens: "first-alpha"},
                    %{content: "beta", lens: "first-beta"}
                  ]
                }
              ]} = search(query: "memory", destinations: ["first"])
    end

    test "and every directly written episode retains content and source kind without Lens or Reflection authorship" do
      start_native_graph()

      assert :ok =
               Gralkor.Client.Native.memory_add(
                 "personal/operator-one",
                 "amber direct memory",
                 "captured"
               )

      assert {:ok, [%{destination: "personal", episodes: [episode]}]} =
               search(query: "amber", destinations: ["personal"])

      assert episode == %{
               content: "amber direct memory",
               source_kind: "document",
               source_description: "captured",
               writer: :direct
             }
    end

    test "and historical unmarked episodes remain available without invented authorship" do
      use_in_memory_storage()
      seed_episode(%{content: "old", source_description: "captured"})

      assert {:ok, [%{episodes: [%{content: "old", source_description: "captured"} = episode]}]} =
               search(query: "old", destinations: ["personal"])

      refute Map.has_key?(episode, :lens)
      refute Map.has_key?(episode, :reflection)
    end

    test "and historical operator-labelled episodes retain their recorded Lens provenance" do
      use_in_memory_storage()
      seed_episode(%{content: "old", source_description: "captured", lens: "operator"})

      assert {:ok, [%{episodes: [%{lens: "operator"}]}]} =
               search(query: "old", destinations: ["personal"])
    end

    test "and Lens source descriptions and naturally textual content remain unchanged" do
      use_in_memory_storage()
      content = ~s({"jira":"still source text"})
      assert :ok = add_episode("first", "operator-one", content, "first-alpha")

      assert {:ok,
              [
                %{
                  episodes: [
                    %{content: ^content, source_description: "functional", lens: "first-alpha"}
                  ]
                }
              ]} = search(query: "jira", destinations: ["first"])
    end

    test "and every episode written through a Destination artefact output exposes its stable artefact identifier and payload as structured fields" do
      use_in_memory_storage()

      output = %{
        kind: :destination,
        destination: Gralkor.Destination.Registry.fetch!("first"),
        ontology: Gralkor.DefaultOntology
      }

      artefact = %Gralkor.Artefact{id: "review-one", payload: %{"lesson" => "keep it simple"}}

      assert :ok =
               Gralkor.Destination.Storage.put_artefact(
                 output,
                 "review",
                 "operator-one",
                 artefact
               )

      returned_artefact = Map.from_struct(artefact)

      assert {:ok,
              [
                %{
                  destination: "first",
                  episodes: [%{artefact: ^returned_artefact, reflection: "review"}]
                }
              ]} = search(query: "simple", destinations: ["first"])
    end

    test "and a search for one word of an artefact's payload returns that artefact from a Graphiti Destination" do
      start_native_graph()

      output = %{
        kind: :destination,
        destination: Gralkor.Destination.Registry.fetch!("first"),
        ontology: Gralkor.DefaultOntology
      }

      artefact =
        Gralkor.Artefact.new(
          Gralkor.Artefact.id_for("operator-one", "invocation-one", "review"),
          %{"lesson" => "prefer reversible saffron rollouts"}
        )

      assert :ok =
               Gralkor.Destination.Storage.put_artefact(
                 output,
                 "review",
                 "operator-one",
                 artefact
               )

      returned_artefact = Map.from_struct(artefact)

      assert {:ok, [%{destination: "first", episodes: episodes}]} =
               search(query: "saffron", destinations: ["first"])

      assert [%{artefact: ^returned_artefact, reflection: "review"}] = episodes
    end
  end

  describe "when a Destination result carries facts" do
    test "then relevant relationships extracted in that Destination are returned as structured fact records" do
      use_in_memory_storage()
      assert :ok = add_episode("first", "operator-one", "first:question")

      assert {:ok, [%{destination: "first", facts: [%{fact: "first:question"}]}]} =
               search(destinations: ["first"])
    end

    test "and each fact retains originating episode identifiers, source kinds, and source descriptions" do
      use_native_fact_storage()
      assert {:ok, [%{facts: [%{sources: sources} | _]}]} = fact_search()

      assert Enum.map(sources, &Map.take(&1, [:id, :source_kind, :source_description])) == [
               %{
                 id: "beta",
                 source_kind: "document",
                 source_description: "notes [lens: first-beta]"
               }
             ]
    end

    test "and named Lens or Reflection provenance is exposed on each attributable fact source" do
      use_native_fact_storage()
      assert {:ok, [%{facts: facts}]} = fact_search()
      assert Enum.at(facts, 0).sources |> hd() |> Map.fetch!(:lens) == "first-beta"
      assert Enum.at(facts, 2).sources |> hd() |> Map.fetch!(:reflection) == "lessons"
    end

    test "and every fact names its relationship" do
      start_native_graph() |> seed_typed_graph()

      assert typed_facts() |> Enum.map(&{&1.fact, &1.relationship}) == [
               {"amber lesson learns from amber project", "LEARNS_FROM"},
               {"amber project owns amber lesson", "OWNS"}
             ]
    end

    test "and every fact identifies its source entity by name and identifier" do
      start_native_graph() |> seed_typed_graph()

      assert typed_facts() |> Enum.map(& &1.source_node) == [
               %{uuid: "lesson", name: "amber lesson"},
               %{uuid: "project", name: "amber project"}
             ]
    end

    test "and every fact identifies its target entity by name and identifier" do
      start_native_graph() |> seed_typed_graph()

      assert typed_facts() |> Enum.map(& &1.target_node) == [
               %{uuid: "project", name: "amber project"},
               %{uuid: "lesson", name: "amber lesson"}
             ]
    end

  end

  describe "when a Destination result carries nodes" do
    test "then relevant entities extracted in that Destination are returned" do
      start_native_graph() |> seed_typed_graph()

      assert {:ok, [%{nodes: nodes}]} = search(query: "amber", destinations: ["first"])

      assert Enum.all?(nodes, &match?(%{name: _, summary: _, attributes: _}, &1))
      assert nodes |> Enum.map(& &1.name) |> Enum.sort() == ["amber lesson", "amber project"]
    end
  end

  describe "where a caller filters by entity type" do
    test "then only nodes carrying a selected ontology label are returned" do
      start_native_graph() |> seed_typed_graph()

      assert {:ok, [%{nodes: [%{name: "amber lesson"}]}]} =
               search(query: "amber", destinations: ["first"], entity_types: ["Learning"])
    end

    test "and only facts whose source and target entities both carry a selected ontology label are returned" do
      start_native_graph() |> seed_typed_graph()

      assert {:ok, [%{facts: []}]} =
               search(query: "amber", destinations: ["first"], entity_types: ["Learning"])

      assert {:ok, [%{facts: facts}]} =
               search(
                 query: "amber",
                 destinations: ["first"],
                 entity_types: ["Learning", "Project"]
               )

      assert facts |> Enum.map(& &1.fact) |> Enum.sort() == [
               "amber lesson learns from amber project",
               "amber project owns amber lesson"
             ]
    end

    test "but episodes are not restricted by entity type" do
      start_native_graph() |> seed_typed_graph()

      assert {:ok, [%{episodes: [%{content: "amber seed"}]}]} =
               search(query: "amber", destinations: ["first"], entity_types: ["Learning"])
    end
  end

  describe "where a caller filters by edge type" do
    test "then only facts carrying a selected ontology relationship type are returned" do
      start_native_graph() |> seed_typed_graph()

      assert {:ok, [%{facts: [%{fact: "amber lesson learns from amber project"}]}]} =
               search(query: "amber", destinations: ["first"], edge_types: ["LEARNS_FROM"])
    end

    test "but nodes and episodes are not restricted by relationship type" do
      start_native_graph() |> seed_typed_graph()

      assert {:ok, [%{nodes: nodes, episodes: [%{content: "amber seed"}]}]} =
               search(query: "amber", destinations: ["first"], edge_types: ["LEARNS_FROM"])

      assert nodes |> Enum.map(& &1.name) |> Enum.sort() == ["amber lesson", "amber project"]
    end
  end

  describe "if a selected Destination search fails" do
    test "then the error is returned without manufacturing a partial memory response" do
      Application.put_env(:jido_gralkor, :destination_search_responses, %{
        "second" => {:error, :unavailable}
      })

      assert {:error, :unavailable} = search(destinations: ["first", "second"])
    end
  end

  describe "if search supplies a field removed in 12.0.0" do
    test "then search fails before any Destination query is started" do
      for {field, value, _guidance} <- removed_fields() do
        assert_raise ArgumentError, fn -> search([{:destinations, ["first"]}, {field, value}]) end
        refute_receive {:destination_search, _, _, _, _}
      end
    end

    test "and the error names the removed field" do
      for {field, value, _guidance} <- removed_fields() do
        error = assert_raise ArgumentError, fn -> search([{field, value}]) end
        assert error.message =~ "#{inspect(field)} was removed in 12.0.0"
      end
    end

    test "and the error gives migration guidance for that field" do
      for {field, value, guidance} <- removed_fields() do
        error = assert_raise ArgumentError, fn -> search([{field, value}]) end
        assert error.message =~ guidance
      end
    end
  end

  describe "if search supplies any Destination or Lens selection that is not a list of registered non-blank names" do
    test "then search fails before any Destination query is started" do
      for {selector, selection, message} <- invalid_selections() do
        assert_raise ArgumentError, ~r/#{Regex.escape(message)}/, fn ->
          search([{selector, selection}])
        end

        refute_receive {:destination_search, _, _, _, _}
      end
    end

    test "and no valid subset is searched" do
      for {selector, selection, _message} <- invalid_selections() do
        assert_raise ArgumentError, fn ->
          search([{:destinations, ["first"]}, {selector, selection}])
        end

        refute_receive {:destination_search, "first", _, _, _}
      end
    end

    test "and the error identifies whether the rejected selection was for Destinations or Lenses" do
      for {selector, selection, _message} <- invalid_selections() do
        error = assert_raise ArgumentError, fn -> search([{selector, selection}]) end

        case selector do
          :destinations ->
            assert error.message =~ ~r/destination/i
            refute error.message =~ ~r/lens/i

          :lenses ->
            assert error.message =~ ~r/lens/i
            refute error.message =~ ~r/destination/i
        end
      end
    end

    test "and the error identifies the rejected value" do
      for {selector, selection, _message} <- invalid_selections() do
        error = assert_raise ArgumentError, fn -> search([{selector, selection}]) end
        rejected = if is_list(selection), do: List.last(selection), else: selection
        assert error.message =~ inspect(rejected)
      end
    end
  end

  defp search(overrides \\ []) do
    Client.search(
      struct!(
        Search,
        Keyword.merge([operator_id: "operator-one", query: "question"], overrides)
      )
    )
  end

  defp removed_fields do
    [
      {:result_type, :facts, "every search now returns facts, nodes, and episodes"},
      {:artefact_id, "a-1", "episodes carrying artefact"},
      {:max_results, 5, "limits are fixed per Destination"}
    ]
  end

  defp invalid_selections do
    [
      {:destinations, ["first", "missing"], ~s(unknown Destination "missing")},
      {:destinations, "first", ~s(search destinations must be a list, got "first")},
      {:destinations, ["first", " "], ~s(invalid Destination name " ")},
      {:lenses, ["first-alpha", "missing"], ~s(unknown Lens "missing")},
      {:lenses, "first-alpha", ~s(search lenses must be a list, got "first-alpha")},
      {:lenses, ["first-alpha", " "], ~s(invalid Lens name " ")}
    ]
  end

  defp lens_search(lenses, overrides \\ []) do
    search([query: "amber", destinations: ["first"], lenses: lenses] ++ overrides)
  end

  defp seed_first_episode(episode),
    do: GenServer.call(Gralkor.Lens.Storage.InMemory, {:add, "first", episode})

  # One Destination holding memory from every writer: two appending Lenses
  # (each episode mentioning its own entities), a direct write, and a Reflection
  # artefact. `shared` is drawn from both Lenses' episodes.
  defp seed_lens_graph(%{database: database} = graph) do
    for {id, lens, content} <- [
          {"amber-alpha", "first-alpha", "amber alpha memory"},
          {"amber-beta", "first-beta", "amber beta memory"}
        ] do
      assert :ok =
               Client.ingest(%Gralkor.Ingest{
                 id: id,
                 operator_id: "operator-one",
                 lens: lens,
                 source_kind: :document,
                 content: content,
                 source_description: "notes"
               })
    end

    assert :ok = Gralkor.Client.Native.memory_add("first", "amber direct memory", "manual")

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
               Gralkor.Artefact.new("amber-review", %{"lesson" => "amber artefact memory"})
             )

    Pythonx.eval(
      """
      graph = database.select_graph('g_' + b'first'.hex())
      graph.query('''
        MATCH (alpha:Episodic) WHERE alpha.source_description ENDS WITH ' [lens: first-alpha]'
        MATCH (beta:Episodic) WHERE beta.source_description ENDS WITH ' [lens: first-beta]'
        MATCH (direct:Episodic) WHERE direct.content = 'amber direct memory'
        CREATE (al:Entity:Learning {uuid: 'alpha-lesson', name: 'amber alpha lesson', group_id: alpha.group_id, summary: 'amber alpha lesson', created_at: alpha.created_at}),
               (ap:Entity:Project {uuid: 'alpha-project', name: 'amber alpha project', group_id: alpha.group_id, summary: 'amber alpha project', created_at: alpha.created_at}),
               (bl:Entity:Learning {uuid: 'beta-lesson', name: 'amber beta lesson', group_id: alpha.group_id, summary: 'amber beta lesson', created_at: alpha.created_at}),
               (dp:Entity:Project {uuid: 'direct-project', name: 'amber direct project', group_id: alpha.group_id, summary: 'amber direct project', created_at: alpha.created_at}),
               (alpha)-[:MENTIONS {uuid: 'mentions-al', group_id: alpha.group_id, created_at: alpha.created_at}]->(al),
               (alpha)-[:MENTIONS {uuid: 'mentions-ap', group_id: alpha.group_id, created_at: alpha.created_at}]->(ap),
               (beta)-[:MENTIONS {uuid: 'mentions-bl', group_id: alpha.group_id, created_at: alpha.created_at}]->(bl),
               (direct)-[:MENTIONS {uuid: 'mentions-dp', group_id: alpha.group_id, created_at: alpha.created_at}]->(dp),
               (al)-[learns:RELATES_TO {uuid: 'alpha-learns', name: 'LEARNS_FROM', fact: 'amber alpha lesson learns from amber alpha project', episodes: [alpha.uuid], group_id: alpha.group_id, created_at: alpha.created_at, valid_at: alpha.valid_at}]->(ap),
               (ap)-[owns:RELATES_TO {uuid: 'alpha-owns', name: 'OWNS', fact: 'amber alpha project owns amber alpha lesson', episodes: [alpha.uuid], group_id: alpha.group_id, created_at: alpha.created_at, valid_at: alpha.valid_at}]->(al),
               (bl)-[beta_owns:RELATES_TO {uuid: 'beta-owns', name: 'OWNS', fact: 'amber beta lesson owns amber alpha lesson', episodes: [beta.uuid], group_id: alpha.group_id, created_at: alpha.created_at, valid_at: alpha.valid_at}]->(al),
               (al)-[shared:RELATES_TO {uuid: 'shared', name: 'SHARES', fact: 'amber shared lesson fact', episodes: [beta.uuid, alpha.uuid], group_id: alpha.group_id, created_at: alpha.created_at, valid_at: alpha.valid_at}]->(bl),
               (dp)-[direct_owns:RELATES_TO {uuid: 'direct-owns', name: 'OWNS', fact: 'amber direct project owns amber direct project', episodes: [direct.uuid], group_id: alpha.group_id, created_at: alpha.created_at, valid_at: alpha.valid_at}]->(dp)
        SET al.name_embedding = vecf32([0.1, 0.2, 0.3]),
            ap.name_embedding = vecf32([0.1, 0.2, 0.3]),
            bl.name_embedding = vecf32([0.1, 0.2, 0.3]),
            dp.name_embedding = vecf32([0.1, 0.2, 0.3]),
            learns.fact_embedding = vecf32([0.1, 0.2, 0.3]),
            owns.fact_embedding = vecf32([0.1, 0.2, 0.3]),
            beta_owns.fact_embedding = vecf32([0.1, 0.2, 0.3]),
            shared.fact_embedding = vecf32([0.1, 0.2, 0.3]),
            direct_owns.fact_embedding = vecf32([0.1, 0.2, 0.3])
      ''')
      """,
      %{"database" => database}
    )

    graph
  end

  # Thirty direct facts and entities and ten direct episodes, each matching
  # the query more strongly than any Lens result.
  defp seed_competing_direct_memory(%{database: database} = graph) do
    Pythonx.eval(
      """
      graph = database.select_graph('g_' + b'first'.hex())
      graph.query('''
        MATCH (direct:Episodic) WHERE direct.content = 'amber direct memory'
        UNWIND range(1, 30) AS i
        CREATE (n:Entity:Project {uuid: 'competing-' + toString(i), name: 'amber amber amber ' + toString(i), group_id: direct.group_id, summary: 'amber amber amber', created_at: direct.created_at}),
               (direct)-[:MENTIONS {uuid: 'competing-mention-' + toString(i), group_id: direct.group_id, created_at: direct.created_at}]->(n),
               (n)-[e:RELATES_TO {uuid: 'competing-fact-' + toString(i), name: 'OWNS', fact: 'amber amber amber ' + toString(i), episodes: [direct.uuid], group_id: direct.group_id, created_at: direct.created_at, valid_at: direct.valid_at}]->(n)
        SET n.name_embedding = vecf32([0.1, 0.2, 0.3]),
            e.fact_embedding = vecf32([0.1, 0.2, 0.3])
      ''')
      graph.query('''
        MATCH (direct:Episodic) WHERE direct.content = 'amber direct memory'
        UNWIND range(1, 10) AS i
        CREATE (e:Episodic)
        SET e = properties(direct),
            e.uuid = 'competing-episode-' + toString(i),
            e.content = 'amber amber amber ' + toString(i)
      ''')
      """,
      %{"database" => database}
    )

    graph
  end

  defp typed_facts do
    assert {:ok, [%{facts: facts}]} = search(query: "amber", destinations: ["first"])
    Enum.sort_by(facts, & &1.fact)
  end

  defp fact_search, do: search(query: "fact", destinations: ["first"])

  defp start_native_graph do
    directory =
      Path.join(System.tmp_dir!(), "destination-search-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)

    {server, globals} =
      Pythonx.eval(
        """
        from redislite import Redis
        from falkordb import FalkorDB
        server = Redis(dbfilename=path.decode(), serverconfig={'port': '0'})
        server.config_set('loglevel', 'warning')
        server.config_set('save', '')
        database = FalkorDB(unix_socket_path=server.socket_file)
        server
        """,
        %{"path" => Path.join(directory, "fixture.rdb")}
      )

    {socket, _} = Pythonx.eval("server.socket_file", %{"server" => server})
    socket = Pythonx.decode(socket)

    on_exit(fn ->
      Pythonx.eval("server.shutdown(save=False, now=True, force=True)", %{"server" => server})
      File.rm_rf!(directory)
    end)

    {telemetry, _} = Pythonx.eval("import os\nos.environ.get('GRAPHITI_TELEMETRY_ENABLED')", %{})

    on_exit(fn ->
      Pythonx.eval(
        "import os\nos.environ.pop('GRAPHITI_TELEMETRY_ENABLED', None) if previous is None else os.environ.__setitem__('GRAPHITI_TELEMETRY_ENABLED', previous)",
        %{"previous" => telemetry}
      )
    end)

    Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)
    Application.put_env(:jido_gralkor, :destination_storage, Gralkor.Destination.Storage.Graphiti)
    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.Graphiti)

    shared_clients = fn _spec ->
      {_, clients} =
        Pythonx.eval(
          """
          import os
          os.environ['GRAPHITI_TELEMETRY_ENABLED'] = 'false'
          from graphiti_core.llm_client import OpenAIClient, LLMConfig
          from graphiti_core.embedder.openai import OpenAIEmbedder, OpenAIEmbedderConfig
          from graphiti_core.cross_encoder.openai_reranker_client import OpenAIRerankerClient
          config = LLMConfig(api_key='isolated-fixture', base_url='http://127.0.0.1:1')
          llm = OpenAIClient(config=config)
          embedder = OpenAIEmbedder(config=OpenAIEmbedderConfig(api_key='isolated-fixture', base_url='http://127.0.0.1:1', embedding_dim=3))
          cross_encoder = OpenAIRerankerClient(config=config)
          async def generate_response(*args, **kwargs):
              model = kwargs.get('response_model')
              name = model.__name__ if model is not None else ''
              if name == 'ExtractedEntities': return {'extracted_entities': []}
              if name == 'ExtractedEdges': return {'edges': []}
              raise AssertionError('unexpected external inference: ' + name)
          async def create(*args, **kwargs): return [0.1, 0.2, 0.3]
          async def create_batch(values): return [[0.1, 0.2, 0.3] for _ in values]
          async def rank(query, passages): return [(passage, 1.0) for passage in passages]
          llm.generate_response = generate_response
          embedder.create = create
          embedder.create_batch = create_batch
          cross_encoder.rank = rank
          """,
          %{}
        )

      %{
        llm_client: clients["llm"],
        embedder: clients["embedder"],
        cross_encoder: clients["cross_encoder"]
      }
    end

    start_supervised!(
      {Gralkor.GraphitiPool,
       falkordb_spec: {:remote, []},
       warmup: false,
       construct_shared_clients: shared_clients,
       construct_falkor_db: fn _ ->
         {database, _} =
           Pythonx.eval(
             "from falkordb.asyncio import FalkorDB\nFalkorDB(unix_socket_path=socket.decode())",
             %{"socket" => socket}
           )

         database
       end}
    )

    %{database: globals["database"]}
  end

  defp seed_typed_graph(%{database: database}) do
    assert :ok = Gralkor.Client.Native.memory_add("first", "amber seed", "manual")

    Pythonx.eval(
      """
      graph = database.select_graph('g_' + b'first'.hex())
      graph.query('''
        MATCH (e:Episodic) WITH e LIMIT 1
        CREATE (lesson:Entity:Learning {uuid: 'lesson', name: 'amber lesson', group_id: e.group_id, summary: 'amber lesson', created_at: e.created_at}),
               (project:Entity:Project {uuid: 'project', name: 'amber project', group_id: e.group_id, summary: 'amber project', created_at: e.created_at}),
               (lesson)-[learned:RELATES_TO {uuid: 'learned', name: 'LEARNS_FROM', fact: 'amber lesson learns from amber project', episodes: [e.uuid], group_id: e.group_id, created_at: e.created_at, valid_at: e.valid_at}]->(project),
               (project)-[owned:RELATES_TO {uuid: 'owned', name: 'OWNS', fact: 'amber project owns amber lesson', episodes: [e.uuid], group_id: e.group_id, created_at: e.created_at, valid_at: e.valid_at}]->(lesson)
        SET lesson.name_embedding = vecf32([0.1, 0.2, 0.3]),
            project.name_embedding = vecf32([0.1, 0.2, 0.3]),
            learned.fact_embedding = vecf32([0.1, 0.2, 0.3]),
            owned.fact_embedding = vecf32([0.1, 0.2, 0.3])
      ''')
      """,
      %{"database" => database}
    )

    :ok
  end

  defp use_native_fact_storage do
    Application.put_env(:jido_gralkor, :destination_storage, Gralkor.Destination.Storage.Graphiti)

    {graphiti, _} =
      Pythonx.eval(
        """
        from types import SimpleNamespace
        from graphiti_core.nodes import EpisodeType
        class FactFixture:
            def __init__(self):
                self.episodes = {
                    'beta': SimpleNamespace(uuid='beta', source=EpisodeType.text, source_description='notes [lens: first-beta]'),
                    'alpha': SimpleNamespace(uuid='alpha', source=EpisodeType.text, source_description='notes [lens: first-alpha]'),
                    'reflection': SimpleNamespace(uuid='reflection', source=EpisodeType.json, source_description='reflection:lessons'),
                }
                self.edges = [
                    self.edge('other', 'unselected fact', ['beta']),
                    self.edge('selected', 'selected fact', ['beta', 'alpha']),
                    self.edge('reflected', 'reflected fact', ['reflection']),
                ]
                self.driver = self
                self.graph_operations_interface = self
            def edge(self, uuid, fact, episodes):
                return SimpleNamespace(uuid=uuid, fact=fact, episodes=episodes, created_at=None, valid_at=None, invalid_at=None, expired_at=None)
            async def search_(self, query, config=None, group_ids=None, search_filter=None):
                assert group_ids is None
                return SimpleNamespace(edges=self.edges[:config.limit], nodes=[], episodes=[])
            async def episodic_node_get_by_uuids(self, cls, driver, uuids):
                return [self.episodes[uuid] for uuid in uuids]
        FactFixture()
        """,
        %{}
      )

    start_supervised!(
      {Gralkor.GraphitiPool,
       name: Gralkor.GraphitiPool,
       table: :gralkor_graphiti_instances,
       falkordb_spec: {:embedded, "/tmp/never_used"},
       construct_falkor_db: fn _ -> :fixture end,
       construct_shared_clients: fn _spec ->
         %{llm_client: nil, embedder: nil, cross_encoder: nil}
       end,
       construct_instance: fn _, _, _ -> graphiti end,
       initialise_instance: fn _ -> :ok end,
       warmup: false,
       install_loop_fn: &Gralkor.Python.install_async_runtime/0}
    )
  end

  defp seed_episode(episode),
    do: GenServer.call(Gralkor.Lens.Storage.InMemory, {:add, "personal/operator-one", episode})

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
