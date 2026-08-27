defmodule Gralkor.ApplicationBackendLifecycleFunctionalTest do
  use ExUnit.Case, async: false

  alias Gralkor.Application, as: GralkorApplication
  alias Gralkor.GraphitiPool

  @moduletag :functional
  @moduletag timeout: 120_000

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
               {Gralkor.CaptureBuffer, _capture_options}
             ] = GralkorApplication.children()

      assert Keyword.fetch!(pool_options, :falkordb_spec) ==
               {:remote, [host: "memory.example", port: 6379]}
    end
  end

  describe "when an application starts with an embedded memory backend" do
    test "then the native memory runtime starts with an embedded server owned for that application's lifetime" do
      %{pool: pool, server_pid: server_pid, data_dir: data_dir} = start_embedded_runtime()

      assert Process.alive?(pool)
      assert process_running?(server_pid)

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
end
