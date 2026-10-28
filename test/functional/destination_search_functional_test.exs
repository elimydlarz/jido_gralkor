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
      use_in_memory_storage()

      for index <- 1..25 do
        assert :ok = add_episode("first", "operator-one", "memory #{index}", "first-alpha")
      end

      replace_first_graph(for index <- 1..25, do: node("node-#{index}", ["Project"]))

      assert {:ok, [%{facts: facts, nodes: nodes, episodes: episodes}]} =
               search(query: "memory", destinations: ["first"])

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

      assert Enum.map(results, & &1.destination) == ["personal", "global", "first", "second"]

      for destination <- ["personal", "global", "first", "second"] do
        assert_receive {:destination_search, ^destination, "operator-one", "question", _opts}
      end
    end

    test "and results written directly or by every Lens or Destination artefact output can contribute" do
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

    test "and a fact written by a graph replacement is returned by a search for one of its words" do
      start_native_graph()

      replace_first_graph(
        [replacement_entity("payments", "Payments"), replacement_entity("clearing", "Clearing")],
        [
          %{
            from: "payments",
            to: "clearing",
            type: "RELATES_TO",
            properties: %{
              uuid: "settlement",
              group_id: "first",
              name: "SETTLES_THROUGH",
              fact: "Payments settles through Clearing.",
              episodes: [],
              created_at: "2026-08-11T00:00:00Z"
            }
          }
        ]
      )

      assert {:ok, [%{destination: "first", facts: facts}]} =
               search(query: "clearing", destinations: ["first"])

      assert [
               %{
                 fact: "Payments settles through Clearing.",
                 relationship: "SETTLES_THROUGH",
                 source_node: %{uuid: "payments", name: "Payments"},
                 target_node: %{uuid: "clearing", name: "Clearing"}
               }
             ] = facts
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

  describe "if search supplies any Destination selection that is not a list of registered non-blank names" do
    test "then search fails before any Destination query is started" do
      for {destinations, message} <- invalid_selections() do
        assert_raise ArgumentError, ~r/#{Regex.escape(message)}/, fn ->
          search(destinations: destinations)
        end

        refute_receive {:destination_search, _, _, _, _}
      end
    end

    test "and no valid subset is searched" do
      for {destinations, _message} <- invalid_selections() do
        assert_raise ArgumentError, fn -> search(destinations: destinations) end
        refute_receive {:destination_search, "first", _, _, _}
      end
    end

    test "and the error identifies the rejected Destination selection" do
      for {destinations, _message} <- invalid_selections() do
        error = assert_raise ArgumentError, fn -> search(destinations: destinations) end
        assert error.message =~ ~r/destination/i
      end
    end

    test "and the error identifies the rejected value" do
      for {destinations, _message} <- invalid_selections() do
        error = assert_raise ArgumentError, fn -> search(destinations: destinations) end
        rejected = if is_list(destinations), do: List.last(destinations), else: destinations
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
      {:lenses, ["first-alpha"], "no longer filters by originating Lens"},
      {:artefact_id, "a-1", "episodes carrying artefact"},
      {:max_results, 5, "limits are fixed per Destination"}
    ]
  end

  defp invalid_selections do
    [
      {["first", "missing"], ~s(unknown Destination "missing")},
      {"first", ~s(search destinations must be a list, got "first")},
      {["first", " "], ~s(invalid Destination name " ")}
    ]
  end

  defp typed_facts do
    assert {:ok, [%{facts: facts}]} = search(query: "amber", destinations: ["first"])
    Enum.sort_by(facts, & &1.fact)
  end

  defp fact_search, do: search(query: "fact", destinations: ["first"])

  defp node(id, labels), do: %{id: id, labels: labels, properties: %{title: id}}

  defp replace_first_graph(nodes, relationships \\ []) do
    store = %Gralkor.Lens.Store{
      operator_id: "operator-one",
      lens: %Gralkor.Lens.Replaceable{
        name: "first-graph",
        destination: Gralkor.Destination.Registry.fetch!("first")
      }
    }

    assert :ok =
             Gralkor.Lens.Store.replace_graph(store, %Gralkor.Graph{
               nodes: nodes,
               relationships: relationships
             })
  end

  defp replacement_entity(id, name) do
    %{
      id: id,
      labels: ["Entity"],
      properties: %{
        uuid: id,
        group_id: "first",
        name: name,
        summary: name,
        created_at: "2026-08-11T00:00:00Z"
      }
    }
  end

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
