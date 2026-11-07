defmodule Gralkor.PythonTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Gralkor.Python

  setup do
    key = {Python, :swept}

    previous =
      case :persistent_term.get(key, :__missing__) do
        :__missing__ -> :missing
        value -> {:present, value}
      end

    :persistent_term.erase(key)

    on_exit(fn ->
      case previous do
        :missing -> :persistent_term.erase(key)
        {:present, value} -> :persistent_term.put(key, value)
      end
    end)

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
                 smoke_import_provider: fn _provider -> :ok end,
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

    test "and the packaged manifest keeps the Google provider package below the release that stopped installing httpx, which the graph library imports" do
      manifest = File.read!(Path.expand("../../priv/python/pyproject.toml", __DIR__))

      assert manifest =~ ~r/^\s*"google-genai<3",?\s*$/m
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

    test "and the managed environment is materialised from the packaged manifest" do
      test_pid = self()
      initialised = {Python, :uv_inited}
      previous = :persistent_term.get(initialised, :__missing__)
      :persistent_term.erase(initialised)

      on_exit(fn ->
        case previous do
          :__missing__ -> :persistent_term.erase(initialised)
          value -> :persistent_term.put(initialised, value)
        end
      end)

      assert {:ok, _} =
               Python.init(
                 reap_orphans: false,
                 uv_init: fn ->
                   Python.ensure_initialised(fn manifest ->
                     send(test_pid, {:materialised, manifest})
                   end)
                 end,
                 smoke_import: fn -> :ok end,
                 smoke_import_provider: fn _provider -> :ok end,
                 install_loop: false
               )

      packaged_manifest = File.read!(Path.expand("../../priv/python/pyproject.toml", __DIR__))
      assert_receive {:materialised, ^packaged_manifest}
    end
  end

  describe "when the Python runtime initialises > while orphan reaping is requested" do
    test "then every process identified as its bundled server is killed before startup" do
      test_pid = self()

      assert {:ok, _} =
               Python.init(
                 reap_orphans: true,
                 list_orphans: fn -> [1234, 5678] end,
                 kill_pid: fn pid -> send(test_pid, {:killed, pid}) end,
                 uv_init: fn ->
                   send(test_pid, :uv_init)
                   :ok
                 end,
                 smoke_import: fn -> :ok end,
                 smoke_import_provider: fn _provider -> :ok end,
                 install_loop: false
               )

      assert {:messages, [{:killed, 1234}, {:killed, 5678}, :uv_init]} =
               Process.info(self(), :messages)
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
          smoke_import_provider: fn _provider -> :ok end,
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

  describe "when the Python runtime initialises > while orphan reaping is not requested" do
    test "then no orphaned-server sweep runs" do
      test_pid = self()

      assert {:ok, _} =
               Python.init(
                 reap_orphans: false,
                 list_orphans: fn -> send(test_pid, :listed) end,
                 kill_pid: fn _ -> send(test_pid, :killed) end,
                 uv_init: fn -> :ok end,
                 smoke_import: fn -> :ok end,
                 smoke_import_provider: fn _provider -> :ok end,
                 install_loop: false
               )

      refute_received :listed
      refute_received :killed
    end
  end

  describe "when a coroutine is run on the shared loop" do
    setup :install_shared_loop

    test "then the caller receives the coroutine's result" do
      result =
        Python.run_coroutine(
          """
          async def add():
              return 40 + left
          add()
          """,
          %{"left" => 2}
        )

      assert Pythonx.decode(result) == 42
    end
  end

  describe "when a coroutine is run on the shared loop > while more coroutines are awaiting than the virtual machine has dirty CPU schedulers" do
    setup :install_shared_loop

    test "then another interpreter call completes without waiting for them" do
      {gate, _} = Pythonx.eval("import asyncio\nasyncio.Event()", %{})
      {state, _} = Pythonx.eval("{'awaiting': 0}", %{})
      awaiting = :erlang.system_info(:dirty_cpu_schedulers) + 1

      waiters =
        for _ <- 1..awaiting do
          Task.async(fn ->
            Python.run_coroutine(
              """
              async def await_gate():
                  state['awaiting'] += 1
                  await gate.wait()
                  return 'released'
              await_gate()
              """,
              %{"gate" => gate, "state" => state}
            )
          end)
        end

      assert_eventually(fn -> promptly_eval("state['awaiting']", %{"state" => state}) end, awaiting)

      assert Pythonx.decode(promptly_eval("1 + 1", %{})) == 2

      Pythonx.eval("import asyncio\nasyncio._gralkor_loop.call_soon_threadsafe(gate.set)", %{
        "gate" => gate
      })

      assert waiters |> Task.await_many(5_000) |> Enum.map(&Pythonx.decode/1) ==
               List.duplicate("released", awaiting)
    end
  end

  describe "when a coroutine is run on the shared loop > if the coroutine raises" do
    setup :install_shared_loop

    test "then the caller receives that Python error" do
      error =
        assert_raise Pythonx.Error, fn ->
          Python.run_coroutine(
            """
            async def fail():
                raise ValueError('broken graph')
            fail()
            """,
            %{}
          )
        end

      assert Exception.message(error) =~ "ValueError: broken graph"
    end
  end

  describe "when a coroutine is run on the shared loop > if the coroutine outlasts the graph operation deadline" do
    setup :install_shared_loop

    test "then the caller receives a timeout error naming the deadline" do
      :ok = Python.install_async_runtime(100)

      error =
        assert_raise Pythonx.Error, fn ->
          Python.run_coroutine("import asyncio\nasyncio.Event().wait()", %{})
        end

      assert Exception.message(error) =~ "TimeoutError: graph operation exceeded its 0.1s deadline"
    end

    test "and the coroutine is cancelled" do
      :ok = Python.install_async_runtime(100)
      {state, _} = Pythonx.eval("{'cancelled': False}", %{})

      assert_raise Pythonx.Error, fn ->
        Python.run_coroutine(hanging_coroutine(), %{"state" => state})
      end

      assert Pythonx.decode(promptly_eval("state['cancelled']", %{"state" => state}))
    end
  end

  describe "when a coroutine is run on the shared loop > if the caller exits while the coroutine awaits" do
    setup :install_shared_loop

    test "then the coroutine is still cancelled at the graph operation deadline" do
      :ok = Python.install_async_runtime(300)
      {state, _} = Pythonx.eval("{'started': False, 'cancelled': False}", %{})

      caller = spawn(fn -> Python.run_coroutine(hanging_coroutine(), %{"state" => state}) end)

      assert_eventually(fn -> promptly_eval("state['started']", %{"state" => state}) end, true)
      Process.exit(caller, :kill)
      refute Pythonx.decode(promptly_eval("state['cancelled']", %{"state" => state}))

      assert_eventually(fn -> promptly_eval("state['cancelled']", %{"state" => state}) end, true)
    end
  end

  describe "if an initialisation step fails" do
    test "then initialisation stops with that reason" do
      first_provider = hd(Gralkor.GraphitiPool.supported_providers())

      failures = [
        {[uv_init: fn -> {:error, {:uv_init, "boom"}} end], {:uv_init, "boom"}},
        {[smoke_import: fn -> {:error, {:graphiti_import, "boom"}} end],
         {:graphiti_import, "boom"}},
        {[
           smoke_import_provider: fn provider ->
             {:error, {:provider_client_import, provider, "boom"}}
           end
         ], {:provider_client_import, first_provider, "boom"}},
        {[
           install_loop_fn: fn -> {:error, {:install_async_runtime, "boom"}} end
         ], {:install_async_runtime, "boom"}}
      ]

      Enum.each(failures, fn {override, expected_reason} ->
        opts =
          Keyword.merge(
            [
              reap_orphans: false,
              uv_init: fn -> :ok end,
              smoke_import: fn -> :ok end,
              smoke_import_provider: fn _provider -> :ok end,
              install_loop: true,
              install_loop_fn: fn -> :ok end
            ],
            override
          )

        assert {:stop, {:boot_failed, ^expected_reason}} = Python.init(opts)
      end)
    end
  end

  describe "if client smoke-import is requested for an unsupported provider" do
    test "then an error identifies that provider without calling the interpreter" do
      assert {:error, {:unsupported_provider, :anthropic}} =
               Python.smoke_import_provider_clients(:anthropic)
    end
  end

  defp install_shared_loop(_context) do
    :ok = Python.install_async_runtime()
    on_exit(fn -> Python.install_async_runtime() end)
    :ok
  end

  defp hanging_coroutine do
    """
    import asyncio
    async def hang():
        state['started'] = True
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            state['cancelled'] = True
            raise
    hang()
    """
  end

  defp promptly_eval(code, globals) do
    task = Task.async(fn -> Pythonx.eval(code, globals) end)

    case Task.yield(task, 2_000) do
      {:ok, {result, _globals}} -> result
      nil -> flunk("interpreter call did not complete within 2s: #{code}")
    end
  end

  defp assert_eventually(read, expected, attempts \\ 100) do
    actual = Pythonx.decode(read.())

    cond do
      actual == expected ->
        :ok

      attempts > 1 ->
        Process.sleep(20)
        assert_eventually(read, expected, attempts - 1)

      true ->
        flunk("expected #{inspect(expected)}, last read #{inspect(actual)}")
    end
  end
end
