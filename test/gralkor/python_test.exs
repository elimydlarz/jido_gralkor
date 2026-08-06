defmodule Gralkor.PythonTest do
  use ExUnit.Case, async: false

  alias Gralkor.Python

  setup do
    :persistent_term.erase({Python, :swept})
    :ok
  end

  describe "when the Python runtime initialises" do
    test "then the call blocks until the runtime is ready" do
      test_pid = self()

      assert {:ok, _} =
               Python.init(
                 reap_orphans: true,
                 list_orphans: fn ->
                   send(test_pid, :reaped)
                   []
                 end,
                 kill_pid: fn _ -> :ok end,
                 uv_init: fn ->
                   send(test_pid, :materialised)
                   :ok
                 end,
                 smoke_import: fn ->
                   send(test_pid, :imported)
                   :ok
                 end,
                 install_loop: false
               )

      assert_received :reaped
      assert_received :materialised
      assert_received :imported
    end

    test "and the packaged manifest owns the graph library, embedded backend, and supported-provider packages" do
      manifest = File.read!(Path.expand("../../priv/python/pyproject.toml", __DIR__))

      assert manifest =~ "graphiti-core[falkordb,google-genai]"
      assert manifest =~ "falkordblite"
      assert manifest =~ "OpenAI LLM, embedder, and reranker"
    end

    test "and changing the packaged manifest triggers recompilation" do
      manifest_path = Path.expand("../../priv/python/pyproject.toml", __DIR__)

      assert manifest_path in Enum.map(
               Python.__info__(:attributes)[:external_resource],
               &Path.expand/1
             )
    end

    @tag :integration
    test "and a second initialisation in the same virtual machine short-circuits" do
      assert :persistent_term.get({Python, :uv_inited}, false) == true
      assert :ok = Python.ensure_initialised()
    end

    @tag :integration
    test "and the graph library imports successfully" do
      assert :ok = Python.smoke_import_graphiti()
    end

    test "and every supported provider's clients are smoke-imported before the runtime reports ready" do
      test_pid = self()

      assert {:ok, _} =
               Python.init(
                 reap_orphans: false,
                 uv_init: fn -> :ok end,
                 smoke_import: fn -> :ok end,
                 smoke_import_provider: fn provider ->
                   send(test_pid, {:provider_imported, provider})
                   :ok
                 end,
                 install_loop: false
               )

      for provider <- Gralkor.GraphitiPool.supported_providers() do
        assert_received {:provider_imported, ^provider}
      end
    end

    @tag :integration
    test "and the packaged clients for every supported provider import successfully" do
      for provider <- Gralkor.GraphitiPool.supported_providers() do
        assert :ok == Python.smoke_import_provider_clients(provider)
      end
    end

    @tag :integration
    test "and a shared asyncio event loop and submission helper are installed" do
      assert :ok = Python.install_async_runtime()

      {result, _} =
        Pythonx.eval(
          """
          import asyncio
          async def _add():
              return 40 + 2
          [hasattr(asyncio, '_gralkor_loop'), callable(asyncio._gralkor_run), asyncio._gralkor_run(_add())]
          """,
          %{}
        )

      assert Pythonx.decode(result) == [true, true, 42]
    end

    @tag :integration
    test "and reinstalling the loop leaves the installed loop in place" do
      assert :ok = Python.install_async_runtime()
      {before_id, _} = Pythonx.eval("import asyncio; id(asyncio._gralkor_loop)", %{})
      assert :ok = Python.install_async_runtime()
      {after_id, _} = Pythonx.eval("import asyncio; id(asyncio._gralkor_loop)", %{})
      assert Pythonx.decode(before_id) == Pythonx.decode(after_id)
    end
  end

  describe "when the Python runtime initialises > while the managed virtual environment is absent" do
    test "then it is materialised" do
      test_pid = self()

      assert {:ok, _} =
               Python.init(
                 reap_orphans: false,
                 uv_init: fn ->
                   send(test_pid, :materialised)
                   :ok
                 end,
                 smoke_import: fn -> :ok end,
                 install_loop: false
               )

      assert_receive :materialised
    end
  end

  describe "when the Python runtime initialises > while the embedded backend is configured" do
    test "then every process identified as its bundled server is killed before startup" do
      killed = :ets.new(:killed, [:public, :set])

      assert :ok =
               Python.reap_redislite_orphans(fn -> [1234, 5678] end, fn pid ->
                 :ets.insert(killed, {pid, true})
               end)

      assert :ets.lookup(killed, 1234) == [{1234, true}]
      assert :ets.lookup(killed, 5678) == [{5678, true}]
    end

    test "and only the first initialisation in a virtual machine sweeps for orphaned servers" do
      sweeps = :counters.new(1, [])
      killed = :ets.new(:killed, [:public, :set])

      boot = fn ->
        Python.init(
          reap_orphans: true,
          list_orphans: fn ->
            :counters.add(sweeps, 1, 1)
            [4321]
          end,
          kill_pid: fn pid -> :ets.insert(killed, {pid, true}) end,
          uv_init: fn -> :ok end,
          smoke_import: fn -> :ok end,
          install_loop: false
        )
      end

      assert {:ok, _} = boot.()
      :ets.delete_all_objects(killed)
      assert {:ok, _} = boot.()
      assert :counters.get(sweeps, 1) == 1
      assert :ets.lookup(killed, 4321) == []
    end
  end

  describe "when the Python runtime initialises > while the remote backend is configured" do
    test "then no orphaned-server sweep runs" do
      test_pid = self()

      assert {:ok, _} =
               Python.init(
                 reap_orphans: false,
                 list_orphans: fn -> send(test_pid, :listed) end,
                 kill_pid: fn _ -> send(test_pid, :killed) end,
                 uv_init: fn -> :ok end,
                 smoke_import: fn -> :ok end,
                 install_loop: false
               )

      refute_received :listed
      refute_received :killed
    end
  end

  describe "if an initialisation step fails" do
    test "then initialisation stops with that reason" do
      assert {:stop, {:boot_failed, {:uv_init, "boom"}}} =
               Python.init(
                 reap_orphans: false,
                 uv_init: fn -> {:error, {:uv_init, "boom"}} end,
                 smoke_import: fn -> :ok end,
                 install_loop: false
               )
    end
  end

  describe "if client smoke-import is requested for an unsupported provider" do
    test "then an error identifies that provider without calling the interpreter" do
      assert {:error, {:unsupported_provider, :anthropic}} =
               Python.smoke_import_provider_clients(:anthropic)
    end
  end
end
