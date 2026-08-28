defmodule Gralkor.ReflectionCompletionFunctionalTest do
  use ExUnit.Case, async: false

  alias Gralkor.Client
  alias Gralkor.GraphitiPool
  alias Gralkor.Ingest
  alias Gralkor.Reflection
  alias Gralkor.Reflection.ChainOfThought
  alias Gralkor.Reflection.Scheduler
  alias Gralkor.Search

  @moduletag :functional

  defmodule StoredDocument do
    @behaviour Gralkor.Lens.Ingestion

    @impl true
    def ingest(request, store) do
      Gralkor.Lens.Store.add(store, request.content, request.source_description)
    end
  end

  defmodule FailOnceStore do
    @behaviour Gralkor.Reflection.Store

    use Agent

    def start_link(test_pid), do: Agent.start_link(fn -> {test_pid, 0} end, name: __MODULE__)

    @impl true
    def get(_reflection, _operator_id, _artefact_id), do: {:error, :not_found}

    @impl true
    def put(_reflection, _operator_id, artefact) do
      Agent.get_and_update(__MODULE__, fn {test_pid, attempts} ->
        send(test_pid, {:store_attempt, artefact})

        if attempts == 0 do
          {{:error, :temporary_store_failure}, {test_pid, 1}}
        else
          {:ok, {test_pid, attempts + 1}}
        end
      end)
    end
  end

  setup do
    previous =
      for key <- [
            :destinations,
            :destination_storage,
            :lenses,
            :lens_storage,
            :reflections,
            :reflection_storage
          ],
          into: %{} do
        {key, Application.get_env(:jido_gralkor, key)}
      end

    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)

    start_supervised!(Gralkor.Lens.Storage.InMemory)
    start_supervised!(Gralkor.Reflection.Storage.InMemory)

    Application.put_env(:jido_gralkor, :destinations, [[name: "observations"]])

    Application.put_env(:jido_gralkor, :lenses, [
      [name: "observations", destination: "observations", ingestion: StoredDocument]
    ])

    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

    Application.put_env(
      :jido_gralkor,
      :destination_storage,
      Gralkor.Destination.Storage.InMemory
    )

    Application.put_env(:jido_gralkor, :reflection_storage, Gralkor.Reflection.Storage.InMemory)

    reflection = %Reflection{
      name: "review",
      destination: %Gralkor.Destination{name: "observations"},
      ontology: Gralkor.DefaultOntology,
      chain_of_thought: %ChainOfThought{
        path: "reflection-completion.yaml",
        steps: [
          %ChainOfThought.Step{
            label: "review",
            directions: "Review the ingested information.",
            output: %{"summary" => "string"}
          }
        ]
      }
    }

    Application.put_env(:jido_gralkor, :reflections, [reflection])

    test_pid = self()
    journal_path =
      Path.join(System.tmp_dir!(), "reflection-scheduler-#{System.unique_integer([:positive])}.dets")

    on_exit(fn -> File.rm(journal_path) end)

    start_supervised!(
      {Scheduler,
       runner: fn reflected, ingestion, opts ->
         send(
           test_pid,
           {:runner_started, reflected.name, ingestion.id, opts[:artefact_id], self()}
         )

         receive do
           :finish_reflection ->
             Gralkor.Reflection.Runner.run(
               reflected,
               ingestion,
               Keyword.put(opts, :inference, fn _ ->
                 {:ok, %{output: %{"summary" => "stored"}}}
               end)
             )

           {:finish_reflection, outcome} ->
             outcome
         end
       end,
       notify: test_pid,
       retry_delays: [0],
       journal_path: journal_path}
    )

    {:ok, reflection: reflection}
  end

  describe "when an application ingests information under a stable ingestion identifier while Reflections are declared" do
    test "then ingestion returns without waiting for Reflection completion" do
      started = System.monotonic_time(:millisecond)

      assert :ok =
               Client.ingest(ingestion())

      assert System.monotonic_time(:millisecond) - started < 100
      assert_receive {:runner_started, "review", "ingestion-one", _artefact_id, _runner}
    end

    test "then replay after a Scheduler restart confirms one stable searchable artefact without rerunning" do
      assert :ok = Client.ingest(ingestion())
      assert_receive {:runner_started, "review", "ingestion-one", _artefact_id, first_runner}
      send(first_runner, :finish_reflection)
      assert_receive {:reflection_completed, "review", {:ok, first_artefact}}

      first_scheduler = Process.whereis(Scheduler)
      GenServer.stop(first_scheduler)
      assert eventually(fn -> Process.whereis(Scheduler) not in [nil, first_scheduler] end)

      assert :ok = Client.ingest(ingestion())
      assert_receive {:reflection_completed, "review", {:ok, second_artefact}}
      refute_receive {:runner_started, "review", "ingestion-one", _artefact_id, _runner}

      assert second_artefact.id == first_artefact.id

      assert {:ok, [%{destination: "observations", artefact: searchable}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "stored",
                 destinations: ["observations"],
                 result_type: :artefacts
               })

      assert searchable.id == first_artefact.id
    end

    test "then a Scheduler crash resumes unfinished Runner work from durable state" do
      assert :ok = Client.ingest(ingestion())

      assert_receive {:runner_started, "review", "ingestion-one", artefact_id, first_runner}

      first_scheduler = Process.whereis(Scheduler)
      Process.exit(first_scheduler, :kill)
      assert eventually(fn -> Process.whereis(Scheduler) not in [nil, first_scheduler] end)
      refute Process.alive?(first_runner)

      assert_receive {:runner_started, "review", "ingestion-one", ^artefact_id, resumed_runner},
                     500

      send(resumed_runner, :finish_reflection)
      assert_receive {:reflection_completed, "review", {:ok, %{id: ^artefact_id}}}
    end

    test "then one failed Reflection retries without rerunning its completed sibling", %{
      reflection: reflection
    } do
      summary = %{reflection | name: "summary"}
      Application.put_env(:jido_gralkor, :reflections, [reflection, summary])

      assert :ok = Client.ingest(ingestion())

      runners = receive_runners(2, %{})
      send(Map.fetch!(runners, "review"), :finish_reflection)
      send(Map.fetch!(runners, "summary"), {:finish_reflection, {:error, :temporary}})

      assert_receive {:reflection_completed, "review", {:ok, _artefact}}
      assert_receive {:reflection_retrying, "summary", %{stage: :runner, reason: :temporary}}
      assert_receive {:runner_started, "summary", "ingestion-one", _artefact_id, retry_runner},
                     500

      refute_receive {:runner_started, "review", "ingestion-one", _artefact_id, _runner}, 50

      send(retry_runner, :finish_reflection)
      assert_receive {:reflection_completed, "summary", {:ok, _artefact}}
    end

    test "then canonical storage failure retries the exact artefact without rerunning the Runner" do
      start_supervised!({FailOnceStore, self()})
      Application.put_env(:jido_gralkor, :reflection_storage, FailOnceStore)

      assert :ok = Client.ingest(ingestion())
      assert_receive {:runner_started, "review", "ingestion-one", _artefact_id, runner}
      send(runner, :finish_reflection)

      assert_receive {:store_attempt, first_artefact}

      assert_receive {:reflection_retrying, "review",
                      %{stage: :storage, reason: :temporary_store_failure}}

      assert_receive {:store_attempt, second_artefact}
      assert second_artefact == first_artefact
      refute_receive {:runner_started, "review", "ingestion-one", _artefact_id, _runner}
      assert_receive {:reflection_completed, "review", {:ok, ^first_artefact}}
    end
  end

  describe "where Graphiti is the canonical Reflection store" do
    test "then a fresh requested UUID is created once and equal retry confirms it without extraction" do
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

          class PinnedGraphitiContract:
              def __init__(self):
                  self.driver = Driver()
                  self.extractions = 0

              async def add_episode(self, **kwargs):
                  from graphiti_core.nodes import EpisodicNode
                  self.extractions += 1
                  episode = await EpisodicNode.get_by_uuid(self.driver, kwargs['uuid'])
                  await episode.save(self.driver)

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
    end
  end

  defp ingestion do
    %Ingest{
      id: "ingestion-one",
      operator_id: "operator-one",
      lens: "observations",
      source_kind: :document,
      content: "The deployment succeeded.",
      source_description: "deployment",
      evidence_id: "evidence-one"
    }
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

  defp receive_runners(0, runners), do: runners

  defp receive_runners(remaining, runners) do
    assert_receive {:runner_started, name, "ingestion-one", _artefact_id, runner}
    receive_runners(remaining - 1, Map.put(runners, name, runner))
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
