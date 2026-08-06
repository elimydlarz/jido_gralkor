defmodule Gralkor.PythonTest do
  use ExUnit.Case, async: false

  alias Gralkor.Python

  setup do
    :persistent_term.erase({Python, :swept})
    :ok
  end

  describe "when the Python runtime is initialised > while an embedded connection is configured" do
    test "and only the first initialisation in a virtual machine sweeps, so a later one cannot kill a server this virtual machine has already started" do
      sweeps = :counters.new(1, [])

      list_orphans = fn ->
        :counters.add(sweeps, 1, 1)
        [4321]
      end

      killed = :ets.new(:killed, [:public, :set])
      kill_pid = fn pid -> :ets.insert(killed, {pid, true}) end

      boot = fn ->
        Python.init(
          reap_orphans: true,
          list_orphans: list_orphans,
          kill_pid: kill_pid,
          uv_init: fn -> :ok end,
          smoke_import: fn -> :ok end,
          install_loop: false
        )
      end

      assert {:ok, _} = boot.()
      assert :ets.lookup(killed, 4321) == [{4321, true}]

      :ets.delete_all_objects(killed)

      assert {:ok, _} = boot.()

      assert :counters.get(sweeps, 1) == 1
      assert :ets.lookup(killed, 4321) == []
    end

    test "then any process whose arguments identify the embedded backend's bundled server is killed first, so a server orphaned by a hard virtual-machine exit cannot survive" do
      list_orphans = fn -> [1234, 5678] end
      killed = :ets.new(:killed, [:public, :set])
      kill_pid = fn pid -> :ets.insert(killed, {pid, true}) end

      assert :ok = Python.reap_redislite_orphans(list_orphans, kill_pid)

      assert :ets.lookup(killed, 1234) == [{1234, true}]
      assert :ets.lookup(killed, 5678) == [{5678, true}]
    end

  end

  describe "when the Python runtime is initialised > while a remote connection is configured" do
    test "then no orphaned-server sweep runs" do
      called = :counters.new(1, [])

      list_orphans = fn ->
        :counters.add(called, 1, 1)
        []
      end

      kill_pid = fn _pid ->
        :counters.add(called, 1, 1)
        :ok
      end

      assert {:ok, _} =
               Python.init(
                 reap_orphans: false,
                 list_orphans: list_orphans,
                 kill_pid: kill_pid,
                 uv_init: fn -> :ok end,
                 smoke_import: fn -> :ok end,
                 install_loop: false
               )

      assert :counters.get(called, 1) == 0
    end
  end

  describe "when the Python runtime is initialised" do
    test "then initialisation runs to completion synchronously and returns only once the runtime is ready" do
      order = :ets.new(:order, [:public, :ordered_set])
      seq = :counters.new(1, [])

      record = fn step ->
        :counters.add(seq, 1, 1)
        :ets.insert(order, {:counters.get(seq, 1), step})
      end

      assert {:ok, _} =
               Python.init(
                 reap_orphans: true,
                 list_orphans: fn ->
                   record.(:reap)
                   []
                 end,
                 kill_pid: fn _ -> :ok end,
                 uv_init: fn ->
                   record.(:uv_init)
                   :ok
                 end,
                 smoke_import: fn ->
                   record.(:smoke_import)
                   :ok
                 end,
                 install_loop: false
               )

      steps = order |> :ets.tab2list() |> Enum.map(fn {_, step} -> step end)
      assert steps == [:reap, :uv_init, :smoke_import]
    end

    test "and the package's manifest declares the graph library, the embedded FalkorDB backend, and the provider packages for every supported inference provider, so a consumer configures nothing about Python" do
      manifest = File.read!(Path.expand("../../priv/python/pyproject.toml", __DIR__))

      assert manifest =~ "graphiti-core[falkordb,google-genai]"
      assert manifest =~ "falkordblite"
      assert manifest =~ "OpenAI LLM, embedder, and reranker"
    end

    test "and the package's manifest is a compile-time external resource, so editing its dependency set triggers recompilation" do
      manifest_path = Path.expand("../../priv/python/pyproject.toml", __DIR__)
      assert manifest_path in Python.__info__(:attributes)[:external_resource]
    end
  end

  describe "when the Python runtime is initialised > while the managed virtual environment is absent" do
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

  describe "if any initialisation step fails" do
    test "then initialisation stops with the reason, so the supervisor restarts it and a permanent failure eventually exits the virtual machine" do
      assert {:stop, {:boot_failed, {:uv_init, "boom"}}} =
               Python.init(
                 reap_orphans: false,
                 uv_init: fn -> {:error, {:uv_init, "boom"}} end,
                 smoke_import: fn -> :ok end,
                 install_loop: false
               )
    end
  end

  describe "when the Python runtime is initialised" do
    @describetag :integration

    test "and a smoke import of the graph library succeeds" do
      assert :ok = Python.smoke_import_graphiti()
    end

    test "and the provider client for each supported inference provider imports successfully, so an unsupported provider selection fails on its configuration rather than on a missing package" do
      assert :ok = Python.smoke_import_graphiti()

      for provider <- Gralkor.GraphitiPool.supported_providers() do
        assert :ok == Python.smoke_import_provider_clients(provider)
      end
    end
  end

  describe "when the Python runtime is initialised" do
    @describetag :integration

    test "and a second initialisation in the same virtual machine short-circuits, so repeated boots cannot trip the interpreter's already-initialised guard" do
      assert :persistent_term.get({Python, :uv_inited}, false) == true
      assert :ok = Python.ensure_initialised()
    end
  end

  describe "when the Python runtime is initialised" do
    @describetag :integration

    test "and a shared asyncio event loop is installed on a daemon thread together with a helper that submits work onto it" do
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

    test "and re-invoking the loop installation leaves the already-installed loop in place" do
      assert :ok = Python.install_async_runtime()

      {before_id, _} = Pythonx.eval("import asyncio; id(asyncio._gralkor_loop)", %{})

      assert :ok = Python.install_async_runtime()

      {after_id, _} = Pythonx.eval("import asyncio; id(asyncio._gralkor_loop)", %{})

      assert Pythonx.decode(before_id) == Pythonx.decode(after_id)
    end
  end

  describe "if a caller asks to smoke-import clients for an unsupported provider" do
    test "then the error identifies that unsupported provider without calling the interpreter" do
      assert {:error, {:unsupported_provider, :anthropic}} =
               Python.smoke_import_provider_clients(:anthropic)
    end
  end
end
