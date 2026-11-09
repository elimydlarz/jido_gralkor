defmodule Gralkor.DestinationSearchFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional
  @moduletag timeout: 300_000

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

      responses
      |> Map.get(
        destination.name,
        {:ok, %{facts: ["#{destination.name}:#{query}"], nodes: [], episodes: []}}
      )
      |> case do
        {:exit, reason} -> exit(reason)
        response -> response
      end
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
      assert Keyword.fetch!(opts, :limits) == Search.limits()
    end

    test "and each Destination contributes at most fifty facts, twenty nodes, and fifteen episodes" do
      start_native_graph()
      |> seed_lens_graph()
      |> seed_competing_direct_memory()
      |> record_seeded_writers()

      assert {:ok, [%{facts: facts, nodes: nodes, episodes: episodes}]} =
               search(query: "amber", destinations: ["first"])

      assert {length(facts), length(nodes), length(episodes)} == {50, 20, 15}
      assert Search.limits() == %{facts: 50, nodes: 20, episodes: 15}
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

    test "and including or excluding a Lens writer does not narrow the search to that Lens's Destination" do
      every_destination =
        Enum.map(Gralkor.Destination.Registry.configured!(), & &1.name)

      assert "second" in every_destination

      for field <- [:writers, :excluded_writers] do
        assert {:ok, results} = search([{field, ["lens:second-beta"]}])

        assert Enum.map(results, & &1.destination) == every_destination

        for destination <- every_destination do
          assert_receive {:destination_search, ^destination, "operator-one", "question", opts}
          assert Keyword.fetch!(opts, field) == ["lens:second-beta"]
        end
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

    test "and including a Lens writer does not add that Lens's Destination to the supplied Destinations" do
      assert {:ok, [%{destination: "second"}]} =
               search(destinations: ["second"], writers: ["lens:first-alpha"])

      assert_receive {:destination_search, "second", _, _, opts}
      assert Keyword.fetch!(opts, :writers) == ["lens:first-alpha"]
      refute_receive {:destination_search, "first", _, _, _}
    end
  end

  describe "when a caller searches memory > where no writer is included or excluded" do
    test "then results from every writer can contribute" do
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

      assert :ok = put_artefact("second", "review", "amber-review", "amber artefact memory")
      assert :ok = Gralkor.GraphitiPool.add_episode("first", "amber unattributed", "old", nil)

      assert {:ok, results} = Client.search(%Search{operator_id: "operator-one", query: "amber"})
      episodes = Map.new(results, &{&1.destination, &1.episodes})

      assert [%{content: "amber direct memory", writer: :direct}] = episodes["personal"]

      assert episode_contents(episodes["first"]) == ["amber lens memory", "amber unattributed"]

      assert [
               %{
                 artefact: %{id: "amber-review", payload: %{"lesson" => "amber artefact memory"}},
                 reflection: "review"
               }
             ] = episodes["second"]
    end
  end

  describe "when a caller searches memory > where one or more writers are included" do
    test "then only episodes written by an included writer are returned" do
      start_native_graph() |> seed_lens_graph() |> record_seeded_writers()

      assert {:ok, [%{episodes: episodes}]} = writer_search(["lens:first-alpha"])
      assert [%{content: "amber alpha memory", lens: "first-alpha"}] = episodes

      assert {:ok, [%{episodes: episodes}]} = writer_search(["lens:first-alpha", "lens:first-beta"])

      assert episode_contents(episodes) == ["amber alpha memory", "amber beta memory"]

      assert {:ok, [%{episodes: [%{content: "amber direct memory", writer: :direct}]}]} =
               writer_search(["direct"])

      assert {:ok, [%{episodes: [%{artefact: %{id: "amber-review"}}]}]} =
               writer_search(["reflection:review"])
    end

    test "and only facts drawn from an episode written by an included writer are returned" do
      start_native_graph() |> seed_lens_graph() |> record_seeded_writers()

      assert {:ok, [%{facts: facts}]} = writer_search(["lens:first-alpha"])

      assert fact_texts(facts) == [
               "amber alpha lesson learns from amber alpha project",
               "amber alpha project owns amber alpha lesson",
               "amber shared lesson fact"
             ]
    end

    test "and only entities mentioned by an episode written by an included writer are returned" do
      start_native_graph() |> seed_lens_graph() |> record_seeded_writers()

      assert {:ok, [%{nodes: nodes}]} = writer_search(["lens:first-alpha"])

      assert node_names(nodes) == ["amber alpha lesson", "amber alpha project"]
    end

    test "and results from other writers cannot consume any per-Destination limit" do
      start_native_graph()
      |> seed_lens_graph()
      |> seed_competing_direct_memory()
      |> record_seeded_writers()

      assert {:ok, [%{facts: facts, nodes: nodes, episodes: episodes}]} =
               writer_search(["lens:first-alpha"])

      assert length(facts) == 3
      assert length(nodes) == 2
      assert [%{content: "amber alpha memory"}] = episodes

      assert {:ok, [%{facts: unfiltered, episodes: unfiltered_episodes}]} =
               search(query: "amber", destinations: ["first"])

      assert length(unfiltered) == 50
      assert length(unfiltered_episodes) == 15
    end

    test "and each returned fact's sources name only included writers" do
      start_native_graph() |> seed_lens_graph() |> record_seeded_writers()

      assert {:ok, [%{facts: facts}]} = writer_search(["lens:first-alpha"])
      shared = Enum.find(facts, &(&1.fact == "amber shared lesson fact"))

      assert Enum.map(shared.sources, & &1.lens) == ["first-alpha"]

      assert {:ok, [%{facts: facts}]} = writer_search(["lens:first-alpha", "lens:first-beta"])
      shared = Enum.find(facts, &(&1.fact == "amber shared lesson fact"))

      assert shared.sources |> Enum.map(& &1.lens) |> Enum.sort() == [
               "first-alpha",
               "first-beta"
             ]
    end

    test "and entity and edge type filters further restrict the included writers' results" do
      start_native_graph() |> seed_lens_graph() |> record_seeded_writers()

      assert {:ok, [%{facts: facts}]} = writer_search(["lens:first-alpha"], edge_types: ["OWNS"])
      assert Enum.map(facts, & &1.fact) == ["amber alpha project owns amber alpha lesson"]

      assert {:ok, [%{nodes: nodes, facts: facts}]} =
               writer_search(["lens:first-alpha"], entity_types: ["Learning"])

      assert Enum.map(nodes, & &1.name) == ["amber alpha lesson"]
      assert Enum.map(facts, & &1.fact) == ["amber shared lesson fact"]
    end

    test "and a writer included more than once is applied once" do
      assert {:ok, [%{destination: "first"}]} =
               search(
                 destinations: ["first"],
                 writers: ["lens:first-alpha", "direct", "lens:first-alpha", "direct"]
               )

      assert_receive {:destination_search, "first", _, _, opts}
      assert Keyword.fetch!(opts, :writers) == ["lens:first-alpha", "direct"]
    end
  end

  describe "when a caller searches memory > where one or more writers are included > while the search is made through an agent's runtime" do
    test "then the Lenses that included writers name resolve from that runtime's configuration" do
      start_runtime_with_lens()

      request = %Search{
        operator_id: "operator-one",
        query: "question",
        destinations: ["runtime-memory"],
        writers: ["lens:runtime-lens", "lens:runtime-lens", "direct"]
      }

      assert {:ok, [%{destination: "runtime-memory"}]} = Client.search(self(), request)
      assert_receive {:destination_search, "runtime-memory", _, _, opts}
      assert Keyword.fetch!(opts, :writers) == ["lens:runtime-lens", "direct"]

      assert_raise ArgumentError, ~r/runtime-lens/, fn ->
        Client.search(%Search{request | destinations: ["first"]})
      end

      assert_raise ArgumentError, ~r/first-alpha/, fn ->
        Client.search(self(), %Search{request | writers: ["lens:first-alpha"]})
      end
    end
  end

  describe "when a caller searches memory > where one or more writers are excluded" do
    test "then no episode written by an excluded writer is returned" do
      start_native_graph() |> seed_lens_graph() |> record_seeded_writers()

      assert {:ok, [%{episodes: episodes}]} = exclusion_search(["lens:first-beta"])

      contents = Enum.map(episodes, &Map.get(&1, :content))
      assert "amber alpha memory" in contents
      assert "amber direct memory" in contents
      refute "amber beta memory" in contents
      refute Enum.any?(episodes, &(Map.get(&1, :lens) == "first-beta"))

      assert {:ok, [%{episodes: episodes}]} = exclusion_search(["direct", "reflection:review"])

      assert episode_contents(episodes) == ["amber alpha memory", "amber beta memory"]
      assert artefact_episodes(episodes) == []
    end

    test "and no fact drawn only from episodes written by excluded writers is returned" do
      start_native_graph() |> seed_lens_graph() |> record_seeded_writers()

      assert {:ok, [%{facts: facts}]} = exclusion_search(["lens:first-beta"])

      refute "amber beta lesson owns amber alpha lesson" in Enum.map(facts, & &1.fact)
    end

    test "and no entity mentioned only by episodes written by excluded writers is returned" do
      start_native_graph() |> seed_lens_graph() |> record_seeded_writers()

      assert {:ok, [%{nodes: nodes}]} = exclusion_search(["lens:first-beta"])

      assert node_names(nodes) == [
               "amber alpha lesson",
               "amber alpha project",
               "amber direct project"
             ]
    end

    test "but a fact also drawn from an episode by a writer that is not excluded is returned" do
      start_native_graph() |> seed_lens_graph() |> record_seeded_writers()

      assert {:ok, [%{facts: facts}]} = exclusion_search(["lens:first-beta"])

      assert fact_texts(facts) == [
               "amber alpha lesson learns from amber alpha project",
               "amber alpha project owns amber alpha lesson",
               "amber direct project owns amber direct project",
               "amber shared lesson fact"
             ]
    end

    test "and an entity also mentioned by an episode by a writer that is not excluded is returned" do
      start_native_graph()
      |> seed_lens_graph()
      |> seed_excluded_mention_of_alpha_lesson()
      |> record_seeded_writers()

      assert {:ok, [%{nodes: nodes}]} = exclusion_search(["lens:first-beta"])

      names = Enum.map(nodes, & &1.name)
      assert "amber alpha lesson" in names
      refute "amber beta lesson" in names
    end

    test "and excluded results cannot consume any per-Destination limit" do
      start_native_graph()
      |> seed_lens_graph()
      |> seed_competing_excluded_memory()
      |> record_seeded_writers()

      assert {:ok, [%{facts: unfiltered, nodes: unfiltered_nodes, episodes: unfiltered_episodes}]} =
               search(query: "amber", destinations: ["first"])

      assert length(unfiltered) == 50
      assert length(unfiltered_nodes) == 20
      assert length(unfiltered_episodes) == 15

      assert {:ok, [%{facts: facts, nodes: nodes, episodes: episodes}]} =
               exclusion_search(["lens:first-beta"])

      assert length(facts) == 4
      assert length(nodes) == 3
      contents = Enum.map(episodes, &Map.get(&1, :content))
      assert "amber alpha memory" in contents
      assert "amber direct memory" in contents
      refute Enum.any?(episodes, &(Map.get(&1, :lens) == "first-beta"))
    end

    test "and each returned fact's sources name no excluded writer" do
      start_native_graph() |> seed_lens_graph() |> record_seeded_writers()

      assert {:ok, [%{facts: facts}]} = exclusion_search(["lens:first-beta"])
      shared = Enum.find(facts, &(&1.fact == "amber shared lesson fact"))

      assert Enum.map(shared.sources, & &1.lens) == ["first-alpha"]

      refute Enum.any?(facts, fn fact -> Enum.any?(fact.sources, &(&1[:lens] == "first-beta")) end)
    end

    test "and entity and edge type filters further restrict the remaining results" do
      start_native_graph() |> seed_lens_graph() |> record_seeded_writers()

      assert {:ok, [%{facts: facts}]} = exclusion_search(["lens:first-beta"], edge_types: ["OWNS"])

      assert fact_texts(facts) == [
               "amber alpha project owns amber alpha lesson",
               "amber direct project owns amber direct project"
             ]

      assert {:ok, [%{nodes: nodes, facts: facts}]} =
               exclusion_search(["lens:first-beta"], entity_types: ["Learning"])

      assert Enum.map(nodes, & &1.name) == ["amber alpha lesson"]
      assert Enum.map(facts, & &1.fact) == ["amber shared lesson fact"]
    end

    test "and each excluded Lens writer's Destination is still searched" do
      every_destination =
        Enum.map(Gralkor.Destination.Registry.configured!(), & &1.name)

      assert "first" in every_destination
      assert {:ok, results} = search(excluded_writers: ["lens:first-alpha"])

      assert Enum.map(results, & &1.destination) == every_destination

      for destination <- every_destination do
        assert_receive {:destination_search, ^destination, "operator-one", "question", opts}
        assert Keyword.fetch!(opts, :excluded_writers) == ["lens:first-alpha"]
        refute Keyword.has_key?(opts, :writers)
      end
    end

    test "and a writer excluded more than once is applied once" do
      assert {:ok, [%{destination: "first"}]} =
               search(
                 destinations: ["first"],
                 excluded_writers: ["lens:first-alpha", "unknown", "lens:first-alpha", "unknown"]
               )

      assert_receive {:destination_search, "first", _, _, opts}
      assert Keyword.fetch!(opts, :excluded_writers) == ["lens:first-alpha", "unknown"]
    end
  end

  describe "when a caller searches memory > where one or more writers are excluded > where writers are also included" do
    test "then a result is returned only when an included writer produced it and a writer that is not excluded produced it" do
      start_native_graph() |> seed_lens_graph() |> record_seeded_writers()

      assert {:ok, [%{facts: facts, nodes: nodes, episodes: episodes}]} =
               writer_search(["lens:*"], excluded_writers: ["lens:first-beta"])

      assert episode_contents(episodes) == ["amber alpha memory"]
      assert artefact_episodes(episodes) == []

      assert fact_texts(facts) == [
               "amber alpha lesson learns from amber alpha project",
               "amber alpha project owns amber alpha lesson",
               "amber shared lesson fact"
             ]

      assert node_names(nodes) == ["amber alpha lesson", "amber alpha project"]

      assert {:ok, [%{facts: facts}]} =
               writer_search(["lens:first-beta"], excluded_writers: ["lens:first-alpha"])

      assert fact_texts(facts) == [
               "amber beta lesson owns amber alpha lesson",
               "amber shared lesson fact"
             ]

      assert {:ok, [%{facts: [shared], nodes: [], episodes: []}]} =
               writer_search(["lens:first-beta"], excluded_writers: ["lens:first-beta"])

      assert shared.fact == "amber shared lesson fact"
      refute Map.has_key?(shared, :sources)

      assert {:ok, [%{facts: [], nodes: [], episodes: []}]} =
               writer_search(["lens:first-beta"],
                 excluded_writers: ["lens:first-beta", "lens:first-alpha"]
               )
    end
  end

  describe "when a caller searches memory > where one or more writers are excluded > while the search is made through an agent's runtime" do
    test "then the Lenses that excluded writers name resolve from that runtime's configuration" do
      start_runtime_with_lens()

      request = %Search{
        operator_id: "operator-one",
        query: "question",
        destinations: ["runtime-memory"],
        excluded_writers: ["lens:runtime-lens", "lens:runtime-lens"]
      }

      assert {:ok, [%{destination: "runtime-memory"}]} = Client.search(self(), request)
      assert_receive {:destination_search, "runtime-memory", _, _, opts}
      assert Keyword.fetch!(opts, :excluded_writers) == ["lens:runtime-lens"]

      assert_raise ArgumentError, ~r/runtime-lens/, fn ->
        Client.search(%Search{request | destinations: ["first"]})
      end

      assert_raise ArgumentError, ~r/first-alpha/, fn ->
        Client.search(self(), %Search{request | excluded_writers: ["lens:first-alpha"]})
      end
    end
  end

  describe "when a caller searches memory > where one or more writers are included or excluded" do
    test "then the search takes about as long as an unfiltered search of the same Destinations, however many results those writers produced" do
      graph = start_native_graph()
      seed_unrecorded_bulk_memory(graph)

      assert {:ok, [%{facts: [_ | _]}]} = search(query: "amber", destinations: ["first"])

      unfiltered = timed_search([])
      included = timed_search(writers: ["lens:first-alpha"])
      excluded = timed_search(excluded_writers: ["direct"])

      for {elapsed, {:ok, [%{facts: facts, episodes: episodes}]}} <- [included, excluded] do
        assert length(facts) == 50
        assert Enum.all?(facts, fn fact -> Enum.all?(fact.sources, &(&1[:lens] == "first-alpha")) end)
        assert [_ | _] = episodes
        assert Enum.all?(episodes, &(&1[:lens] == "first-alpha"))
        assert elapsed <= elem(unfiltered, 0) * 3 + 2_000
      end
    end
  end

  describe "when a search names a writer" do
    test "then `lens:<name>` names the Lens of that name" do
      start_native_graph() |> seed_lens_graph() |> record_seeded_writers()

      assert {:ok, [%{episodes: episodes}]} = writer_search(["lens:first-beta"])
      assert [%{content: "amber beta memory", lens: "first-beta"}] = episodes
    end

    test "and `reflection:<name>` names the Reflection of that name, whose output is stored in memory" do
      start_native_graph() |> seed_lens_graph() |> record_seeded_writers()
      assert :ok = put_artefact("first", "audit", "amber-audit", "amber audited memory")

      assert {:ok, [%{facts: [], nodes: [], episodes: episodes}]} =
               writer_search(["reflection:review"])

      assert [%{artefact: %{id: "amber-review"}, reflection: "review"}] = episodes
    end

    test "and `direct` names direct capture and direct memory addition" do
      start_native_graph() |> seed_lens_graph() |> record_seeded_writers()

      turns = [[Gralkor.Message.new("user", "amber captured memory")]]

      assert :ok =
               Gralkor.Application.build_flush_callback(nil).("first", "Susu", "Eli", nil, turns)

      assert {:ok, [%{episodes: episodes}]} = writer_search(["direct"])

      assert episode_contents(episodes) == ["Eli: amber captured memory", "amber direct memory"]
      assert Enum.all?(episodes, &(&1.writer == :direct))
    end

    test "and `unknown` names memory whose writer could not be determined" do
      start_native_graph() |> seed_lens_graph() |> record_seeded_writers()
      assert :ok = Gralkor.GraphitiPool.add_episode("first", "amber unattributed", "old", nil)

      assert {:ok, [%{episodes: [%{content: "amber unattributed"} = episode]}]} =
               writer_search(["unknown"])

      refute Map.has_key?(episode, :lens)
      refute Map.has_key?(episode, :reflection)
      refute Map.has_key?(episode, :writer)
    end

    test "and `lens:*` names every Lens" do
      start_native_graph() |> seed_lens_graph() |> record_seeded_writers()

      assert {:ok, [%{episodes: episodes}]} = writer_search(["lens:*"])
      assert episode_contents(episodes) == ["amber alpha memory", "amber beta memory"]
      assert artefact_episodes(episodes) == []
    end

    test "and `reflection:*` names every Reflection" do
      start_native_graph() |> seed_lens_graph() |> record_seeded_writers()
      assert :ok = put_artefact("first", "audit", "amber-audit", "amber audited memory")

      assert {:ok, [%{episodes: episodes}]} = writer_search(["reflection:*"])

      assert episodes |> Enum.map(& &1.reflection) |> Enum.sort() == ["audit", "review"]
      assert episode_contents(episodes) == []
    end
  end

  describe "when memory is written to a Destination" do
    test "then each episode is written by exactly one writer: the Lens it was ingested through, the Reflection whose output it stores, or direct capture or addition" do
      start_native_graph()
      assert :ok = ingest("amber-alpha", "first-alpha", "amber alpha memory")
      assert :ok = put_artefact("first", "review", "amber-review", "amber artefact memory")
      assert :ok = Gralkor.Client.Native.memory_add("first", "amber direct memory", "manual")

      writers = ["lens:first-alpha", "reflection:review", "direct", "unknown", "lens:first-beta"]

      found =
        Map.new(writers, fn writer ->
          assert {:ok, [%{episodes: episodes}]} = writer_search([writer])
          {writer, Enum.map(episodes, &(&1[:content] || &1.artefact.id))}
        end)

      assert found == %{
               "lens:first-alpha" => ["amber alpha memory"],
               "reflection:review" => ["amber-review"],
               "direct" => ["amber direct memory"],
               "unknown" => [],
               "lens:first-beta" => []
             }
    end

    test "and each fact is produced by the writer of every episode it was drawn from" do
      %{llm: llm} = start_native_graph()
      extract(llm, ["amber lesson", "amber project"], [shared_fact()])
      assert :ok = ingest("amber-alpha", "first-alpha", "amber lesson learns from amber project")
      assert :ok = Gralkor.Client.Native.memory_add("first", "amber lesson again", "manual")
      extract(llm, ["amber lesson", "amber beta project"], [beta_fact()])
      assert :ok = ingest("amber-beta", "first-beta", "amber lesson informs amber beta project")

      assert {:ok, [%{facts: [fact | _] = facts}]} = writer_search(["lens:first-alpha"])
      assert fact_texts(facts) == ["amber lesson learns from amber project"]
      assert fact.sources |> Enum.map(&Map.get(&1, :lens)) == ["first-alpha"]

      assert {:ok, [%{facts: facts}]} = writer_search(["direct"])
      assert fact_texts(facts) == ["amber lesson learns from amber project"]

      assert {:ok, [%{facts: facts}]} = exclusion_search(["lens:first-alpha", "lens:first-beta"])
      assert fact_texts(facts) == ["amber lesson learns from amber project"]

      assert {:ok, [%{facts: facts}]} = exclusion_search(["lens:first-alpha", "direct"])
      assert fact_texts(facts) == ["amber lesson informs amber beta project"]
    end

    test "and each entity is produced by the writer of every episode that mentions it" do
      %{llm: llm} = start_native_graph()
      extract(llm, ["amber lesson", "amber project"], [shared_fact()])
      assert :ok = ingest("amber-alpha", "first-alpha", "amber lesson learns from amber project")
      extract(llm, ["amber lesson"], [])
      assert :ok = Gralkor.Client.Native.memory_add("first", "amber lesson again", "manual")

      assert {:ok, [%{nodes: nodes}]} = writer_search(["lens:first-alpha"])
      assert node_names(nodes) == ["amber lesson", "amber project"]

      assert {:ok, [%{nodes: nodes}]} = writer_search(["direct"])
      assert node_names(nodes) == ["amber lesson"]

      assert {:ok, [%{nodes: nodes}]} = exclusion_search(["lens:first-alpha"])
      assert node_names(nodes) == ["amber lesson"]

      assert {:ok, [%{nodes: []}]} = exclusion_search(["lens:first-alpha", "direct"])
    end
  end

  describe "while a Destination holds memory written before its writers were recorded > when that Destination is first searched or written" do
    test "then each of its episodes, facts, and entities is produced by the writers its episodes' provenance records" do
      start_native_graph() |> seed_unrecorded_memory()

      assert {:ok, [%{facts: facts, nodes: nodes, episodes: episodes}]} =
               writer_search(["lens:first-alpha"])

      assert [%{content: "amber alpha memory", lens: "first-alpha"}] = episodes

      assert fact_texts(facts) == [
               "amber alpha project owns amber alpha lesson",
               "amber shared lesson fact"
             ]

      assert node_names(nodes) == ["amber alpha lesson", "amber alpha project"]

      assert {:ok, [%{facts: facts, nodes: nodes, episodes: episodes}]} =
               writer_search(["direct"])

      assert episode_contents(episodes) == ["amber direct memory", "amber marked memory"]
      assert fact_texts(facts) == ["amber direct project owns amber direct project"]
      assert node_names(nodes) == ["amber direct project"]

      assert {:ok, [%{facts: facts, episodes: episodes}]} = writer_search(["reflection:review"])
      assert [%{artefact: %{id: "amber-review"}, reflection: "review"}] = episodes
      assert fact_texts(facts) == ["amber shared lesson fact"]
    end

    test "and an episode whose writer cannot be determined is written by `unknown`" do
      start_native_graph() |> seed_unrecorded_memory()

      assert {:ok, [%{facts: facts, nodes: nodes, episodes: episodes}]} =
               writer_search(["unknown"])

      assert episode_contents(episodes) == ["amber historical memory"]
      assert fact_texts(facts) == ["amber historical lesson owns amber historical lesson"]
      assert node_names(nodes) == ["amber historical lesson"]

      assert {:ok, [%{episodes: episodes}]} = exclusion_search(["unknown"])
      refute "amber historical memory" in episode_contents(episodes)
    end

    test "and later searches by writer return that memory as they return memory written since" do
      start_native_graph() |> seed_unrecorded_memory()

      assert :ok = ingest("amber-alpha-later", "first-alpha", "amber alpha later memory")

      assert {:ok, [%{episodes: episodes}]} = writer_search(["lens:first-alpha"])
      assert episode_contents(episodes) == ["amber alpha later memory", "amber alpha memory"]

      assert {:ok, [%{episodes: episodes}]} = exclusion_search(["lens:first-alpha"])
      contents = episode_contents(episodes)
      refute "amber alpha memory" in contents
      refute "amber alpha later memory" in contents
      assert "amber direct memory" in contents
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

      assert %{valid_at: valid_at, created_at: created_at} = episode
      assert is_binary(valid_at) and is_binary(created_at)

      assert Map.drop(episode, [:valid_at, :created_at]) == %{
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

  describe "if a selected Destination search exits instead of returning" do
    test "then the search returns an error naming that Destination and its exit reason" do
      Application.put_env(:jido_gralkor, :destination_search_responses, %{
        "second" => {:exit, :janitor_timeout}
      })

      assert {:error, {:destination_search_exited, "second", :janitor_timeout}} =
               search(destinations: ["first", "second"])
    end

    test "and the caller does not exit" do
      Application.put_env(:jido_gralkor, :destination_search_responses, %{
        "second" => {:exit, :janitor_timeout}
      })

      test_pid = self()

      {caller, monitor} =
        spawn_monitor(fn ->
          send(test_pid, {:searched, search(destinations: ["first", "second"])})
        end)

      assert_receive {:searched, {:error, _reason}}
      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    end
  end

  describe "if search supplies a field removed in 12.0.0 or 17.0.0" do
    test "then search fails before any Destination query is started" do
      for {field, value, _version, _guidance} <- removed_fields() do
        assert_raise ArgumentError, fn -> search([{:destinations, ["first"]}, {field, value}]) end
        refute_receive {:destination_search, _, _, _, _}
      end
    end

    test "and the error names the removed field" do
      for {field, value, version, _guidance} <- removed_fields() do
        error = assert_raise ArgumentError, fn -> search([{field, value}]) end
        assert error.message =~ "#{inspect(field)} was removed in #{version}"
      end
    end

    test "and the error gives migration guidance for that field" do
      for {field, value, _version, guidance} <- removed_fields() do
        error = assert_raise ArgumentError, fn -> search([{field, value}]) end
        assert error.message =~ guidance
      end
    end
  end

  describe "if search supplies a Destination selection that is not a list of registered non-blank names" do
    test "then search fails before any Destination query is started" do
      for {selection, message} <- invalid_destination_selections() do
        assert_raise ArgumentError, ~r/#{Regex.escape(message)}/, fn ->
          search(destinations: selection)
        end

        refute_receive {:destination_search, _, _, _, _}
      end
    end

    test "and no valid subset is searched" do
      for {selection, _message} <- invalid_destination_selections() do
        assert_raise ArgumentError, fn -> search(destinations: selection) end
        refute_receive {:destination_search, "first", _, _, _}
      end
    end

    test "and the error identifies the rejected Destination selection and its rejected value" do
      for {selection, _message} <- invalid_destination_selections() do
        error = assert_raise ArgumentError, fn -> search(destinations: selection) end
        rejected = if is_list(selection), do: List.last(selection), else: selection
        assert error.message =~ ~r/destination/i
        assert error.message =~ inspect(rejected)
      end
    end
  end

  describe "if search includes or excludes anything but `direct`, `unknown`, `lens:*`, `reflection:*`, `lens:` naming a registered Lens, or `reflection:` with a non-blank name" do
    test "then search fails before any Destination query is started" do
      for {field, selection} <- invalid_writer_selections() do
        assert_raise ArgumentError, fn -> search([{field, selection}]) end
        refute_receive {:destination_search, _, _, _, _}
      end
    end

    test "and no valid subset is searched" do
      for {field, selection} <- invalid_writer_selections() do
        assert_raise ArgumentError, fn ->
          search([{:destinations, ["first"]}, {field, selection}])
        end

        refute_receive {:destination_search, "first", _, _, _}
      end
    end

    test "and the error says whether the rejected writer was included or excluded" do
      for {field, selection} <- invalid_writer_selections() do
        error = assert_raise ArgumentError, fn -> search([{field, selection}]) end

        case field do
          :writers ->
            assert error.message =~ "included writer"
            refute error.message =~ "excluded"

          :excluded_writers ->
            assert error.message =~ "excluded writer"
            refute error.message =~ "included"
        end
      end
    end

    test "and the error identifies the rejected value" do
      for {field, selection} <- invalid_writer_selections() do
        error = assert_raise ArgumentError, fn -> search([{field, selection}]) end
        rejected = if is_list(selection), do: List.last(selection), else: selection
        assert error.message =~ inspect(rejected)
      end
    end
  end

  defp search(overrides) do
    Client.search(
      struct!(
        Search,
        Keyword.merge([operator_id: "operator-one", query: "question"], overrides)
      )
    )
  end

  defp removed_fields do
    [
      {:result_type, :facts, "12.0.0", "every search now returns facts, nodes, and episodes"},
      {:artefact_id, "a-1", "12.0.0", "episodes carrying artefact"},
      {:max_results, 5, "12.0.0", "at most 50 facts, 20 nodes, and 15 episodes"},
      {:lenses, ["first-alpha"], "17.0.0", ~s(writers: ["lens:name"])},
      {:excluded_lenses, ["first-alpha"], "17.0.0", ~s(excluded_writers: ["lens:name"])},
      {:limits, %{facts: 1, nodes: 1, episodes: 1}, "17.0.0",
       "at most 50 facts, 20 nodes, and 15 episodes"}
    ]
  end

  defp invalid_destination_selections do
    [
      {["first", "missing"], ~s(unknown Destination "missing")},
      {"first", ~s(search destinations must be a list, got "first")},
      {["first", " "], ~s(invalid Destination name " ")}
    ]
  end

  defp invalid_writer_selections do
    for field <- [:writers, :excluded_writers],
        selection <- [
          ["direct", "lens:missing"],
          ["lens:"],
          ["lens:  "],
          ["reflection:"],
          ["reflection: "],
          ["first-alpha"],
          ["lens"],
          ["Direct"],
          [:direct],
          "direct"
        ],
        do: {field, selection}
  end

  defp writer_search(writers, overrides \\ []) do
    search([query: "amber", destinations: ["first"], writers: writers] ++ overrides)
  end

  defp exclusion_search(excluded_writers, overrides \\ []) do
    search(
      [query: "amber", destinations: ["first"], excluded_writers: excluded_writers] ++ overrides
    )
  end

  defp timed_search(overrides) do
    [{elapsed, _} = first | _] =
      for _ <- 1..3 do
        :timer.tc(
          fn -> search([query: "amber", destinations: ["first"]] ++ overrides) end,
          :millisecond
        )
      end
      |> Enum.sort_by(&elem(&1, 0))

    {elapsed, elem(first, 1)}
  end

  defp start_runtime_with_lens do
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
  end

  defp artefact_episodes(episodes), do: Enum.filter(episodes, &Map.has_key?(&1, :artefact))

  defp episode_contents(episodes) do
    episodes |> Enum.map(&Map.get(&1, :content)) |> Enum.reject(&is_nil/1) |> Enum.sort()
  end

  defp fact_texts(facts), do: facts |> Enum.map(& &1.fact) |> Enum.sort()

  defp node_names(nodes), do: nodes |> Enum.map(& &1.name) |> Enum.sort()

  defp ingest(id, lens, content) do
    Client.ingest(%Gralkor.Ingest{
      id: id,
      operator_id: "operator-one",
      lens: lens,
      source_kind: :document,
      content: content,
      source_description: "notes"
    })
  end

  defp put_artefact(destination, reflection, id, lesson) do
    Gralkor.Destination.Storage.put_artefact(
      %{
        kind: :destination,
        destination: Gralkor.Destination.Registry.fetch!(destination),
        ontology: Gralkor.DefaultOntology
      },
      reflection,
      "operator-one",
      Gralkor.Artefact.new(id, %{"lesson" => lesson})
    )
  end

  defp shared_fact,
    do: ["amber lesson", "amber project", "LEARNS_FROM", "amber lesson learns from amber project"]

  defp beta_fact,
    do: [
      "amber lesson",
      "amber beta project",
      "INFORMS",
      "amber lesson informs amber beta project"
    ]

  # What the substituted extractor returns for the next episode written.
  defp extract(llm, entities, edges) do
    Pythonx.eval(
      """
      import json
      llm.extraction = json.loads(extraction.decode('utf-8'))
      None
      """,
      %{"llm" => llm, "extraction" => Jason.encode!(%{entities: entities, edges: edges})}
    )
  end

  # Raw seeding below the graph library stands in for memory an earlier
  # release wrote; its graph instance re-initialises so it carries writers.
  defp record_seeded_writers(graph) do
    assert {:ok, _} = Gralkor.GraphitiPool.build_indices()
    graph
  end

  # The excluded `first-beta` episode also mentions `amber alpha lesson`, which
  # the kept `first-alpha` episode mentions too.
  defp seed_excluded_mention_of_alpha_lesson(%{database: database} = graph) do
    Pythonx.eval(
      """
      graph = database.select_graph('g_' + b'first'.hex())
      graph.query('''
        MATCH (beta:Episodic) WHERE beta.source_description ENDS WITH ' [lens: first-beta]'
        MATCH (al:Entity {uuid: 'alpha-lesson'})
        CREATE (beta)-[:MENTIONS {uuid: 'mentions-beta-al', group_id: beta.group_id, created_at: beta.created_at}]->(al)
      ''')
      """,
      %{"database" => database}
    )

    graph
  end

  # Sixty facts and entities and twenty episodes written only through the
  # `first-beta` Lens, each matching the query more strongly than any kept result.
  defp seed_competing_excluded_memory(%{database: database} = graph) do
    Pythonx.eval(
      """
      graph = database.select_graph('g_' + b'first'.hex())
      graph.query('''
        MATCH (beta:Episodic) WHERE beta.source_description ENDS WITH ' [lens: first-beta]'
        UNWIND range(1, 60) AS i
        CREATE (n:Entity:Project {uuid: 'excluded-' + toString(i), name: 'amber amber amber ' + toString(i), group_id: beta.group_id, summary: 'amber amber amber', created_at: beta.created_at}),
               (beta)-[:MENTIONS {uuid: 'excluded-mention-' + toString(i), group_id: beta.group_id, created_at: beta.created_at}]->(n),
               (n)-[e:RELATES_TO {uuid: 'excluded-fact-' + toString(i), name: 'OWNS', fact: 'amber amber amber ' + toString(i), episodes: [beta.uuid], group_id: beta.group_id, created_at: beta.created_at, valid_at: beta.valid_at}]->(n)
        SET n.name_embedding = vecf32([0.1, 0.2, 0.3]),
            e.fact_embedding = vecf32([0.1, 0.2, 0.3])
      ''')
      graph.query('''
        MATCH (beta:Episodic) WHERE beta.source_description ENDS WITH ' [lens: first-beta]'
        WITH beta LIMIT 1
        UNWIND range(1, 20) AS i
        CREATE (e:Episodic)
        SET e = properties(beta),
            e.uuid = 'excluded-episode-' + toString(i),
            e.content = 'amber amber amber ' + toString(i)
      ''')
      """,
      %{"database" => database}
    )

    graph
  end

  # One Destination holding memory from every writer: two appending Lenses
  # (each episode mentioning its own entities), a direct write, and a Reflection
  # artefact. `shared` is drawn from both Lenses' episodes.
  defp seed_lens_graph(%{database: database} = graph) do
    assert :ok = ingest("amber-alpha", "first-alpha", "amber alpha memory")
    assert :ok = ingest("amber-beta", "first-beta", "amber beta memory")
    assert :ok = Gralkor.Client.Native.memory_add("first", "amber direct memory", "manual")
    assert :ok = put_artefact("first", "review", "amber-review", "amber artefact memory")

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

  # Sixty direct facts and entities and twenty direct episodes, each matching
  # the query more strongly than any Lens result.
  defp seed_competing_direct_memory(%{database: database} = graph) do
    Pythonx.eval(
      """
      graph = database.select_graph('g_' + b'first'.hex())
      graph.query('''
        MATCH (direct:Episodic) WHERE direct.content = 'amber direct memory'
        UNWIND range(1, 60) AS i
        CREATE (n:Entity:Project {uuid: 'competing-' + toString(i), name: 'amber amber amber ' + toString(i), group_id: direct.group_id, summary: 'amber amber amber', created_at: direct.created_at}),
               (direct)-[:MENTIONS {uuid: 'competing-mention-' + toString(i), group_id: direct.group_id, created_at: direct.created_at}]->(n),
               (n)-[e:RELATES_TO {uuid: 'competing-fact-' + toString(i), name: 'OWNS', fact: 'amber amber amber ' + toString(i), episodes: [direct.uuid], group_id: direct.group_id, created_at: direct.created_at, valid_at: direct.valid_at}]->(n)
        SET n.name_embedding = vecf32([0.1, 0.2, 0.3]),
            e.fact_embedding = vecf32([0.1, 0.2, 0.3])
      ''')
      graph.query('''
        MATCH (direct:Episodic) WHERE direct.content = 'amber direct memory'
        UNWIND range(1, 20) AS i
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

  # Graphiti's indexes, created as an earlier release created them, before any
  # memory is written into the `first` graph.
  defp create_existing_indexes(database) do
    Pythonx.eval(
      """
      import time
      from graphiti_core.driver.driver import GraphProvider
      from graphiti_core.graph_queries import get_fulltext_indices, get_range_indices
      graph = database.select_graph('g_' + b'first'.hex())
      for query in get_range_indices(GraphProvider.FALKORDB) + get_fulltext_indices(GraphProvider.FALKORDB):
          graph.query(query)
      for _ in range(500):
          statuses = [row[0] for row in graph.query('CALL db.indexes() YIELD status RETURN status').result_set]
          if all('UNDER CONSTRUCTION' not in str(status) for status in statuses):
              break
          time.sleep(0.01)
      None
      """,
      %{"database" => database}
    )
  end

  # Memory written into `first` before writers were recorded: Lens, durable
  # direct, descriptively direct, Reflection, and unattributed episodes, with
  # the entities they mention and the facts drawn from them. Nothing carries
  # recorded writers, and no graph instance for `first` exists yet.
  defp seed_unrecorded_memory(%{database: database} = graph) do
    create_existing_indexes(database)

    artefact = Jason.encode!(%{id: "amber-review", payload: %{"lesson" => "amber artefact memory"}})

    Pythonx.eval(
      """
      graph = database.select_graph('g_' + b'first'.hex())
      graph.query('''
        CREATE (alpha:Episodic {uuid: 'old-alpha', name: 'old-alpha', group_id: $group, source: 'text', source_description: 'notes [lens: first-alpha]', content: 'amber alpha memory', entity_edges: [], created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z'}),
               (direct:Episodic {uuid: 'old-direct', name: 'old-direct', group_id: $group, source: 'text', source_description: 'manual', content: 'amber direct memory', entity_edges: [], created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z', _gralkor_writer: 'direct'}),
               (marked:Episodic {uuid: 'old-marked', name: 'old-marked', group_id: $group, source: 'text', source_description: 'manual [gralkor: direct]', content: 'amber marked memory', entity_edges: [], created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z'}),
               (review:Episodic {uuid: 'amber-review', name: 'amber-review', group_id: $group, source: 'json', source_description: 'reflection:review', content: $artefact, entity_edges: [], created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z', _gralkor_extraction_complete: true}),
               (old:Episodic {uuid: 'old-unknown', name: 'old-unknown', group_id: $group, source: 'text', source_description: 'old notes', content: 'amber historical memory', entity_edges: [], created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z'}),
               (al:Entity:Learning {uuid: 'alpha-lesson', name: 'amber alpha lesson', group_id: $group, summary: 'amber alpha lesson', created_at: '2026-01-01T00:00:00Z'}),
               (ap:Entity:Project {uuid: 'alpha-project', name: 'amber alpha project', group_id: $group, summary: 'amber alpha project', created_at: '2026-01-01T00:00:00Z'}),
               (dp:Entity:Project {uuid: 'direct-project', name: 'amber direct project', group_id: $group, summary: 'amber direct project', created_at: '2026-01-01T00:00:00Z'}),
               (hl:Entity:Learning {uuid: 'historical-lesson', name: 'amber historical lesson', group_id: $group, summary: 'amber historical lesson', created_at: '2026-01-01T00:00:00Z'}),
               (alpha)-[:MENTIONS {uuid: 'mentions-al', group_id: $group, created_at: '2026-01-01T00:00:00Z'}]->(al),
               (alpha)-[:MENTIONS {uuid: 'mentions-ap', group_id: $group, created_at: '2026-01-01T00:00:00Z'}]->(ap),
               (direct)-[:MENTIONS {uuid: 'mentions-dp', group_id: $group, created_at: '2026-01-01T00:00:00Z'}]->(dp),
               (old)-[:MENTIONS {uuid: 'mentions-hl', group_id: $group, created_at: '2026-01-01T00:00:00Z'}]->(hl),
               (ap)-[owns:RELATES_TO {uuid: 'alpha-owns', name: 'OWNS', fact: 'amber alpha project owns amber alpha lesson', episodes: ['old-alpha'], group_id: $group, created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z'}]->(al),
               (al)-[shared:RELATES_TO {uuid: 'shared', name: 'SHARES', fact: 'amber shared lesson fact', episodes: ['old-alpha', 'amber-review'], group_id: $group, created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z'}]->(ap),
               (dp)-[direct_owns:RELATES_TO {uuid: 'direct-owns', name: 'OWNS', fact: 'amber direct project owns amber direct project', episodes: ['old-direct'], group_id: $group, created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z'}]->(dp),
               (hl)-[historical:RELATES_TO {uuid: 'historical-owns', name: 'OWNS', fact: 'amber historical lesson owns amber historical lesson', episodes: ['old-unknown'], group_id: $group, created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z'}]->(hl)
        SET al.name_embedding = vecf32([0.1, 0.2, 0.3]),
            ap.name_embedding = vecf32([0.1, 0.2, 0.3]),
            dp.name_embedding = vecf32([0.1, 0.2, 0.3]),
            hl.name_embedding = vecf32([0.1, 0.2, 0.3]),
            owns.fact_embedding = vecf32([0.1, 0.2, 0.3]),
            shared.fact_embedding = vecf32([0.1, 0.2, 0.3]),
            direct_owns.fact_embedding = vecf32([0.1, 0.2, 0.3]),
            historical.fact_embedding = vecf32([0.1, 0.2, 0.3])
      ''', {'group': 'g_' + b'first'.hex(), 'artefact': artefact.decode('utf-8')})
      """,
      %{"database" => database, "artefact" => artefact}
    )

    graph
  end

  # Thousands of facts written before writers were recorded: 200 episodes
  # through `first-alpha` and 400 direct episodes, each with twenty-five facts
  # between its own entities, every fact matching the query.
  defp seed_unrecorded_bulk_memory(%{database: database} = graph) do
    create_existing_indexes(database)

    Pythonx.eval(
      """
      graph = database.select_graph('g_' + b'first'.hex())
      graph.query('''
        UNWIND range(0, 599) AS i
        CREATE (:Episodic {uuid: 'bulk-episode-' + toString(i), name: 'bulk-' + toString(i), group_id: $group, source: 'text',
                source_description: CASE WHEN i < 200 THEN 'change [lens: first-alpha]' ELSE 'manual' END,
                _gralkor_writer: CASE WHEN i < 200 THEN null ELSE 'direct' END,
                content: 'amber change ' + toString(i), entity_edges: [], created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z'})
      ''', {'group': 'g_' + b'first'.hex()})
      graph.query('''
        UNWIND range(0, 2999) AS i
        MATCH (episode:Episodic {uuid: 'bulk-episode-' + toString(i / 5)})
        CREATE (n:Entity {uuid: 'bulk-entity-' + toString(i), name: 'amber entity ' + toString(i), group_id: $group, summary: 'amber', created_at: '2026-01-01T00:00:00Z'}),
               (episode)-[:MENTIONS {uuid: 'bulk-mention-' + toString(i), group_id: $group, created_at: '2026-01-01T00:00:00Z'}]->(n)
        SET n.name_embedding = vecf32([0.1, 0.2, 0.3])
      ''', {'group': 'g_' + b'first'.hex()})
      graph.query('''
        UNWIND range(0, 14999) AS i
        MATCH (a:Entity {uuid: 'bulk-entity-' + toString(i / 5)}), (b:Entity {uuid: 'bulk-entity-' + toString((i / 25) * 5 + (i % 5))})
        CREATE (a)-[e:RELATES_TO {uuid: 'bulk-fact-' + toString(i), name: 'CHANGES', fact: 'amber fact ' + toString(i), episodes: ['bulk-episode-' + toString(i / 25)], group_id: $group, created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z'}]->(b)
        SET e.fact_embedding = vecf32([0.1, 0.2, 0.3])
      ''', {'group': 'g_' + b'first'.hex()})
      None
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

    test_pid = self()

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
          llm.extraction = {'entities': [], 'edges': []}
          async def generate_response(*args, **kwargs):
              model = kwargs.get('response_model')
              name = model.__name__ if model is not None else ''
              if name == 'ExtractedEntities':
                  return {'extracted_entities': [{'name': entity, 'entity_type_id': 0} for entity in llm.extraction['entities']]}
              if name == 'ExtractedEdges':
                  return {'edges': [
                      {'source_entity_name': source, 'target_entity_name': target, 'relation_type': relation, 'fact': fact}
                      for source, target, relation, fact in llm.extraction['edges']
                  ]}
              if name == 'SummarizedEntities': return {'summaries': []}
              if name == 'NodeResolutions': return {'entity_resolutions': []}
              if name == 'EdgeDuplicate': return {'duplicate_facts': [], 'contradicted_facts': []}
              if name == 'EdgeTimestamps': return {'valid_at': None, 'invalid_at': None}
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

      send(test_pid, {:fixture_llm, clients["llm"]})

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

    assert_receive {:fixture_llm, llm}

    %{database: globals["database"], llm: llm}
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
