defmodule Gralkor.ApplicationIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Gralkor.Application, as: App
  alias Gralkor.Client

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

    test "then startup returns only once the Python runtime, graph pool, and capture buffer have initialised" do
      assert_startup_returns_after_children_initialise()
    end
  end

  # The production path (start/2) builds the flush callback with NO add_episode_fn
  # dep, so it falls back to the default. Every other build_flush_callback test
  # injects a stub add_episode_fn and never exercises that default — which is
  # exactly where a dispatch bug hides: GraphitiPool.add_episode carries defaults
  # on server (1st) and opts (6th), so a 5-arity capture bound the wrong params and
  # raised FunctionClauseError on every real capture, exhausting CaptureBuffer and
  # writing nothing. This wires the real GraphitiPool (fake graphiti recording the
  # add_episode call) and drives the DEFAULT-wired callback end-to-end.
  describe "when a capture flush runs > while no episode-writing dependency is supplied" do
    setup do
      {g, _} =
        Pythonx.eval(
          """
          import asyncio

          class _FakeGraphiti:
              def __init__(self):
                  self.recorded = {}

              async def build_indices_and_constraints(self):
                  return None

              async def add_episode(self, **kwargs):
                  self.recorded['episode_body'] = kwargs.get('episode_body')
                  self.recorded['source_description'] = kwargs.get('source_description')
                  self.recorded['group_id'] = kwargs.get('group_id')
                  return None

          _FakeGraphiti()
          """,
          %{}
        )

      start_supervised!(
        {Gralkor.GraphitiPool,
         [
           name: Gralkor.GraphitiPool,
           table: :gralkor_graphiti_instances,
           falkordb_spec: {:embedded, "/tmp/never_used"},
           construct_falkor_db: fn _spec -> :stub_falkor_db end,
           construct_shared_clients: fn _spec ->
             %{llm_client: nil, embedder: nil, cross_encoder: nil}
           end,
           construct_instance: fn _db, _shared, _group_id -> g end,
           warmup: false,
           install_loop_fn: &Gralkor.Python.install_async_runtime/0
         ]}
      )

      %{g: g}
    end

    test "then default writes name the graph pool server explicitly and reach it without shifted arguments",
         %{g: g} do
      cb = App.build_flush_callback({:embedded, "/tmp/never_used"})

      turns = [
        [
          Gralkor.Message.new("user", "the backup keeps failing"),
          Gralkor.Message.new("assistant", "I moved the vacuum job to 04:00")
        ]
      ]

      assert :ok = cb.("flush_group", "Susu", "Eli", nil, turns)

      {rec, _} = Pythonx.eval("g.recorded", %{"g" => g})
      rec = Pythonx.decode(rec)
      assert rec["source_description"] == "captured [gralkor: direct]"
      assert rec["group_id"] == Client.sanitize_group_id("flush_group")
      assert rec["episode_body"] =~ "vacuum"
    end

    test "and the logical group is encoded exactly once by that graph pool boundary", %{g: g} do
      cb = App.build_flush_callback({:embedded, "/tmp/never_used"})

      turns = [
        [
          Gralkor.Message.new("user", "the backup keeps failing"),
          Gralkor.Message.new("assistant", "I moved the vacuum job to 04:00")
        ]
      ]

      assert :ok = cb.("operator/one", "Susu", "Eli", nil, turns)

      {rec, _} = Pythonx.eval("g.recorded", %{"g" => g})
      rec = Pythonx.decode(rec)
      assert rec["group_id"] == Client.sanitize_group_id("operator/one")
    end
  end

  defp assert_startup_returns_after_children_initialise do
    start_application_children(self())

    assert_received {:initialised, Gralkor.Python}
    assert_received {:initialised, Gralkor.GraphitiPool}
    assert :ok = Gralkor.CaptureBuffer.flush_all()
  end

  defp start_application_children(test_pid) do
    data_dir = ready_data_dir()
    System.put_env("GRALKOR_DATA_DIR", data_dir)
    Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)

    [
      {Gralkor.Python, python_opts},
      {Gralkor.GraphitiPool, pool_opts},
      {Gralkor.CaptureBuffer, buffer_opts}
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
             {Gralkor.GraphitiPool, pool_opts},
             {Gralkor.CaptureBuffer, buffer_opts}
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
