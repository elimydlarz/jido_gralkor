defmodule Gralkor.ApplicationBackendLifecycleFunctionalTest do
  use ExUnit.Case, async: false

  alias Gralkor.Application, as: GralkorApplication
  alias Gralkor.CaptureBuffer
  alias Gralkor.Client
  alias Gralkor.GraphitiPool
  alias Gralkor.Message

  @moduletag :functional
  @moduletag timeout: 120_000

  setup do
    previous_falkordb = Application.get_env(:jido_gralkor, :falkordb)
    previous_client = Application.get_env(:jido_gralkor, :client)
    previous_destinations = Application.get_env(:jido_gralkor, :destinations)
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_lens_storage = Application.get_env(:jido_gralkor, :lens_storage)
    previous_reflections = Application.get_env(:jido_gralkor, :reflections)
    previous_data_dir = System.get_env("GRALKOR_DATA_DIR")

    on_exit(fn ->
      restore_application_env(:falkordb, previous_falkordb)
      restore_application_env(:client, previous_client)
      restore_application_env(:destinations, previous_destinations)
      restore_application_env(:lenses, previous_lenses)
      restore_application_env(:lens_storage, previous_lens_storage)
      restore_application_env(:reflections, previous_reflections)
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

      %{pool: pool} = start_remote_runtime()

      assert :sys.get_state(pool).falkordb_spec == {:remote, [host: "memory.example", port: 6379]}
      assert_received {:falkor_db_constructed, {:remote, [host: "memory.example", port: 6379]}}
      assert :sys.get_state(pool).falkor_db == :remote_falkor_db
    end

    test "and application compatibility capture does not require an owning agent runtime" do
      Application.put_env(:jido_gralkor, :falkordb, host: "memory.example", port: 6379)
      Application.put_env(:jido_gralkor, :reflections, :invalid_if_resolved)
      Application.put_env(:jido_gralkor, :destinations, [[name: "observations"]])

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          destination: "observations",
          ingestion: Gralkor.Lens.Ingestion.Store
        ]
      ])

      Application.put_env(
        :jido_gralkor,
        :lens_storage,
        Gralkor.Lens.Storage.InMemory
      )

      start_supervised!(Gralkor.Lens.Storage.InMemory)

      assert [
               {Gralkor.Python, _python_options},
               {GraphitiPool, _pool_options},
               {CaptureBuffer, capture_options}
             ] = GralkorApplication.children()

      start_supervised!({CaptureBuffer, capture_options})

      assert :ok =
               CaptureBuffer.append_lens(
                 "reflection-free-capture",
                 "operator-one",
                 "Susu",
                 "Eli",
                 "observations",
                 [Message.new("user", "captured without Reflection scheduling")]
               )

      assert :ok = CaptureBuffer.flush_and_await("reflection-free-capture", 1_000)

      assert [%{lens: "observations"}] =
               Gralkor.Lens.Storage.InMemory.episodes("observations")
    end

    test "and buffered Lens capture flushes without resolving or invoking configured Reflections" do
      Application.put_env(:jido_gralkor, :falkordb, host: "memory.example", port: 6379)
      Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)
      start_supervised!(Gralkor.Lens.Storage.InMemory)
      test_pid = self()

      start_supervised!(
        {JidoGralkor.Runtime,
         owner: test_pid,
         configuration: %{
           destinations: [%{name: "observations"}],
           lenses: [
             %{
               name: "observations",
               destination: "observations",
               write: :append,
               ingestion: Gralkor.Lens.Ingestion.Store
             }
           ],
           reflections: [
             %{
               name: "review",
               chain_of_thought: %{
                 steps: [
                   %{label: "review", directions: "Review", output: %{"summary" => "string"}}
                 ]
               },
               outputs: [%{kind: :destination, destination: "observations"}]
             }
           ]
         },
         run_reflection: fn reflection, invocation, _opts ->
           send(test_pid, {:reflection_run, reflection.name, invocation})
           {:error, :unexpected_reflection}
         end,
         deliver_artefact: fn _output, reflection_name, _operator_id, _artefact ->
           send(test_pid, {:reflection_delivered, reflection_name})
           :ok
         end}
      )

      assert [{Gralkor.Python, _}, {GraphitiPool, _}, {CaptureBuffer, capture_options}] =
               GralkorApplication.children()

      start_supervised!({CaptureBuffer, capture_options})

      assert :ok =
               Client.capture(test_pid, %Gralkor.Capture{
                 session_id: "reflection-free-capture",
                 operator_id: "operator-one",
                 agent_name: "Susu",
                 user_name: "Eli",
                 messages: [Message.new("user", "captured without Reflection scheduling")],
                 route: {:lenses, ["observations"]}
               })

      assert :ok = CaptureBuffer.flush_and_await("reflection-free-capture", 1_000)
      assert [%{lens: "observations"}] = Gralkor.Lens.Storage.InMemory.episodes("observations")
      refute_receive {:reflection_run, _name, _invocation}, 100
      refute_received {:reflection_delivered, _name}
    end
  end

  describe "when an application starts with an embedded memory backend" do
    test "then the native memory runtime starts with an embedded server owned for that application's lifetime" do
      %{pool: pool, supervisor: supervisor, server_pid: server_pid, data_dir: data_dir} =
        start_embedded_runtime()

      assert Process.alive?(pool)
      assert :sys.get_state(pool).falkordb_spec == {:embedded, Path.expand(data_dir)}
      assert process_running?(server_pid)

      Supervisor.stop(supervisor)
    end
  end

  describe "when an application starts with an embedded memory backend > when the application stops" do
    test "then the owned embedded server exits before shutdown completes" do
      %{supervisor: supervisor, server_pid: server_pid} = start_embedded_runtime()

      Supervisor.stop(supervisor)

      refute process_running?(server_pid)
    end
  end

  describe "when an application configures both a remote backend and a data directory" do
    test "then the native memory runtime uses the remote backend without owning an embedded server" do
      data_dir = unique_data_dir()
      System.put_env("GRALKOR_DATA_DIR", data_dir)
      Application.put_env(:jido_gralkor, :falkordb, host: "memory.example", port: 6379)

      %{pool: pool} = start_remote_runtime()

      assert :sys.get_state(pool).falkordb_spec == {:remote, [host: "memory.example", port: 6379]}
      assert_received {:falkor_db_constructed, {:remote, [host: "memory.example", port: 6379]}}
      refute_received {:falkor_db_constructed, {:embedded, _}}
      assert :sys.get_state(pool).falkor_db == :remote_falkor_db
      refute File.exists?(data_dir)
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

  defp unique_data_dir do
    Path.join(
      System.tmp_dir!(),
      "application_backend_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
    )
  end

  defp start_remote_runtime do
    test_pid = self()

    assert [
             {Gralkor.Python, [reap_orphans: false]} = python,
             {GraphitiPool, pool_options},
             {Gralkor.CaptureBuffer, _capture_options} = capture
           ] = GralkorApplication.children()

    pool_options =
      Keyword.merge(pool_options,
        name: nil,
        table: :"application_backend_remote_#{System.unique_integer([:positive])}",
        construct_falkor_db: fn spec ->
          send(test_pid, {:falkor_db_constructed, spec})
          :remote_falkor_db
        end,
        construct_shared_clients: fn _llm, _embedder ->
          %{llm_client: nil, embedder: nil, cross_encoder: nil}
        end,
        warmup: false
      )

    supervisor =
      start_supervised!(%{
        id: :remote_application_children,
        start:
          {Supervisor, :start_link,
           [[python, {GraphitiPool, pool_options}, capture], [strategy: :one_for_one]]},
        type: :supervisor
      })

    assert [
             {CaptureBuffer, capture_pid, :worker, _},
             {GraphitiPool, pool, :worker, _},
             {Gralkor.Python, python_pid, :worker, _}
           ] = Supervisor.which_children(supervisor)

    assert Enum.all?([capture_pid, pool, python_pid], &Process.alive?/1)

    %{pool: pool}
  end

  defp start_embedded_runtime do
    data_dir = unique_data_dir()
    System.put_env("GRALKOR_DATA_DIR", data_dir)

    assert [{Gralkor.Python, [reap_orphans: true]}, {GraphitiPool, pool_options}, _capture] =
             GralkorApplication.children()

    assert Keyword.fetch!(pool_options, :falkordb_spec) == {:embedded, Path.expand(data_dir)}

    table = :"application_backend_pool_#{System.unique_integer([:positive])}"

    options =
      Keyword.merge(pool_options,
        name: nil,
        table: table,
        construct_shared_clients: fn _llm, _embedder ->
          %{llm_client: nil, embedder: nil, cross_encoder: nil}
        end,
        warmup: false
      )

    supervisor =
      start_supervised!(%{
        id: table,
        start: {Supervisor, :start_link, [[{GraphitiPool, options}], [strategy: :one_for_one]]},
        type: :supervisor,
        restart: :temporary
      })

    [{GraphitiPool, pool, :worker, _}] = Supervisor.which_children(supervisor)

    database = :sys.get_state(pool).falkor_db
    {server_pid, _} = Pythonx.eval("database.client.pid", %{"database" => database})

    server_pid = Pythonx.decode(server_pid)

    on_exit(fn ->
      if process_running?(server_pid) do
        Pythonx.eval("database.client._sync_client.shutdown(save=False)", %{
          "database" => database
        })
      end

      File.rm_rf!(data_dir)
    end)

    %{pool: pool, supervisor: supervisor, server_pid: server_pid, data_dir: data_dir}
  end

  defp process_running?(pid) do
    {_output, status} = System.cmd("ps", ["-p", to_string(pid), "-o", "pid="])
    status == 0
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_application_env(key, value), do: Application.put_env(:jido_gralkor, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
