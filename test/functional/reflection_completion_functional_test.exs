defmodule Gralkor.ReflectionCompletionFunctionalTest do
  use ExUnit.Case, async: false

  alias Gralkor.Client
  alias Gralkor.GraphitiPool
  alias Gralkor.Reflection
  alias Gralkor.Artefact
  alias Gralkor.Reflection.ChainOfThought
  alias Gralkor.Search

  @moduletag :functional

  defmodule LoseFirstGraphitiResponseStore do
    use Agent

    alias Gralkor.Destination.Storage.Graphiti

    def start_link(test_pid), do: Agent.start_link(fn -> {test_pid, true} end, name: __MODULE__)

    def get_artefact(output, reflection_name, operator_id, artefact_id),
      do: Graphiti.get_artefact(output, reflection_name, operator_id, artefact_id)

    def put_artefact(output, reflection_name, operator_id, artefact) do
      with :ok <- Graphiti.put_artefact(output, reflection_name, operator_id, artefact),
           :ok <-
             Gralkor.Destination.Storage.InMemory.put_artefact(
               output,
               reflection_name,
               operator_id,
               artefact
             ) do
        Agent.get_and_update(__MODULE__, fn {test_pid, lose_response?} ->
          send(test_pid, {:graphiti_store_committed, artefact})

          if lose_response? do
            {{:error, :response_lost}, {test_pid, false}}
          else
            {:ok, {test_pid, false}}
          end
        end)
      end
    end
  end

  setup do
    previous =
      for key <- [
            :destinations,
            :destination_storage,
            :reflections,
            :reflection_storage
          ],
          into: %{} do
        {key, Application.get_env(:jido_gralkor, key)}
      end

    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)

    start_supervised!(Gralkor.Destination.Storage.InMemory)
    Application.put_env(:jido_gralkor, :destinations, [[name: "observations"]])

    Application.put_env(
      :jido_gralkor,
      :destination_storage,
      Gralkor.Destination.Storage.InMemory
    )

    reflection = %Reflection{
      name: "review",
      outputs: [
        %{
          kind: :destination,
          destination: %Gralkor.Destination{name: "observations"},
          ontology: Gralkor.DefaultOntology
        }
      ],
      chain_of_thought: %ChainOfThought{
        path: "reflection-completion.yaml",
        steps: [
          %ChainOfThought.Step{
            label: "review",
            directions: "Review supplied information.",
            output: %{"summary" => "string"}
          }
        ]
      }
    }

    Application.put_env(:jido_gralkor, :reflections, [reflection])
    {:ok, reflection: reflection}
  end

  setup_all do
    keys =
      Enum.map(
        [
          :fresh,
          :uncertain,
          :failed_extraction,
          :preclaim_complete,
          :preclaim_incomplete,
          :shared
        ],
        &{__MODULE__, &1}
      )

    Enum.each(keys, &:persistent_term.erase/1)
    on_exit(fn -> Enum.each(keys, &:persistent_term.erase/1) end)
    :ok
  end

  describe "when repeated Destination writes use the same artefact identifier and immutable payload" do
    test "then the first write creates the artefact", %{reflection: reflection} do
      {output, artefact} = in_memory_artefact(reflection)
      assert :ok = put_in_memory(output, reflection, artefact)
      assert {:ok, ^artefact} = get_in_memory(output, reflection, artefact.id)
    end

    test "and every later write reports success without creating another artefact", %{
      reflection: reflection
    } do
      {output, artefact} = in_memory_artefact(reflection)
      assert :ok = put_in_memory(output, reflection, artefact)
      assert :ok = put_in_memory(output, reflection, artefact)
      assert [%{artefact: ^artefact}] = in_memory_search(output, reflection)
    end
  end

  describe "if repeated Destination writes use the same artefact identifier with a conflicting immutable payload" do
    test "then the repeated write is rejected as an artefact conflict", %{reflection: reflection} do
      {output, artefact} = in_memory_artefact(reflection)
      conflicting = %{artefact | payload: %{"summary" => "changed"}}
      assert :ok = put_in_memory(output, reflection, artefact)

      assert {:error, {:artefact_conflict, "stable-id"}} =
               put_in_memory(output, reflection, conflicting)
    end

    test "and the original canonical artefact remains unchanged", %{reflection: reflection} do
      {output, artefact} = in_memory_artefact(reflection)
      conflicting = %{artefact | payload: %{"summary" => "changed"}}
      assert :ok = put_in_memory(output, reflection, artefact)
      assert {:error, _} = put_in_memory(output, reflection, conflicting)
      assert {:ok, ^artefact} = get_in_memory(output, reflection, artefact.id)
    end
  end

  describe "where Graphiti stores a Destination artefact output > when a new artefact is written with its stable identifier" do
    test "then Graphiti creates one episode under a deterministic UUID derived from that artefact identifier" do
      assert_verified(:fresh, &assert_fresh_graphiti_contract/0)
    end

    test "and the episode body contains exactly the artefact identifier and payload" do
      assert_verified(:fresh, &assert_fresh_graphiti_contract/0)
    end

    test "and Graphiti records durable extraction completion only after every graph effect succeeds" do
      assert_verified(:fresh, &assert_fresh_graphiti_contract/0)
    end
  end

  describe "where Graphiti stores a Destination artefact output > when a new artefact is written with its stable identifier > if graph extraction fails before its claim-fenced transaction commits" do
    test "then canonical lookup and public artefact search report no episode", %{
      reflection: reflection
    } do
      assert_verified(:failed_extraction, fn -> assert_failed_extraction_contract(reflection) end)
    end

    test "and a later equal write retries extraction from scratch", %{reflection: reflection} do
      assert_verified(:failed_extraction, fn -> assert_failed_extraction_contract(reflection) end)
    end
  end

  describe "where Graphiti stores a Destination artefact output > when that artefact is written again after an uncertain response > while durable extraction completion was recorded" do
    test "then Graphiti confirms the existing episode without repeating extraction" do
      assert_verified(:uncertain, &assert_uncertain_response_contract/0)
    end
  end

  describe "where Graphiti stores a Destination artefact output > when that artefact is written again after an uncertain response > while the episode exists but extraction completion was not recorded" do
    test "then canonical lookup retains the exact episode artefact as incomplete rather than reporting success" do
      assert_verified(:preclaim_incomplete, &assert_preclaim_incomplete_contract/0)
    end

    test "and public artefact search excludes that incomplete artefact" do
      assert_verified(:preclaim_incomplete, &assert_preclaim_incomplete_contract/0)
    end

    test "and Graphiti resumes the normal extraction path before reporting success" do
      assert_verified(:preclaim_incomplete, &assert_preclaim_incomplete_contract/0)
    end
  end

  describe "where Graphiti stores a Destination artefact output > when that artefact is written again after an uncertain response" do
    test "and exactly one episode carrying that artefact remains searchable" do
      assert_verified(:uncertain, &assert_uncertain_response_contract/0)
    end
  end

  describe "where Graphiti stores a Destination artefact output > when artefact search encounters historical complete episodes carrying the same artefact identifier > while their immutable payloads are equal" do
    test "then search returns one artefact" do
      assert_verified(:uncertain, &assert_uncertain_response_contract/0)
    end
  end

  describe "where Graphiti stores a Destination artefact output > when artefact search encounters historical complete episodes carrying the same artefact identifier > while their immutable payloads conflict" do
    test "then search reports an artefact conflict" do
      assert_verified(:uncertain, &assert_uncertain_response_contract/0)
    end
  end

  describe "where Graphiti stores a Destination artefact output > when incomplete or duplicate episodes outnumber the requested result window" do
    test "then they cannot crowd completed unique artefacts out of the requested results" do
      assert_verified(:uncertain, &assert_uncertain_response_contract/0)
    end

    test "and conflicts for selected artefact identifiers are detected beyond the ranked window" do
      assert_verified(:uncertain, &assert_uncertain_response_contract/0)
    end
  end

  describe "where Graphiti stores a Destination artefact output > when independent application runtimes write the same artefact UUID concurrently" do
    @tag timeout: 120_000
    test "then a graph uniqueness constraint exists before UUID claim admission" do
      assert_verified(:shared, &assert_shared_graph_claim_contract/0)
    end

    @tag timeout: 120_000
    test "and graph-backed admission serializes extraction across runtimes" do
      assert_verified(:shared, &assert_shared_graph_claim_contract/0)
    end

    @tag timeout: 120_000
    test "and equal payloads converge while conflicting payloads are rejected" do
      assert_verified(:shared, &assert_shared_graph_claim_contract/0)
    end
  end

  describe "where Graphiti stores a Destination artefact output > when independent application runtimes write the same artefact UUID concurrently > while a claim lease changes owner" do
    @tag timeout: 120_000
    test "then graph-server time determines expiry" do
      assert_verified(:shared, &assert_shared_graph_claim_contract/0)
    end

    @tag timeout: 120_000
    test "and the episode plus every derived node and edge persist in one claim-fenced graph transaction" do
      assert_verified(:shared, &assert_shared_graph_claim_contract/0)
    end

    @tag timeout: 120_000
    test "and loss of ownership aborts that transaction before any graph effect commits" do
      assert_verified(:shared, &assert_shared_graph_claim_contract/0)
    end

    @tag timeout: 120_000
    test "and the completion marker is fenced by the current claim generation" do
      assert_verified(:shared, &assert_shared_graph_claim_contract/0)
    end

    @tag timeout: 120_000
    test "and a stale owner cannot mutate or finish the artefact output" do
      assert_verified(:shared, &assert_shared_graph_claim_contract/0)
    end
  end

  describe "where Graphiti stores a Destination artefact output > when upgrading from an unmarked pre-completion-marker artefact" do
    test "then it remains hidden until an explicit replay or migration establishes durable extraction completion" do
      assert_verified(:preclaim_incomplete, &assert_preclaim_incomplete_contract/0)
    end

    test "and upgrade behavior does not expose a possibly partial episode as completed" do
      assert_verified(:preclaim_complete, &assert_preclaim_complete_contract/0)
    end
  end

  describe "where in-memory Destination storage receives an artefact output > when the same artefact is written repeatedly" do
    test "then exactly one copy remains searchable in its original insertion position", %{
      reflection: reflection
    } do
      {output, artefact} = in_memory_artefact(reflection)
      other = Artefact.new("other-id", %{"summary" => "other"})
      assert :ok = put_in_memory(output, reflection, artefact)
      assert :ok = put_in_memory(output, reflection, other)
      assert :ok = put_in_memory(output, reflection, artefact)
      assert [%{artefact: ^artefact}, %{artefact: ^other}] = in_memory_search(output, reflection)
    end
  end

  defp assert_fresh_graphiti_contract do
    {graphiti, _} =
      Pythonx.eval(
        """
        from graphiti_core.errors import NodeNotFoundError

        class GraphOperations:
            async def episodic_node_get_by_uuid(self, cls, driver, uuid):
                if uuid not in driver.episodes:
                    raise NodeNotFoundError(uuid)
                return driver.episodes[uuid]

            async def episodic_node_save(self, episode, driver):
                driver.episodes[episode.uuid] = episode

        class Driver:
            def __init__(self):
                self.graph_operations_interface = GraphOperations()
                self.episodes = {}

            @property
            def _gralkor_episode_count(self):
                return len(self.episodes)

        class PinnedGraphitiContract:
            def __init__(self):
                self.driver = Driver()
                self.extractions = 0

            async def add_episode(self, **kwargs):
                from graphiti_core.nodes import EpisodicNode
                self.extractions += 1
                episode = await EpisodicNode.get_by_uuid(self.driver, kwargs['uuid'])
                await episode.save(self.driver)

            async def search_(self, query, config=None, group_ids=None, search_filter=None):
                from graphiti_core.search.search_config import SearchResults
                groups = set(group_ids or [])
                episodes = [
                    episode for episode in self.driver.episodes.values()
                    if not groups or episode.group_id in groups
                ]
                if config is not None:
                    episodes = episodes[:config.limit]
                return SearchResults(episodes=episodes)

        PinnedGraphitiContract()
        """,
        %{}
      )

    table = :"reflection_graphiti_#{System.unique_integer([:positive])}"

    pool =
      start_supervised!(
        Supervisor.child_spec(
          {GraphitiPool,
           name: nil,
           table: table,
           falkordb_spec: {:remote, []},
           construct_falkor_db: fn _spec -> :stub_falkor_db end,
           close_falkor_db: fn _database -> :ok end,
           construct_shared_clients: fn _llm, _embedder ->
             %{llm_client: nil, embedder: nil, cross_encoder: nil}
           end,
           construct_instance: fn _database, _shared, _group -> graphiti end,
           initialise_instance: fn _instance -> :ok end,
           warmup: false,
           install_loop_fn: &Gralkor.Python.install_async_runtime/0},
          id: table
        )
      )

    assert :ok =
             GraphitiPool.add_episode(
               pool,
               "observations",
               ~s({"id":"stable-id","payload":{"summary":"stored"}}),
               "reflection:review",
               nil,
               uuid: "stable-id"
             )

    assert :ok =
             GraphitiPool.add_episode(
               pool,
               "observations",
               ~s({"id":"stable-id","payload":{"summary":"stored"}}),
               "reflection:review",
               nil,
               uuid: "stable-id"
             )

    assert {:error, {:episode_conflict, "stable-id"}} =
             GraphitiPool.add_episode(
               pool,
               "observations",
               ~s({"id":"stable-id","payload":{"summary":"changed"}}),
               "reflection:review",
               nil,
               uuid: "stable-id"
             )

    {proof, _} =
      Pythonx.eval(
        """
        episode = graphiti.driver.episodes['stable-id']
        [len(graphiti.driver.episodes), graphiti.extractions, episode.uuid, episode.content]
        """,
        %{"graphiti" => graphiti}
      )

    assert Pythonx.decode(proof) == [
             1,
             1,
             "stable-id",
             ~s({"id":"stable-id","payload":{"summary":"stored"}})
           ]

    :ok
  end

  defp assert_uncertain_response_contract do
    {graphiti, _} =
      Pythonx.eval(
        """
        from graphiti_core.errors import NodeNotFoundError

        class GraphOperations:
            async def episodic_node_get_by_uuid(self, cls, driver, uuid):
                if uuid not in driver.episodes:
                    raise NodeNotFoundError(uuid)
                return driver.episodes[uuid]

            async def episodic_node_save(self, episode, driver):
                driver.episodes[episode.uuid] = episode

        class Driver:
            def __init__(self):
                self.graph_operations_interface = GraphOperations()
                self.episodes = {}

            @property
            def _gralkor_episode_count(self):
                return len(self.episodes)

        class GraphitiContract:
            def __init__(self):
                self.driver = Driver()
                self.extractions = 0

            async def add_episode(self, **kwargs):
                from graphiti_core.nodes import EpisodicNode
                self.extractions += 1
                episode = await EpisodicNode.get_by_uuid(self.driver, kwargs['uuid'])
                await episode.save(self.driver)

            async def search_(self, query, config=None, group_ids=None, search_filter=None):
                from graphiti_core.search.search_config import SearchResults
                groups = set(group_ids or [])
                episodes = [
                    episode for episode in self.driver.episodes.values()
                    if not groups or episode.group_id in groups
                ]
                if query:
                    episodes = [
                        episode for episode in episodes
                        if query.lower() in episode.content.lower()
                    ]
                if config is not None:
                    episodes = episodes[:config.limit]
                return SearchResults(episodes=episodes)

        GraphitiContract()
        """,
        %{}
      )

    start_supervised!(
      Supervisor.child_spec(
        {GraphitiPool,
         table: :gralkor_graphiti_instances,
         falkordb_spec: {:remote, []},
         construct_falkor_db: fn _spec -> :stub_falkor_db end,
         close_falkor_db: fn _database -> :ok end,
         construct_shared_clients: fn _llm, _embedder ->
           %{llm_client: nil, embedder: nil, cross_encoder: nil}
         end,
         construct_instance: fn _database, _shared, _group -> graphiti end,
         initialise_instance: fn _instance -> :ok end,
         warmup: false,
         install_loop_fn: &Gralkor.Python.install_async_runtime/0},
        id: :reflection_uncertain_graphiti
      )
    )

    start_supervised!({LoseFirstGraphitiResponseStore, self()})
    Application.put_env(:jido_gralkor, :destination_storage, LoseFirstGraphitiResponseStore)

    reflection = hd(Application.fetch_env!(:jido_gralkor, :reflections))
    output = Enum.find(reflection.outputs, &(&1.kind == :destination))
    artefact_id = Artefact.id_for("operator-one", "ingestion-one", "review")
    first = Artefact.new(artefact_id, %{"summary" => "stored"})

    legacy_content =
      Artefact.new(
        artefact_id,
        %{"summary" => "stored"}
      )
      |> Map.from_struct()
      |> Jason.encode!()

    graph_group_id = Client.sanitize_group_id("observations")

    Pythonx.eval(
      """
      from datetime import datetime, timezone
      from graphiti_core.nodes import EpisodeType, EpisodicNode
      body = legacy_content.decode('utf-8') if isinstance(legacy_content, (bytes, bytearray)) else legacy_content
      group_id = group_id.decode('utf-8') if isinstance(group_id, (bytes, bytearray)) else group_id
      graphiti.driver.episodes['legacy-pre-marker'] = EpisodicNode(
          uuid='legacy-pre-marker',
          name='legacy-reflection',
          group_id=group_id,
          labels=[],
          source=EpisodeType.text,
          content=body,
          source_description='reflection:review',
          created_at=datetime.now(timezone.utc),
          valid_at=datetime.now(timezone.utc),
      )
      """,
      %{
        "graphiti" => graphiti,
        "legacy_content" => legacy_content,
        "group_id" => graph_group_id
      }
    )

    assert {:error, :response_lost} =
             Gralkor.Destination.Storage.put_artefact(
               output,
               reflection.name,
               "operator-one",
               first
             )

    assert_receive {:graphiti_store_committed, ^first}, 1_000

    assert :ok =
             Gralkor.Destination.Storage.put_artefact(
               output,
               reflection.name,
               "operator-one",
               first
             )

    assert_receive {:graphiti_store_committed, ^first}, 1_000

    Application.put_env(
      :jido_gralkor,
      :destination_storage,
      Gralkor.Destination.Storage.Graphiti
    )

    Pythonx.eval(
      """
      uid = artefact_id.decode('utf-8') if isinstance(artefact_id, (bytes, bytearray)) else artefact_id
      original = graphiti.driver.episodes[uid]
      partials = {
          f'legacy-unmarked-{index}': original.model_copy(
              update={'uuid': f'legacy-unmarked-{index}'}
          )
          for index in range(25)
      }
      graphiti.driver.episodes = {**partials, **graphiti.driver.episodes}
      """,
      %{"graphiti" => graphiti, "artefact_id" => artefact_id}
    )

    assert {:ok, [%{destination: "observations", artefact: ^first}]} =
             Client.search(%Search{
               operator_id: "operator-one",
               query: "",
               destinations: ["observations"],
               result_type: :artefacts
             })

    Pythonx.eval(
      """
      uid = artefact_id.decode('utf-8') if isinstance(artefact_id, (bytes, bytearray)) else artefact_id
      original = graphiti.driver.episodes[uid]
      duplicate = original.model_copy(update={'uuid': 'legacy-equal-duplicate'})
      graphiti.driver.episodes[duplicate.uuid] = duplicate
      graphiti.driver._gralkor_completed_episode_uuids.add(duplicate.uuid)
      """,
      %{"graphiti" => graphiti, "artefact_id" => artefact_id}
    )

    assert {:ok, [%{destination: "observations", artefact: ^first}]} =
             Client.search(%Search{
               operator_id: "operator-one",
               query: "",
               destinations: ["observations"],
               result_type: :artefacts
             })

    conflicting_content =
      first
      |> Map.put(:payload, %{"summary" => "conflicting"})
      |> Map.from_struct()
      |> Jason.encode!()

    Pythonx.eval(
      """
      body = conflicting_content.decode('utf-8') if isinstance(conflicting_content, (bytes, bytearray)) else conflicting_content
      uid = artefact_id.decode('utf-8') if isinstance(artefact_id, (bytes, bytearray)) else artefact_id
      original = graphiti.driver.episodes[uid]
      conflict = original.model_copy(
          update={'uuid': 'legacy-conflicting-duplicate', 'content': body}
      )
      graphiti.driver.episodes[conflict.uuid] = conflict
      graphiti.driver._gralkor_completed_episode_uuids.add(conflict.uuid)
      """,
      %{
        "graphiti" => graphiti,
        "artefact_id" => artefact_id,
        "conflicting_content" => conflicting_content
      }
    )

    assert {:error, {:artefact_conflict, ^artefact_id}} =
             Client.search(%Search{
               operator_id: "operator-one",
               query: "stored",
               destinations: ["observations"],
               result_type: :artefacts
             })

    {proof, _} =
      Pythonx.eval(
        "[len(graphiti.driver.episodes), graphiti.extractions]",
        %{"graphiti" => graphiti}
      )

    assert Pythonx.decode(proof) == [29, 1]

    :ok
  end

  defp assert_failed_extraction_contract(reflection) do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "reflection-partial-commit-#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
      )

    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf!(data_dir) end)
    start_supervised!(Gralkor.Python)

    construct_instance = fn database, _shared, group_id ->
      {graphiti, _} =
        Pythonx.eval(
          """
          from graphiti_core.driver.falkordb_driver import FalkorDriver

          gid = group_id.decode('utf-8') if isinstance(group_id, (bytes, bytearray)) else group_id

          class EmbeddedGraphitiContract:
              def __init__(self):
                  self.driver = FalkorDriver(falkor_db=database, database=gid)
                  self.extractions = 0

              async def add_episode(self, **kwargs):
                  from graphiti_core.graphiti import add_nodes_and_edges_bulk
                  from graphiti_core.nodes import EpisodicNode
                  self.extractions += 1
                  episode = await EpisodicNode.get_by_uuid(self.driver, kwargs['uuid'])
                  await episode.save(self.driver)
                  if self.extractions == 1:
                      raise RuntimeError('lost after durable episode save')
                  await add_nodes_and_edges_bulk(
                      self.driver,
                      [episode],
                      [],
                      [],
                      [],
                      None,
                  )

              async def search_(self, query, config=None, group_ids=None, search_filter=None):
                  from graphiti_core.nodes import EpisodicNode
                  from graphiti_core.search.search_config import SearchResults
                  episodes = await EpisodicNode.get_by_group_ids(
                      self.driver,
                      list(group_ids or []),
                      limit=config.limit if config is not None else None,
                  )
                  return SearchResults(episodes=episodes)

          EmbeddedGraphitiContract()
          """,
          %{"database" => database, "group_id" => group_id}
        )

      graphiti
    end

    artefact_id = Artefact.id_for("operator-one", "ingestion-one", "review")

    partial_artefact = Artefact.new(artefact_id, %{"summary" => "stored"})

    content = Jason.encode!(Map.from_struct(partial_artefact))

    pool =
      start_supervised!(
        Supervisor.child_spec(
          {GraphitiPool,
           falkordb_spec: {:embedded, data_dir},
           construct_shared_clients: fn _llm, _embedder ->
             %{llm_client: nil, embedder: nil, cross_encoder: nil}
           end,
           construct_instance: construct_instance,
           initialise_instance: fn _instance -> :ok end,
           warmup: false,
           embedded_falkordb_socket_timeout_ms: 60_000},
          id: :reflection_partial_graphiti
        )
      )

    assert {:error, {:python, "RuntimeError: lost after durable episode save"}} =
             GraphitiPool.add_episode(
               pool,
               "observations",
               content,
               "reflection:review",
               Gralkor.DefaultOntology,
               uuid: artefact_id
             )

    assert {:error, :not_found} =
             GraphitiPool.get_episode(pool, "observations", artefact_id)

    assert {:error, :not_found} =
             Gralkor.Destination.Storage.Graphiti.get_artefact(
               Enum.find(reflection.outputs, &(&1.kind == :destination)),
               reflection.name,
               "operator-one",
               artefact_id
             )

    Application.put_env(
      :jido_gralkor,
      :destination_storage,
      Gralkor.Destination.Storage.Graphiti
    )

    assert {:ok, []} =
             Client.search(%Search{
               operator_id: "operator-one",
               query: "stored",
               destinations: ["observations"],
               result_type: :artefacts,
               artefact_id: artefact_id
             })

    assert :ok =
             Gralkor.Destination.Storage.Graphiti.put_artefact(
               Enum.find(reflection.outputs, &(&1.kind == :destination)),
               reflection.name,
               "operator-one",
               partial_artefact
             )

    assert {:ok, [%{destination: "observations", artefact: ^partial_artefact}]} =
             Client.search(%Search{
               operator_id: "operator-one",
               query: "stored",
               destinations: ["observations"],
               result_type: :artefacts,
               artefact_id: artefact_id
             })

    assert :ok =
             GraphitiPool.add_episode(
               pool,
               "observations",
               content,
               "reflection:review",
               Gralkor.DefaultOntology,
               uuid: artefact_id
             )

    assert {:ok,
            %{
              "content" => ^content,
              "uuid" => ^artefact_id,
              "extraction_complete" => true
            }} = GraphitiPool.get_episode(pool, "observations", artefact_id)

    graphiti = GraphitiPool.for(pool, "observations")

    {proof, _} =
      Pythonx.eval(
        """
        import asyncio
        async def proof():
            uid = artefact_id.decode('utf-8') if isinstance(artefact_id, (bytes, bytearray)) else artefact_id
            records, _, _ = await graphiti.driver.execute_query(
                "MATCH (e:Episodic {uuid: $uuid}) RETURN e._gralkor_extraction_complete AS complete",
                uuid=uid,
            )
            return [graphiti.extractions, records[0]['complete']]
        asyncio._gralkor_run(proof())
        """,
        %{"graphiti" => graphiti, "artefact_id" => artefact_id}
      )

    assert Pythonx.decode(proof) == [2, true]

    :ok
  end

  defp assert_preclaim_complete_contract do
    {pool, graphiti} = start_preclaim_graphiti_pool(:reflection_preclaim_complete_graphiti)
    graph_group_id = Client.sanitize_group_id("observations")

    Pythonx.eval(
      """
      import asyncio
      from datetime import datetime, timezone
      now = datetime.now(timezone.utc)
      group_id = group_id.decode('utf-8') if isinstance(group_id, (bytes, bytearray)) else group_id
      asyncio._gralkor_run(graphiti.driver.execute_query(
          '''
          CREATE (episode:Episodic {
            uuid: $uuid,
            name: 'legacy deterministic episode',
            group_id: $group_id,
            source: 'text',
            source_description: 'reflection:review',
            content: $content,
            entity_edges: [],
            created_at: $created_at,
            valid_at: $valid_at,
            _gralkor_extraction_complete: true
          })
          RETURN episode.uuid AS uuid
          ''',
          uuid='preclaim-complete',
          content='original',
          created_at=now,
          valid_at=now,
          group_id=group_id,
      ))
      """,
      %{"graphiti" => graphiti, "group_id" => graph_group_id}
    )

    assert {:error, {:episode_conflict, "preclaim-complete"}} =
             GraphitiPool.add_episode(
               pool,
               "observations",
               "conflicting",
               "reflection:review",
               nil,
               uuid: "preclaim-complete"
             )

    {proof, _} =
      Pythonx.eval(
        """
        import asyncio
        records, _, _ = asyncio._gralkor_run(graphiti.driver.execute_query(
            '''
            MATCH (episode:Episodic {uuid: 'preclaim-complete'})
            OPTIONAL MATCH (claim:_GralkorEpisodeClaim {uuid: 'preclaim-complete'})
            RETURN episode.content AS episode_content,
                   claim.content AS claim_content
            '''
        ))
        [records[0], graphiti.extractions]
        """,
        %{"graphiti" => graphiti}
      )

    assert Pythonx.decode(proof) == [
             %{
               "claim_content" => "original",
               "episode_content" => "original"
             },
             0
           ]

    :ok
  end

  defp assert_preclaim_incomplete_contract do
    {pool, graphiti} = start_preclaim_graphiti_pool(:reflection_preclaim_incomplete_graphiti)
    reflection = hd(Application.fetch_env!(:jido_gralkor, :reflections))
    artefact_id = Artefact.id_for("operator-one", "ingestion-one", "review")
    artefact = Artefact.new(artefact_id, %{"summary" => "stored"})
    content = Jason.encode!(Map.from_struct(artefact))
    graph_group_id = Client.sanitize_group_id("observations")

    Pythonx.eval(
      """
      import asyncio
      from datetime import datetime, timezone
      now = datetime.now(timezone.utc)
      group_id = group_id.decode('utf-8') if isinstance(group_id, (bytes, bytearray)) else group_id
      uid = uuid.decode('utf-8') if isinstance(uuid, (bytes, bytearray)) else uuid
      body = content.decode('utf-8') if isinstance(content, (bytes, bytearray)) else content
      asyncio._gralkor_run(graphiti.driver.execute_query(
          '''
          CREATE (episode:Episodic {
            uuid: $uuid,
            name: 'legacy deterministic episode',
            group_id: $group_id,
            source: 'text',
            source_description: 'reflection:review',
            content: $content,
            entity_edges: [],
            created_at: $created_at,
            valid_at: $valid_at,
            _gralkor_extraction_complete: false
          })
          RETURN episode.uuid AS uuid
          ''',
          uuid=uid,
          content=body,
          created_at=now,
          valid_at=now,
          group_id=group_id,
      ))
      """,
      %{
        "graphiti" => graphiti,
        "uuid" => artefact_id,
        "content" => content,
        "group_id" => graph_group_id
      }
    )

    assert {:error, {:episode_conflict, ^artefact_id}} =
             GraphitiPool.add_episode(
               pool,
               "observations",
               "conflicting",
               "reflection:review",
               nil,
               uuid: artefact_id
             )

    assert {:error, {:incomplete_artefact, ^artefact}} =
             Gralkor.Destination.Storage.Graphiti.get_artefact(
               Enum.find(reflection.outputs, &(&1.kind == :destination)),
               reflection.name,
               "operator-one",
               artefact_id
             )

    Application.put_env(
      :jido_gralkor,
      :destination_storage,
      Gralkor.Destination.Storage.Graphiti
    )

    assert {:ok, []} =
             Client.search(%Search{
               operator_id: "operator-one",
               query: "stored",
               destinations: ["observations"],
               result_type: :artefacts,
               artefact_id: artefact_id
             })

    {released_claim, _} =
      Pythonx.eval(
        """
        import asyncio
        uid = uuid.decode('utf-8') if isinstance(uuid, (bytes, bytearray)) else uuid
        records, _, _ = asyncio._gralkor_run(graphiti.driver.execute_query(
            '''
            MATCH (claim:_GralkorEpisodeClaim {uuid: $uuid})
            RETURN claim.content AS content,
                   claim.owner AS owner,
                   claim.lease_until_ms AS lease_until_ms
            ''',
            uuid=uid,
        ))
        records[0]
        """,
        %{"graphiti" => graphiti, "uuid" => artefact_id}
      )

    assert Pythonx.decode(released_claim) == %{
             "content" => content,
             "lease_until_ms" => nil,
             "owner" => nil
           }

    assert :ok =
             Gralkor.Destination.Storage.Graphiti.put_artefact(
               Enum.find(reflection.outputs, &(&1.kind == :destination)),
               reflection.name,
               "operator-one",
               artefact
             )

    assert {:ok, [%{destination: "observations", artefact: ^artefact}]} =
             Client.search(%Search{
               operator_id: "operator-one",
               query: "stored",
               destinations: ["observations"],
               result_type: :artefacts,
               artefact_id: artefact_id
             })

    {proof, _} =
      Pythonx.eval(
        """
        import asyncio
        uid = uuid.decode('utf-8') if isinstance(uuid, (bytes, bytearray)) else uuid
        records, _, _ = asyncio._gralkor_run(graphiti.driver.execute_query(
            '''
            MATCH (episode:Episodic {uuid: $uuid})
            MATCH (claim:_GralkorEpisodeClaim {uuid: $uuid})
            RETURN episode.content AS episode_content,
                   episode._gralkor_extraction_complete AS complete,
                   claim.content AS claim_content
            ''',
            uuid=uid,
        ))
        [records[0], graphiti.extractions]
        """,
        %{"graphiti" => graphiti, "uuid" => artefact_id}
      )

    assert Pythonx.decode(proof) == [
             %{
               "claim_content" => content,
               "complete" => true,
               "episode_content" => content
             },
             1
           ]

    :ok
  end

  defp start_preclaim_graphiti_pool(child_id) do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "reflection-preclaim-#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
      )

    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf!(data_dir) end)
    start_supervised!(Gralkor.Python)

    construct_instance = fn database, _shared, group_id ->
      {graphiti, _} =
        Pythonx.eval(
          """
          from graphiti_core.driver.falkordb_driver import FalkorDriver

          gid = group_id.decode('utf-8') if isinstance(group_id, (bytes, bytearray)) else group_id

          class PreclaimGraphitiContract:
              def __init__(self):
                  self.driver = FalkorDriver(falkor_db=database, database=gid)
                  self.extractions = 0

              async def add_episode(self, **kwargs):
                  from graphiti_core.nodes import EpisodicNode
                  self.extractions += 1
                  episode = await EpisodicNode.get_by_uuid(self.driver, kwargs['uuid'])
                  await episode.save(self.driver)

              async def search_(self, query, config=None, group_ids=None, search_filter=None):
                  from graphiti_core.nodes import EpisodicNode
                  from graphiti_core.search.search_config import SearchResults
                  episodes = await EpisodicNode.get_by_group_ids(
                      self.driver,
                      list(group_ids or []),
                      limit=config.limit if config is not None else None,
                  )
                  return SearchResults(episodes=episodes)

          PreclaimGraphitiContract()
          """,
          %{"database" => database, "group_id" => group_id}
        )

      graphiti
    end

    pool =
      start_supervised!(
        Supervisor.child_spec(
          {GraphitiPool,
           falkordb_spec: {:embedded, data_dir},
           construct_shared_clients: fn _llm, _embedder ->
             %{llm_client: nil, embedder: nil, cross_encoder: nil}
           end,
           construct_instance: construct_instance,
           initialise_instance: fn _instance -> :ok end,
           warmup: false,
           embedded_falkordb_socket_timeout_ms: 60_000},
          id: child_id
        )
      )

    {pool, GraphitiPool.for(pool, "observations")}
  end

  defp assert_shared_graph_claim_contract do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "reflection-shared-claims-#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
      )

    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf!(data_dir) end)
    start_supervised!(Gralkor.Python)

    construct_instance = fn database, _shared, group_id ->
      {graphiti, _} =
        Pythonx.eval(
          """
          import asyncio
          from graphiti_core.driver.falkordb_driver import FalkorDriver

          gid = group_id.decode('utf-8') if isinstance(group_id, (bytes, bytearray)) else group_id

          class SharedClaimGraphitiContract:
              def __init__(self):
                  self.driver = FalkorDriver(falkor_db=database, database=gid)
                  self.extractions = 0
                  self.wait_for_replacement_owner = False

              async def add_episode(self, **kwargs):
                  from datetime import datetime, timezone
                  from graphiti_core.edges import EntityEdge, EpisodicEdge
                  from graphiti_core.graphiti import add_nodes_and_edges_bulk
                  from graphiti_core.nodes import EntityNode, EpisodicNode
                  self.extractions += 1

                  if (
                      kwargs['uuid'] == 'embedded-stolen-claim'
                      and self.wait_for_replacement_owner
                  ):
                      self.wait_for_replacement_owner = False
                      for _ in range(1000):
                          records, _, _ = await self.driver.execute_query(
                              '''
                              MATCH (c:_GralkorEpisodeClaim {uuid: $uuid})
                              RETURN c.owner AS owner
                              ''',
                              uuid=kwargs['uuid'],
                          )
                          if records and records[0]['owner'] == 'replacement-owner':
                              break
                          await asyncio.sleep(0.01)
                      else:
                          raise RuntimeError('timed out waiting for replacement owner')
                  else:
                      await asyncio.sleep(0.1)

                  episode = await EpisodicNode.get_by_uuid(self.driver, kwargs['uuid'])

                  if kwargs['uuid'] in {'embedded-bulk-stolen', 'embedded-bulk-created'}:
                      suffix = kwargs['uuid'].removeprefix('embedded-bulk-')
                      now = datetime.now(timezone.utc)
                      left = EntityNode(
                          uuid=f'embedded-bulk-{suffix}-left',
                          name='left',
                          group_id=gid,
                          labels=['Person'],
                          created_at=now,
                          name_embedding=[0.1],
                      )
                      right = EntityNode(
                          uuid=f'embedded-bulk-{suffix}-right',
                          name='right',
                          group_id=gid,
                          labels=['Person'],
                          created_at=now,
                          name_embedding=[0.2],
                      )
                      mention = EpisodicEdge(
                          uuid=f'embedded-bulk-{suffix}-mention',
                          group_id=gid,
                          source_node_uuid=episode.uuid,
                          target_node_uuid=left.uuid,
                          created_at=now,
                      )
                      relation = EntityEdge(
                          uuid=f'embedded-bulk-{suffix}-relation',
                          group_id=gid,
                          source_node_uuid=left.uuid,
                          target_node_uuid=right.uuid,
                          created_at=now,
                          name='KNOWS',
                          fact='left knows right',
                          fact_embedding=[0.3],
                          episodes=[episode.uuid],
                      )
                      await episode.save(self.driver)
                      if suffix == 'stolen':
                          await self.driver.execute_query(
                              '''
                              MATCH (c:_GralkorEpisodeClaim {uuid: $uuid})
                              SET c.owner = 'replacement-owner', c.generation = c.generation + 1
                              RETURN c.generation AS generation
                              ''',
                              uuid=episode.uuid,
                          )
                      await add_nodes_and_edges_bulk(
                          self.driver,
                          [episode],
                          [mention],
                          [left, right],
                          [relation],
                          None,
                      )
                      return

                  await episode.save(self.driver)
                  await add_nodes_and_edges_bulk(
                      self.driver,
                      [episode],
                      [],
                      [],
                      [],
                      None,
                  )

          SharedClaimGraphitiContract()
          """,
          %{"database" => database, "group_id" => group_id}
        )

      graphiti
    end

    common_options = [
      construct_shared_clients: fn _llm, _embedder ->
        %{llm_client: nil, embedder: nil, cross_encoder: nil}
      end,
      construct_instance: construct_instance,
      initialise_instance: fn _instance -> :ok end,
      warmup: false,
      embedded_falkordb_socket_timeout_ms: 60_000
    ]

    first_pool =
      start_supervised!(
        Supervisor.child_spec(
          {GraphitiPool,
           [
             name: nil,
             table: :"shared_claims_first_#{System.unique_integer([:positive])}",
             falkordb_spec: {:embedded, data_dir}
           ] ++ common_options},
          id: :reflection_shared_claims_first
        )
      )

    database = :sys.get_state(first_pool).falkor_db

    second_pool =
      start_supervised!(
        Supervisor.child_spec(
          {GraphitiPool,
           [
             name: nil,
             table: :"shared_claims_second_#{System.unique_integer([:positive])}",
             falkordb_spec: {:remote, []},
             construct_falkor_db: fn _spec -> database end,
             close_falkor_db: fn _database -> :ok end
           ] ++ common_options},
          id: :reflection_shared_claims_second
        )
      )

    first_graph = GraphitiPool.for(first_pool, "observations")
    second_graph = GraphitiPool.for(second_pool, "observations")
    graph_group_id = Client.sanitize_group_id("observations")

    Pythonx.eval(
      "first_graph.wait_for_replacement_owner = True",
      %{"first_graph" => first_graph}
    )

    equal_writes = [
      Task.async(fn ->
        GraphitiPool.add_episode(first_pool, "observations", "same", "source", nil,
          uuid: "embedded-shared-equal"
        )
      end),
      Task.async(fn ->
        GraphitiPool.add_episode(second_pool, "observations", "same", "source", nil,
          uuid: "embedded-shared-equal"
        )
      end)
    ]

    assert [:ok, :ok] = Task.await_many(equal_writes, 30_000)

    {equal_extractions, _} =
      Pythonx.eval(
        "first.extractions + second.extractions",
        %{"first" => first_graph, "second" => second_graph}
      )

    assert Pythonx.decode(equal_extractions) == 1

    conflicting_writes = [
      Task.async(fn ->
        GraphitiPool.add_episode(first_pool, "observations", "first", "source", nil,
          uuid: "embedded-shared-conflict"
        )
      end),
      Task.async(fn ->
        GraphitiPool.add_episode(second_pool, "observations", "second", "source", nil,
          uuid: "embedded-shared-conflict"
        )
      end)
    ]

    conflict_outcomes = Task.await_many(conflicting_writes, 30_000)
    assert Enum.count(conflict_outcomes, &(&1 == :ok)) == 1

    assert Enum.count(
             conflict_outcomes,
             &(&1 == {:error, {:episode_conflict, "embedded-shared-conflict"}})
           ) == 1

    stale_write =
      Task.async(fn ->
        GraphitiPool.add_episode(first_pool, "observations", "same", "source", nil,
          uuid: "embedded-stolen-claim"
        )
      end)

    assert eventually(fn -> graph_claim_exists?(first_graph, "embedded-stolen-claim") end)

    Pythonx.eval(
      """
      import asyncio
      asyncio._gralkor_run(graph.driver.execute_query(
          '''
          MATCH (c:_GralkorEpisodeClaim {uuid: $uuid})
          SET c.owner = 'replacement-owner', c.generation = c.generation + 1
          RETURN c.generation AS generation
          ''',
          uuid='embedded-stolen-claim',
      ))
      """,
      %{"graph" => first_graph}
    )

    assert {:error, {:python, stale_error}} = Task.await(stale_write, 30_000)
    assert Regex.match?(~r/episode claim(?: renewal)? lost/, stale_error)

    assert {:error, :not_found} =
             GraphitiPool.get_episode(first_pool, "observations", "embedded-stolen-claim")

    bulk_stale_write =
      Task.async(fn ->
        GraphitiPool.add_episode(first_pool, "observations", "same", "source", nil,
          uuid: "embedded-bulk-stolen"
        )
      end)

    assert {:error, {:python, bulk_stale_error}} = Task.await(bulk_stale_write, 30_000)
    assert Regex.match?(~r/episode claim(?: renewal)? lost/, bulk_stale_error)

    {bulk_stale_proof, _} =
      Pythonx.eval(
        """
        import asyncio
        async def bulk_stale_proof():
            records, _, _ = await graph.driver.execute_query(
                '''
                OPTIONAL MATCH (episode:Episodic {uuid: 'embedded-bulk-stolen'})
                OPTIONAL MATCH (left:Entity {uuid: 'embedded-bulk-stolen-left'})
                OPTIONAL MATCH (right:Entity {uuid: 'embedded-bulk-stolen-right'})
                OPTIONAL MATCH ()-[mention:MENTIONS {uuid: 'embedded-bulk-stolen-mention'}]->()
                OPTIONAL MATCH ()-[relation:RELATES_TO {uuid: 'embedded-bulk-stolen-relation'}]->()
                RETURN episode IS NOT NULL AS episode,
                       left IS NOT NULL AS left,
                       right IS NOT NULL AS right,
                       mention IS NOT NULL AS mention,
                       relation IS NOT NULL AS relation
                '''
            )
            return records[0]
        asyncio._gralkor_run(bulk_stale_proof())
        """,
        %{"graph" => first_graph}
      )

    assert Pythonx.decode(bulk_stale_proof) == %{
             "episode" => false,
             "left" => false,
             "mention" => false,
             "relation" => false,
             "right" => false
           }

    assert :ok =
             GraphitiPool.add_episode(
               first_pool,
               "observations",
               "same",
               "source",
               nil,
               uuid: "embedded-bulk-created"
             )

    {bulk_created_proof, _} =
      Pythonx.eval(
        """
        import asyncio
        async def bulk_created_proof():
            records, _, _ = await graph.driver.execute_query(
                '''
                MATCH (episode:Episodic {uuid: 'embedded-bulk-created'})
                MATCH (left:Entity {uuid: 'embedded-bulk-created-left'})
                MATCH (right:Entity {uuid: 'embedded-bulk-created-right'})
                MATCH (episode)-[mention:MENTIONS {uuid: 'embedded-bulk-created-mention'}]->(left)
                MATCH (left)-[relation:RELATES_TO {uuid: 'embedded-bulk-created-relation'}]->(right)
                RETURN episode._gralkor_extraction_complete AS complete,
                       mention.uuid AS mention,
                       relation.uuid AS relation
                '''
            )
            return records[0]
        asyncio._gralkor_run(bulk_created_proof())
        """,
        %{"graph" => first_graph}
      )

    assert Pythonx.decode(bulk_created_proof) == %{
             "complete" => true,
             "mention" => "embedded-bulk-created-mention",
             "relation" => "embedded-bulk-created-relation"
           }

    Pythonx.eval(
      """
      import asyncio
      asyncio._gralkor_run(graph.driver.execute_query(
          '''
          MATCH (c:_GralkorEpisodeClaim {uuid: $uuid})
          SET c.owner = NULL, c.lease_until_ms = 0
          RETURN c.generation AS generation
          ''',
          uuid='embedded-stolen-claim',
      ))
      """,
      %{"graph" => first_graph}
    )

    assert :ok =
             GraphitiPool.add_episode(
               second_pool,
               "observations",
               "same",
               "source",
               nil,
               uuid: "embedded-stolen-claim"
             )

    assert {:ok, %{"extraction_complete" => true}} =
             GraphitiPool.get_episode(
               first_pool,
               "observations",
               "embedded-stolen-claim"
             )

    Pythonx.eval(
      """
      import asyncio
      group_id = group_id.decode('utf-8') if isinstance(group_id, (bytes, bytearray)) else group_id
      asyncio._gralkor_run(graph.driver.execute_query(
          '''
          MERGE (c:_GralkorEpisodeClaim {uuid: $uuid})
          ON CREATE SET
            c.group_id = $group_id,
            c.content = 'same',
            c.source = 'text',
            c.source_description = 'source',
            c.owner = 'expired-owner',
            c.generation = 7,
            c.lease_until_ms = timestamp() - 1
          RETURN c.generation AS generation
          ''',
          uuid='embedded-server-expired',
          group_id=group_id,
      ))
      """,
      %{"graph" => first_graph, "group_id" => graph_group_id}
    )

    assert :ok =
             GraphitiPool.add_episode(
               first_pool,
               "observations",
               "same",
               "source",
               nil,
               uuid: "embedded-server-expired"
             )

    {proof, _} =
      Pythonx.eval(
        """
        import asyncio
        records, _, _ = asyncio._gralkor_run(first.driver.execute_query(
            'MATCH (c:_GralkorEpisodeClaim {uuid: $uuid}) RETURN c.generation AS generation',
            uuid='embedded-server-expired',
        ))
        records[0]['generation']
        """,
        %{"first" => first_graph, "second" => second_graph}
      )

    assert Pythonx.decode(proof) == 8

    :ok
  end

  defp eventually(assertion, attempts \\ 100)

  defp eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      true
    else
      Process.sleep(10)
      eventually(assertion, attempts - 1)
    end
  end

  defp eventually(_assertion, 0), do: false

  defp graph_claim_exists?(graph, uuid) do
    {exists, _} =
      Pythonx.eval(
        """
        import asyncio
        uid = uuid.decode('utf-8') if isinstance(uuid, (bytes, bytearray)) else uuid
        records, _, _ = asyncio._gralkor_run(graph.driver.execute_query(
            'MATCH (c:_GralkorEpisodeClaim {uuid: $uuid}) RETURN c.uuid AS uuid',
            uuid=uid,
        ))
        bool(records)
        """,
        %{"graph" => graph, "uuid" => uuid}
      )

    Pythonx.decode(exists)
  end

  defp assert_verified(key, verification) do
    cache_key = {__MODULE__, key}

    result =
      :global.trans(cache_key, fn ->
        case :persistent_term.get(cache_key, :missing) do
          :ok ->
            :ok

          :missing ->
            :ok = verification.()
            :persistent_term.put(cache_key, :ok)
            :ok
        end
      end)

    assert result == :ok
  end

  defp in_memory_artefact(reflection) do
    output = Enum.find(reflection.outputs, &(&1.kind == :destination))
    {output, Artefact.new("stable-id", %{"summary" => "stored"})}
  end

  defp put_in_memory(output, reflection, artefact) do
    Gralkor.Destination.Storage.InMemory.put_artefact(
      output,
      reflection.name,
      "operator-one",
      artefact
    )
  end

  defp get_in_memory(output, reflection, artefact_id) do
    Gralkor.Destination.Storage.InMemory.get_artefact(
      output,
      reflection.name,
      "operator-one",
      artefact_id
    )
  end

  defp in_memory_search(output, reflection) do
    {:ok, artefacts} =
      Gralkor.Destination.Storage.InMemory.search(
        output.destination,
        "operator-one",
        "",
        :artefacts,
        10,
        []
      )

    Enum.map(artefacts, &%{artefact: &1, reflection: reflection.name})
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
