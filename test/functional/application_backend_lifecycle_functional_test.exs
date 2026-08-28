defmodule Gralkor.ApplicationBackendLifecycleFunctionalTest do
  use ExUnit.Case, async: false

  alias Gralkor.Application, as: GralkorApplication
  alias Gralkor.CaptureBuffer
  alias Gralkor.Destination
  alias Gralkor.GraphitiPool
  alias Gralkor.Reflection
  alias Gralkor.Reflection.Artefact
  alias Gralkor.Reflection.ChainOfThought
  alias Gralkor.Reflection.Scheduler

  @moduletag :functional
  @moduletag timeout: 120_000

  defmodule EmptyReflectionStore do
    @behaviour Gralkor.Reflection.Store

    @impl true
    def get(_reflection, _operator_id, _artefact_id), do: {:error, :not_found}

    @impl true
    def put(_reflection, _operator_id, _artefact), do: :ok
  end

  setup do
    previous_falkordb = Application.get_env(:jido_gralkor, :falkordb)
    previous_client = Application.get_env(:jido_gralkor, :client)
    previous_data_dir = System.get_env("GRALKOR_DATA_DIR")

    on_exit(fn ->
      restore_application_env(:falkordb, previous_falkordb)
      restore_application_env(:client, previous_client)
      restore_system_env("GRALKOR_DATA_DIR", previous_data_dir)
    end)

    Application.delete_env(:jido_gralkor, :client)
    Application.delete_env(:jido_gralkor, :falkordb)
    System.delete_env("GRALKOR_DATA_DIR")
    :ok
  end

  describe "when an application starts with a remote memory backend" do
    test "then the native memory runtime starts without owning an embedded server" do
      Application.put_env(:jido_gralkor, :falkordb, host: "memory.example", port: 6379)

      assert [
               {Gralkor.Python, [reap_orphans: false]},
               {GraphitiPool, pool_options},
               {Gralkor.Reflection.Supervisor, reflection_options},
               {Gralkor.CaptureBuffer, _capture_options}
             ] = GralkorApplication.children()

      assert Keyword.fetch!(pool_options, :falkordb_spec) ==
               {:remote, [host: "memory.example", port: 6379]}

      scheduler_options = Keyword.fetch!(reflection_options, :scheduler_opts)

      assert Keyword.fetch!(scheduler_options, :journal_path) =~
               "jido_gralkor/reflection_scheduler.dets"
    end

    test "then its production child order can replace Scheduler while CaptureBuffer drains" do
      test_pid = self()
      Application.put_env(:jido_gralkor, :falkordb, host: "memory.example", port: 6379)
      attempts = :atomics.new(1, [])

      [
        _python,
        _pool,
        {Gralkor.Reflection.Supervisor, reflection_options},
        {CaptureBuffer, capture_options}
      ] = GralkorApplication.children()

      journal_path =
        Path.join(
          System.tmp_dir!(),
          "application-reflection-drain-#{System.unique_integer([:positive])}.dets"
        )

      on_exit(fn -> File.rm(journal_path) end)

      runner = fn reflection, _ingestion, opts ->
        attempt = :atomics.add_get(attempts, 1, 1)
        send(test_pid, {:application_drain_runner, attempt})

        if attempt == 1 do
          receive do
            :never -> {:error, :unexpected}
          end
        else
          {:ok, Artefact.new(opts[:artefact_id], reflection.name, %{"done" => true}, [])}
        end
      end

      scheduler_options =
        reflection_options
        |> Keyword.fetch!(:scheduler_opts)
        |> Keyword.merge(
          runner: runner,
          store_opts: [storage: EmptyReflectionStore],
          notify: test_pid,
          retry_delays: [0],
          journal_path: journal_path
        )

      children = [
        {Gralkor.Reflection.Supervisor, scheduler_opts: scheduler_options},
        {CaptureBuffer, Keyword.put(capture_options, :reflections, [])}
      ]

      reflection = %Reflection{
        name: "review",
        destination: %Destination{name: "observations"},
        ontology: Gralkor.DefaultOntology,
        chain_of_thought: %ChainOfThought{path: "test", steps: []}
      }

      ingestion = %{
        id: "application-drain",
        operator_id: "operator-one",
        intended_lenses: ["observations"],
        completed_lenses: ["observations"],
        representations: [%{lens: "observations", result: :ok}]
      }

      {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
      assert {:ok, :scheduled} = Scheduler.schedule([reflection], ingestion)
      assert_receive {:application_drain_runner, 1}

      first_scheduler = Process.whereis(Scheduler)
      stopper = Task.async(fn -> Supervisor.stop(supervisor, :normal, :infinity) end)
      assert eventually(fn -> :sys.get_state(Scheduler).draining end)
      Process.exit(first_scheduler, :kill)

      assert_receive {:application_drain_runner, 2}
      assert_receive {:reflection_completed, "review", {:ok, _artefact}}
      assert :ok = Task.await(stopper)
    end
  end

  describe "when an application starts with an embedded memory backend" do
    test "then the native memory runtime starts with an embedded server owned for that application's lifetime" do
      %{pool: pool, server_pid: server_pid, data_dir: data_dir} = start_embedded_runtime()

      assert Process.alive?(pool)
      assert process_running?(server_pid)

      assert [
               _python,
               _pool,
               {Gralkor.Reflection.Supervisor, reflection_options},
               _capture
             ] = GralkorApplication.children()

      scheduler_options = Keyword.fetch!(reflection_options, :scheduler_opts)

      assert Keyword.fetch!(scheduler_options, :journal_path) ==
               Path.join(data_dir, "reflection_scheduler.dets")

      GenServer.stop(pool)
      File.rm_rf!(data_dir)
    end
  end

  describe "when an application starts with an embedded memory backend > when the application stops" do
    test "then the owned embedded server exits before shutdown completes" do
      %{pool: pool, server_pid: server_pid, data_dir: data_dir} = start_embedded_runtime()

      GenServer.stop(pool)

      refute process_running?(server_pid)
      File.rm_rf!(data_dir)
    end
  end

  describe "if an application starts with invalid remote memory-backend configuration" do
    test "then startup raises before the native memory runtime starts" do
      Application.put_env(:jido_gralkor, :falkordb, host: "memory.example")

      assert_raise ArgumentError, fn -> GralkorApplication.children() end
      refute Process.whereis(Gralkor.Python)
    end

    test "and the error identifies the invalid configuration" do
      Application.put_env(:jido_gralkor, :falkordb, host: "memory.example")

      assert_raise ArgumentError,
                   ~r/:jido_gralkor, :falkordb requires :port .* got nil/,
                   fn -> GralkorApplication.children() end
    end
  end

  describe "when an application starts without a configured memory backend" do
    test "then it starts without the native memory runtime" do
      assert GralkorApplication.children() == []
    end
  end

  defp start_embedded_runtime do
    data_dir =
      Path.join(System.tmp_dir!(), "application_backend_#{System.unique_integer([:positive])}")

    System.put_env("GRALKOR_DATA_DIR", data_dir)

    table = :"application_backend_pool_#{System.unique_integer([:positive])}"

    {:ok, pool} =
      GraphitiPool.start_link(
        name: nil,
        table: table,
        falkordb_spec: {:embedded, data_dir},
        construct_shared_clients: fn _llm, _embedder ->
          %{llm_client: nil, embedder: nil, cross_encoder: nil}
        end,
        warmup: false,
        install_loop_fn: &Gralkor.Python.install_async_runtime/0
      )

    database = :sys.get_state(pool).falkor_db
    {server_pid, _} = Pythonx.eval("database.client.pid", %{"database" => database})

    %{pool: pool, server_pid: Pythonx.decode(server_pid), data_dir: data_dir}
  end

  defp process_running?(pid) do
    {_output, status} = System.cmd("ps", ["-p", to_string(pid), "-o", "pid="])
    status == 0
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_application_env(key, value), do: Application.put_env(:jido_gralkor, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

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
end
