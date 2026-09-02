defmodule Gralkor.ReflectionCompletionFunctionalTest do
  use ExUnit.Case, async: false

  alias Gralkor.Client
  alias Gralkor.CaptureBuffer
  alias Gralkor.GraphitiPool
  alias Gralkor.Ingest
  alias Gralkor.Reflection
  alias Gralkor.Artefact
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
    use Agent

    def start_link(test_pid), do: Agent.start_link(fn -> {test_pid, 0} end, name: __MODULE__)

    def get_artefact(_output, _reflection_name, _operator_id, _artefact_id),
      do: {:error, :not_found}

    def put_artefact(_output, _reflection_name, _operator_id, artefact) do
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

  defmodule ControlledCompletionStore do
    use Agent

    def start_link({test_pid, outcomes}) do
      Agent.start_link(fn -> {test_pid, outcomes} end, name: __MODULE__)
    end

    def get_artefact(_output, _reflection_name, _operator_id, _artefact_id),
      do: {:error, :not_found}

    def put_artefact(_output, _reflection_name, _operator_id, artefact) do
      {test_pid, outcome} =
        Agent.get_and_update(__MODULE__, fn {test_pid, [outcome | remaining]} ->
          {{test_pid, outcome}, {test_pid, remaining}}
        end)

      send(test_pid, {:controlled_store_attempt, artefact, self()})

      case outcome do
        :ok ->
          :ok

        :crash ->
          raise "Destination storage crashed"

        :hang ->
          receive do
            :release -> :ok
          end
      end
    end
  end

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

  defmodule FailOnceReturnHandler do
    @behaviour Gralkor.Artefact.ReturnHandler

    use Agent

    def start_link(test_pid), do: Agent.start_link(fn -> {test_pid, 0} end, name: __MODULE__)

    @impl true
    def return(operator_id, invocation_id, artefact) do
      Agent.get_and_update(__MODULE__, fn {test_pid, attempts} ->
        send(test_pid, {:return_attempt, operator_id, invocation_id, artefact})

        outcome = if attempts == 0, do: {:error, :response_lost}, else: :ok
        {outcome, {test_pid, attempts + 1}}
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
    start_supervised!(Gralkor.Destination.Storage.InMemory)

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

    reflection = %Reflection{
      name: "review",
      triggers: [{:lens_ingestion, :any}],
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
            directions: "Review the ingested information.",
            output: %{"summary" => "string"}
          }
        ]
      }
    }

    Application.put_env(:jido_gralkor, :reflections, [reflection])

    test_pid = self()

    journal_path =
      Path.join(
        System.tmp_dir!(),
        "reflection-scheduler-#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}.dets"
      )

    on_exit(fn -> File.rm(journal_path) end)

    inference = fn request ->
      artefact_id = Artefact.id_for(request.operator_id, "ingestion-one", request.reflection)

      send(
        test_pid,
        {:runner_started, request.reflection, "ingestion-one", artefact_id, self()}
      )

      receive do
        :finish_reflection -> {:ok, %{output: %{"summary" => "stored"}}}
        {:finish_reflection, outcome} -> outcome
        :crash -> raise "runner crashed"
      end
    end

    start_supervised!(
      {Scheduler,
       runner_opts: [inference: inference],
       notify: test_pid,
       retry_delays: [0],
       execution_timeout_ms: 1_000,
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
  end

  describe "if public ingestion omits or supplies a blank operator or stable ingestion identifier" do
    test "then a blank ingestion identifier raises before Lens or Reflection side effects" do
      assert_raise ArgumentError, ~r/id must be a non-blank string/, fn ->
        Client.ingest(%{ingestion() | id: " "})
      end

      refute_receive {:runner_started, _reflection, _ingestion, _artefact_id, _runner}

      assert {:ok, []} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "",
                 destinations: ["observations"],
                 result_type: :episodes
               })
    end

    test "then a missing ingestion identifier raises before Lens or Reflection side effects" do
      assert_raise ArgumentError, ~r/id must be a non-blank string/, fn ->
        Client.ingest(%{ingestion() | id: nil})
      end

      refute_receive {:runner_started, _reflection, _ingestion, _artefact_id, _runner}
    end

    test "then a blank operator identifier raises before Lens or Reflection side effects" do
      assert_raise ArgumentError, ~r/operator_id must be a non-blank string/, fn ->
        Client.ingest(%{ingestion() | operator_id: " "})
      end

      refute_receive {:runner_started, _reflection, _ingestion, _artefact_id, _runner}

      assert {:ok, []} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "",
                 destinations: ["observations"],
                 result_type: :episodes
               })
    end

    test "then a missing operator identifier raises before Lens or Reflection side effects" do
      assert_raise ArgumentError, ~r/operator_id must be a non-blank string/, fn ->
        Client.ingest(%{ingestion() | operator_id: nil})
      end

      refute_receive {:runner_started, _reflection, _ingestion, _artefact_id, _runner}
    end
  end

  describe "when an ingestion is replayed after one or more of its Reflections completed" do
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

    test "then a newly declared Reflection runs without rerunning a completed sibling", %{
      reflection: reflection
    } do
      assert :ok = Client.ingest(ingestion())
      assert_receive {:runner_started, "review", "ingestion-one", _artefact_id, runner}
      send(runner, :finish_reflection)
      assert_receive {:reflection_completed, "review", {:ok, _artefact}}

      summary = %{reflection | name: "summary"}
      Application.put_env(:jido_gralkor, :reflections, [reflection, summary])
      assert :ok = Client.ingest(ingestion())

      assert_receive {:reflection_completed, "review", {:ok, _artefact}}
      assert_receive {:runner_started, "summary", "ingestion-one", _artefact_id, summary_runner}
      refute_receive {:runner_started, "review", "ingestion-one", _artefact_id, _runner}

      send(summary_runner, :finish_reflection)
      assert_receive {:reflection_completed, "summary", {:ok, _artefact}}
    end
  end

  describe "when the supervised Reflection Scheduler crashes with unfinished work" do
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
  end

  describe "when one ingestion schedules several Reflections" do
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

      assert_receive {:reflection_retrying, "summary",
                      %{stage: :runner, reason: %{reason: :temporary}}}

      assert_receive {:runner_started, "summary", "ingestion-one", _artefact_id, retry_runner},
                     500

      refute_receive {:runner_started, "review", "ingestion-one", _artefact_id, _runner}, 50

      send(retry_runner, :finish_reflection)
      assert_receive {:reflection_completed, "summary", {:ok, _artefact}}
    end
  end

  describe "when a Reflection Runner produces an artefact" do
    test "then a lost return response retries only that output with the exact artefact", %{
      reflection: reflection
    } do
      start_supervised!({FailOnceReturnHandler, self()})

      reflection = %{
        reflection
        | outputs: reflection.outputs ++ [%{kind: :return, handler: FailOnceReturnHandler}]
      }

      Application.put_env(:jido_gralkor, :reflections, [reflection])

      assert :ok = Client.ingest(ingestion())
      assert_receive {:runner_started, "review", "ingestion-one", _artefact_id, runner}
      send(runner, :finish_reflection)

      assert_receive {:return_attempt, "operator-one", "ingestion-one", first_artefact}

      assert_receive {:reflection_retrying, "review",
                      %{stage: :return, output: :return, reason: :response_lost}}

      assert_receive {:return_attempt, "operator-one", "ingestion-one", second_artefact}
      assert second_artefact == first_artefact
      refute_receive {:runner_started, "review", "ingestion-one", _artefact_id, _runner}
      assert_receive {:reflection_completed, "review", {:ok, ^first_artefact}}

      assert {:ok, [%{artefact: ^first_artefact}]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "stored",
                 destinations: ["observations"],
                 result_type: :artefacts
               })
    end

    test "then Destination output failure retries the exact artefact without rerunning the Runner" do
      start_supervised!({FailOnceStore, self()})
      Application.put_env(:jido_gralkor, :destination_storage, FailOnceStore)

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

    test "then a Destination output task crash retries the exact artefact without rerunning the Runner" do
      start_supervised!({ControlledCompletionStore, {self(), [:crash, :ok]}})
      Application.put_env(:jido_gralkor, :destination_storage, ControlledCompletionStore)

      assert :ok = Client.ingest(ingestion())
      assert_receive {:runner_started, "review", "ingestion-one", _artefact_id, runner}
      send(runner, :finish_reflection)

      assert_receive {:controlled_store_attempt, first_artefact, _first_store_task}

      assert_receive {:reflection_retrying, "review",
                      %{stage: :storage, reason: {:task_exit, _reason}}}

      assert_receive {:controlled_store_attempt, second_artefact, _second_store_task}
      assert second_artefact == first_artefact
      refute_receive {:runner_started, "review", "ingestion-one", _artefact_id, _runner}
      assert_receive {:reflection_completed, "review", {:ok, ^first_artefact}}
    end

    test "then storage timeout exhaustion is observable after each expired attempt exits", %{
      reflection: reflection
    } do
      start_supervised!({ControlledCompletionStore, {self(), [:hang, :hang]}})
      Application.put_env(:jido_gralkor, :destination_storage, ControlledCompletionStore)

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection], scheduler_ingestion(), execution_timeout_ms: 25)

      assert_receive {:runner_started, "review", "ingestion-one", artefact_id, runner}
      send(runner, :finish_reflection)

      assert_receive {:controlled_store_attempt, first_artefact, first_store_task}
      first_monitor = Process.monitor(first_store_task)
      assert_receive {:DOWN, ^first_monitor, :process, ^first_store_task, :killed}
      assert_receive {:reflection_retrying, "review", %{stage: :storage, reason: :timeout}}

      assert_receive {:controlled_store_attempt, ^first_artefact, second_store_task}
      second_monitor = Process.monitor(second_store_task)
      assert_receive {:DOWN, ^second_monitor, :process, ^second_store_task, :killed}

      assert_receive {:reflection_completed, "review",
                      {:error,
                       %{
                         stage: :storage,
                         attempts: 2,
                         reason: :timeout
                       }}}

      refute_receive {:runner_started, "review", "ingestion-one", ^artefact_id, _runner}
    end
  end

  describe "when overlapping requests schedule the same operator, ingestion, and Reflection" do
    test "then overlapping scheduling admits at most one active Runner" do
      requests = for _ <- 1..2, do: Task.async(fn -> Client.ingest(ingestion()) end)
      assert Task.await_many(requests) == [:ok, :ok]

      assert_receive {:runner_started, "review", "ingestion-one", _artefact_id, runner}
      refute_receive {:runner_started, "review", "ingestion-one", _artefact_id, _runner}

      send(runner, :finish_reflection)
      assert_receive {:reflection_completed, "review", {:ok, _artefact}}

      assert {:ok, [_one_artefact]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "",
                 destinations: ["observations"],
                 result_type: :artefacts
               })
    end
  end

  describe "when a Reflection Runner returns an error or crashes" do
    test "then a Runner task crash is retried and can complete" do
      assert :ok = Client.ingest(ingestion())
      assert_receive {:runner_started, "review", "ingestion-one", artefact_id, runner}
      send(runner, :crash)

      assert_receive {:reflection_retrying, "review",
                      %{stage: :runner, reason: {:task_exit, _reason}}}

      assert_receive {:runner_started, "review", "ingestion-one", ^artefact_id, retry_runner}
      send(retry_runner, :finish_reflection)
      assert_receive {:reflection_completed, "review", {:ok, %{id: ^artefact_id}}}
    end

    test "then a host-tool side effect before interruption is invoked again on Runner retry", %{
      reflection: reflection
    } do
      side_effects = :atomics.new(1, [])
      test_pid = self()

      inference = fn request ->
        if request.tool_results == [] do
          {:ok, %{tool_calls: [%{name: "record-side-effect", arguments: %{}}]}}
        else
          if :atomics.get(side_effects, 1) == 1 do
            raise "response lost after host-tool side effect"
          else
            {:ok, %{output: %{"summary" => "stored"}}}
          end
        end
      end

      tool_executor = fn call, _context ->
        count = :atomics.add_get(side_effects, 1, 1)
        send(test_pid, {:host_tool_side_effect, count, call})
        :recorded
      end

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection], scheduler_ingestion(),
                 runner_opts: [inference: inference, tool_executor: tool_executor]
               )

      assert_receive {:host_tool_side_effect, 1, %{name: "record-side-effect"}}
      assert_receive {:reflection_retrying, "review", %{stage: :runner}}
      assert_receive {:host_tool_side_effect, 2, %{name: "record-side-effect"}}
      assert_receive {:reflection_completed, "review", {:ok, _artefact}}
      assert :atomics.get(side_effects, 1) == 2
    end
  end

  describe "when a Runner task cannot start" do
    test "then the task-start failure follows the bounded Runner retry schedule", %{
      reflection: reflection
    } do
      starts = :atomics.new(1, [])

      start_task = fn supervisor, operation ->
        if :atomics.add_get(starts, 1, 1) == 2 do
          {:error, :task_supervisor_busy}
        else
          Task.Supervisor.async_nolink(supervisor, operation)
        end
      end

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection], scheduler_ingestion(), start_task: start_task)

      assert_receive {:reflection_retrying, "review",
                      %{stage: :runner, reason: {:task_start, :task_supervisor_busy}}}

      assert_receive {:runner_started, "review", "ingestion-one", _artefact_id, runner}
      send(runner, :finish_reflection)
      assert_receive {:reflection_completed, "review", {:ok, _artefact}}
    end
  end

  describe "when a Reflection Runner does not finish within its execution timeout" do
    test "then Runner timeout exhaustion is observable and releases its logical work", %{
      reflection: reflection
    } do
      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection], scheduler_ingestion(), execution_timeout_ms: 50)

      assert_receive {:runner_started, "review", "ingestion-one", artefact_id, first_runner},
                     1_000

      first_monitor = Process.monitor(first_runner)

      assert_receive {:DOWN, ^first_monitor, :process, ^first_runner, :killed}, 1_000

      assert_receive {:reflection_retrying, "review", %{stage: :runner, reason: :timeout}},
                     1_000

      assert_receive {:runner_started, "review", "ingestion-one", ^artefact_id, second_runner},
                     1_000

      assert_receive {:reflection_completed, "review",
                      {:error,
                       %{
                         reflection: "review",
                         stage: :runner,
                         attempts: 2,
                         reason: :timeout
                       }}},
                     1_000

      refute Process.alive?(second_runner)

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection], scheduler_ingestion(),
                 execution_timeout_ms: 1_000
               )

      assert_receive {:runner_started, "review", "ingestion-one", ^artefact_id, replacement}
      send(replacement, :finish_reflection)
      assert_receive {:reflection_completed, "review", {:ok, _artefact}}
    end
  end

  describe "if scheduling receives duplicate Reflection names" do
    test "then duplicate Reflection names fail before execution and empty work retains nothing",
         %{
           reflection: reflection
         } do
      assert {:error, {:duplicate_reflection, "review"}} =
               Scheduler.schedule([reflection, reflection], scheduler_ingestion())

      refute_receive {:runner_started, _name, _ingestion, _artefact_id, _runner}
      assert {:ok, :scheduled} = Scheduler.schedule([], scheduler_ingestion())
      assert :ok = Scheduler.drain()
    end
  end

  describe "when an ingestion completes while no Reflections are declared" do
    test "then public ingestion with no Reflections succeeds without retaining work" do
      Application.put_env(:jido_gralkor, :reflections, [])

      assert :ok = Client.ingest(ingestion())
      assert :ok = Scheduler.drain()
      refute_receive {:runner_started, _name, _ingestion, _artefact_id, _runner}
    end
  end

  describe "when the application stops gracefully with unfinished Reflection work" do
    test "then graceful draining waits for admitted work to finish" do
      assert :ok = Client.ingest(ingestion())
      assert_receive {:runner_started, "review", "ingestion-one", _artefact_id, runner}

      drainer = Task.async(fn -> Scheduler.drain() end)
      assert Task.yield(drainer, 25) == nil

      send(runner, :finish_reflection)
      assert_receive {:reflection_completed, "review", {:ok, _artefact}}
      assert Task.await(drainer) == :ok
    end

    test "then CaptureBuffer shutdown drains the replacement Scheduler after a restart", %{
      reflection: reflection
    } do
      start_supervised!(
        {CaptureBuffer,
         flush_callback: fn _group, _agent, _user, _ontology, _turns -> :ok end,
         reflections: [reflection]}
      )

      original = Process.whereis(Scheduler)
      Process.exit(original, :kill)
      assert eventually(fn -> Process.whereis(Scheduler) not in [nil, original] end)

      assert :ok = Client.ingest(ingestion())
      assert_receive {:runner_started, "review", "ingestion-one", _artefact_id, runner}

      finisher =
        Task.async(fn ->
          Process.sleep(50)
          send(runner, :finish_reflection)
          :ok
        end)

      started = System.monotonic_time(:millisecond)
      assert :ok = stop_supervised(CaptureBuffer)
      assert System.monotonic_time(:millisecond) - started >= 40
      assert :ok = Task.await(finisher)
      assert :ok = Scheduler.drain()
    end

    test "then an active fire-and-forget capture flush admits and completes its Reflection before shutdown returns",
         %{reflection: reflection} do
      test_pid = self()
      assert :ok = stop_supervised(Scheduler)

      runner = fn _current_reflection, _ingestion, opts ->
        send(test_pid, :shutdown_runner_started)
        Process.sleep(100)

        {:ok, Artefact.new(opts[:artefact_id], %{"summary" => "stored"})}
      end

      start_supervised!(
        {Scheduler,
         runner: runner,
         store_opts: [storage: Gralkor.Destination.Storage.InMemory],
         notify: test_pid,
         retry_delays: [0]}
      )

      lens_flush_callback = fn _operator, _agent, _user, lens, _turns, _ingestion_id ->
        send(test_pid, {:shutdown_lens_flush_started, self()})

        receive do
          :finish_lens_flush ->
            {:ok, %{id: "representation-one", lens: lens, result: :ok}}
        end
      end

      start_supervised!(
        {CaptureBuffer,
         flush_callback: fn _group, _agent, _user, _ontology, _turns -> :ok end,
         lens_flush_callback: lens_flush_callback,
         reflections: [reflection],
         retries: []}
      )

      assert :ok =
               CaptureBuffer.append_lens(
                 "shutdown-session",
                 "operator-one",
                 "Susu",
                 "Eli",
                 "observations",
                 [Gralkor.Message.new("user", "remember")]
               )

      assert :ok = CaptureBuffer.flush("shutdown-session")
      assert_receive {:shutdown_lens_flush_started, worker}

      finisher =
        Task.async(fn ->
          Process.sleep(50)
          send(worker, :finish_lens_flush)
          :ok
        end)

      started = System.monotonic_time(:millisecond)
      assert :ok = stop_supervised(CaptureBuffer)
      assert System.monotonic_time(:millisecond) - started >= 125
      assert :ok = Task.await(finisher)
      assert_receive :shutdown_runner_started
      assert_receive {:reflection_completed, "review", {:ok, _artefact}}
    end

    test "then stopping the production-ordered child tree waits for admitted work", %{
      reflection: reflection
    } do
      test_pid = self()
      assert :ok = stop_supervised(Scheduler)

      inference = fn _request ->
        send(test_pid, :application_tree_runner_started)
        Process.sleep(100)
        {:ok, %{output: %{"summary" => "stored"}}}
      end

      children = [
        {Gralkor.Reflection.Supervisor,
         scheduler_opts: [
           runner_opts: [inference: inference],
           store_opts: [storage: Gralkor.Destination.Storage.InMemory],
           notify: test_pid,
           retry_delays: [0]
         ]},
        {CaptureBuffer,
         flush_callback: fn _group, _agent, _user, _ontology, _turns -> :ok end,
         reflections: [reflection]}
      ]

      {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

      assert :ok = Client.ingest(ingestion())
      assert_receive :application_tree_runner_started

      started = System.monotonic_time(:millisecond)
      stopper = Task.async(fn -> Supervisor.stop(supervisor, :normal, :infinity) end)
      assert Task.yield(stopper, 25) == nil
      assert :ok = Task.await(stopper)
      assert System.monotonic_time(:millisecond) - started >= 75
      assert_receive {:reflection_completed, "review", {:ok, _artefact}}
    end

    test "then an empty initial Reflection registry still drains directly admitted work", %{
      reflection: reflection
    } do
      test_pid = self()
      assert :ok = stop_supervised(Scheduler)

      runner = fn _current_reflection, _ingestion, opts ->
        send(test_pid, :empty_registry_functional_runner_started)
        Process.sleep(100)

        {:ok, Artefact.new(opts[:artefact_id], %{"summary" => "stored"})}
      end

      children = [
        {Gralkor.Reflection.Supervisor,
         scheduler_opts: [
           runner: runner,
           store_opts: [storage: Gralkor.Destination.Storage.InMemory],
           notify: test_pid,
           retry_delays: []
         ]},
        {CaptureBuffer,
         flush_callback: fn _group, _agent, _user, _ontology, _turns -> :ok end, reflections: []}
      ]

      {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

      assert {:ok, :scheduled} = Scheduler.schedule([reflection], scheduler_ingestion())
      assert_receive :empty_registry_functional_runner_started

      stopper = Task.async(fn -> Supervisor.stop(supervisor, :normal, :infinity) end)
      assert Task.yield(stopper, 25) == nil
      assert :ok = Task.await(stopper)
      assert_receive {:reflection_completed, "review", {:ok, _artefact}}
    end

    test "then a Scheduler exit during drain waits for its durable replacement", %{
      reflection: reflection
    } do
      test_pid = self()
      assert :ok = stop_supervised(Scheduler)
      attempts = :atomics.new(1, [])

      journal_path =
        Path.join(
          System.tmp_dir!(),
          "reflection-drain-restart-#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}.dets"
        )

      on_exit(fn -> File.rm(journal_path) end)

      runner = fn _current_reflection, _ingestion, opts ->
        attempt = :atomics.add_get(attempts, 1, 1)
        send(test_pid, {:drain_restart_functional_runner, attempt, self()})

        if attempt == 1 do
          receive do
            :never -> {:error, :unexpected}
          end
        else
          {:ok,
           Artefact.new(
             opts[:artefact_id],
             %{"summary" => "stored"}
           )}
        end
      end

      children = [
        {Gralkor.Reflection.Supervisor,
         scheduler_opts: [
           runner: runner,
           store_opts: [storage: Gralkor.Destination.Storage.InMemory],
           notify: test_pid,
           retry_delays: [0],
           journal_path: journal_path
         ]},
        {CaptureBuffer,
         flush_callback: fn _group, _agent, _user, _ontology, _turns -> :ok end, reflections: []}
      ]

      {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
      assert {:ok, :scheduled} = Scheduler.schedule([reflection], scheduler_ingestion())
      assert_receive {:drain_restart_functional_runner, 1, _first_runner}

      first_scheduler = Process.whereis(Scheduler)
      stopper = Task.async(fn -> Supervisor.stop(supervisor, :normal, :infinity) end)
      assert eventually(fn -> :sys.get_state(Scheduler).draining end)
      Process.exit(first_scheduler, :kill)

      assert_receive {:drain_restart_functional_runner, 2, _replacement_runner}, 1_000
      assert_receive {:reflection_completed, "review", {:ok, _artefact}}, 1_000
      assert :ok = Task.await(stopper)
    end
  end

  describe "where Graphiti is the Destination artefact store" do
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
    end
  end

  describe "when Destination storage commits an artefact but its response is lost" do
    test "then a committed write whose response is lost retries to one searchable artefact" do
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

      artefact_id = Artefact.id_for("operator-one", "ingestion-one", "review")

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

      assert :ok = Client.ingest(ingestion())
      assert_receive {:runner_started, "review", "ingestion-one", ^artefact_id, runner}, 1_000
      send(runner, :finish_reflection)

      assert_receive {:graphiti_store_committed, first}, 1_000
      assert first.id == artefact_id

      assert_receive {:reflection_retrying, "review", %{stage: :storage, reason: :response_lost}},
                     1_000

      assert_receive {:graphiti_store_committed, ^first}, 1_000
      assert_receive {:reflection_completed, "review", {:ok, ^first}}, 1_000

      Application.put_env(
        :jido_gralkor,
        :destination_storage,
        Gralkor.Destination.Storage.Graphiti
      )

      Pythonx.eval(
        """
        original = next(iter(graphiti.driver.episodes.values()))
        partials = {
            f'legacy-unmarked-{index}': original.model_copy(
                update={'uuid': f'legacy-unmarked-{index}'}
            )
            for index in range(25)
        }
        graphiti.driver.episodes = {**partials, **graphiti.driver.episodes}
        """,
        %{"graphiti" => graphiti}
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
        original = next(iter(graphiti.driver.episodes.values()))
        duplicate = original.model_copy(update={'uuid': 'legacy-equal-duplicate'})
        graphiti.driver.episodes[duplicate.uuid] = duplicate
        graphiti.driver._gralkor_completed_episode_uuids.add(duplicate.uuid)
        """,
        %{"graphiti" => graphiti}
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
        original = next(iter(graphiti.driver.episodes.values()))
        conflict = original.model_copy(
            update={'uuid': 'legacy-conflicting-duplicate', 'content': body}
        )
        graphiti.driver.episodes[conflict.uuid] = conflict
        graphiti.driver._gralkor_completed_episode_uuids.add(conflict.uuid)
        """,
        %{"graphiti" => graphiti, "conflicting_content" => conflicting_content}
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
    end
  end

  describe "where Graphiti is the Destination artefact store > when graph extraction fails before its claim-fenced transaction commits" do
    test "then canonical lookup and public search expose no episode and a later equal write retries extraction",
         %{
           reflection: reflection
         } do
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

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection], scheduler_ingestion())

      assert_receive {:runner_started, "review", "ingestion-one", ^artefact_id, runner}, 1_000
      send(runner, :finish_reflection)
      assert_receive {:reflection_completed, "review", {:ok, ^partial_artefact}}, 5_000

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
    end
  end

  describe "where Graphiti is the Destination artefact store > when a deterministic episode predates graph-backed claim admission" do
    test "then a completed episode rejects conflicting immutable content and remains unchanged" do
      {pool, graphiti} = start_preclaim_graphiti_pool(:reflection_preclaim_complete_graphiti)

      Pythonx.eval(
        """
        import asyncio
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc)
        asyncio._gralkor_run(graphiti.driver.execute_query(
            '''
            CREATE (episode:Episodic {
              uuid: $uuid,
              name: 'legacy deterministic episode',
              group_id: 'observations',
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
        ))
        """,
        %{"graphiti" => graphiti}
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
    end

    test "then canonical lookup resumes an incomplete artefact without rerunning its Runner" do
      {pool, graphiti} = start_preclaim_graphiti_pool(:reflection_preclaim_incomplete_graphiti)
      reflection = hd(Application.fetch_env!(:jido_gralkor, :reflections))
      artefact_id = Artefact.id_for("operator-one", "ingestion-one", "review")
      artefact = Artefact.new(artefact_id, %{"summary" => "stored"})
      content = Jason.encode!(Map.from_struct(artefact))

      Pythonx.eval(
        """
        import asyncio
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc)
        uid = uuid.decode('utf-8') if isinstance(uuid, (bytes, bytearray)) else uuid
        body = content.decode('utf-8') if isinstance(content, (bytes, bytearray)) else content
        asyncio._gralkor_run(graphiti.driver.execute_query(
            '''
            CREATE (episode:Episodic {
              uuid: $uuid,
              name: 'legacy deterministic episode',
              group_id: 'observations',
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
        ))
        """,
        %{"graphiti" => graphiti, "uuid" => artefact_id, "content" => content}
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

      assert {:ok, :scheduled} = Scheduler.schedule([reflection], scheduler_ingestion())
      assert_receive {:reflection_completed, "review", {:ok, ^artefact}}, 1_000
      refute_receive {:runner_started, "review", "ingestion-one", ^artefact_id, _runner}

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
    end
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

  describe "where Graphiti is the Destination artefact store > when independent pools share one Falkor graph" do
    @tag timeout: 120_000
    test "then server-timed generational claims serialize, reject conflicts, and fence a stale owner" do
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
        asyncio._gralkor_run(graph.driver.execute_query(
            '''
            MERGE (c:_GralkorEpisodeClaim {uuid: $uuid})
            ON CREATE SET
              c.group_id = 'observations',
              c.content = 'same',
              c.source = 'text',
              c.source_description = 'source',
              c.owner = 'expired-owner',
              c.generation = 7,
              c.lease_until_ms = timestamp() - 1
            RETURN c.generation AS generation
            ''',
            uuid='embedded-server-expired',
        ))
        """,
        %{"graph" => first_graph}
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
    end
  end

  defp ingestion do
    %Ingest{
      id: "ingestion-one",
      operator_id: "operator-one",
      lens: "observations",
      source_kind: :document,
      content: "The deployment succeeded.",
      source_description: "deployment"
    }
  end

  defp scheduler_ingestion do
    %{
      id: "ingestion-one",
      operator_id: "operator-one",
      intended_lenses: ["observations"],
      completed_lenses: ["observations"],
      representations: [
        %{
          id: "representation-one",
          lens: "observations",
          content: "The deployment succeeded.",
          result: :ok
        }
      ]
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

  defp receive_runners(0, runners), do: runners

  defp receive_runners(remaining, runners) do
    assert_receive {:runner_started, name, "ingestion-one", _artefact_id, runner}
    receive_runners(remaining - 1, Map.put(runners, name, runner))
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
