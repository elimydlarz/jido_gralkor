defmodule Gralkor.ApplicationIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Gralkor.Application, as: App

  describe "when the application starts > while a data directory is configured and no remote connection is configured" do
    setup do
      original_env = System.get_env("GRALKOR_DATA_DIR")
      original_client = Application.get_env(:jido_gralkor, :client)
      original_falkordb = Application.get_env(:jido_gralkor, :falkordb)
      original_reflection_storage = Application.get_env(:jido_gralkor, :reflection_storage)

      on_exit(fn ->
        restore_env("GRALKOR_DATA_DIR", original_env)
        restore_app_env(:client, original_client)
        restore_app_env(:falkordb, original_falkordb)
        restore_app_env(:reflection_storage, original_reflection_storage)
      end)

      Application.delete_env(:jido_gralkor, :falkordb)
      Application.delete_env(:jido_gralkor, :reflection_storage)
      :ok
    end

    test "then startup returns only once the Python runtime and graph pool have initialised" do
      assert_startup_returns_after_children_initialise()
    end
  end

  defp assert_startup_returns_after_children_initialise do
    start_application_children(self())

    assert_received {:initialised, Gralkor.Python}
    assert_received {:initialised, Gralkor.GraphitiPool}
  end

  defp start_application_children(test_pid) do
    data_dir = ready_data_dir()
    System.put_env("GRALKOR_DATA_DIR", data_dir)
    Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)

    [
      {Gralkor.Python, python_opts},
      {Gralkor.GraphitiPool, pool_opts}
    ] = App.children()

    python_opts = initialising_python_opts(python_opts, test_pid)
    pool_opts = initialising_pool_opts(pool_opts, test_pid)

    start_supervised!(%{
      id: :gralkor_application_children,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           [
             {Gralkor.Python, python_opts},
             {Gralkor.GraphitiPool, pool_opts}
           ],
           [strategy: :one_for_one]
         ]}
    })
  end

  defp ready_data_dir do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "ex_app_ready_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)
    data_dir
  end

  defp initialising_python_opts(python_opts, test_pid) do
    Keyword.merge(python_opts,
      list_orphans: fn -> [] end,
      kill_pid: fn pid -> flunk("unexpected orphan kill #{pid}") end,
      uv_init: fn -> :ok end,
      smoke_import: fn -> :ok end,
      smoke_import_provider: fn _provider -> :ok end,
      install_loop_fn: fn ->
        Process.sleep(50)
        send(test_pid, {:initialised, Gralkor.Python})
        :ok
      end
    )
  end

  defp initialising_pool_opts(pool_opts, test_pid) do
    Keyword.merge(pool_opts,
      install_loop_fn: fn -> :ok end,
      construct_shared_clients: fn _spec ->
        %{llm_client: nil, embedder: nil, cross_encoder: nil}
      end,
      construct_falkor_db: fn _spec ->
        Process.sleep(50)
        send(test_pid, {:initialised, Gralkor.GraphitiPool})
        :stub_falkor_db
      end,
      warmup: false
    )
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_app_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
