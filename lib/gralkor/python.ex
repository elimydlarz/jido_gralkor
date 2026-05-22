defmodule Gralkor.Python do
  @moduledoc """
  PythonX runtime owner for the embedded Gralkor stack.

  Two responsibilities, both in `init/1`:

    1. **Reap redislite orphans.** `falkordblite` (loaded into PythonX in this
       BEAM) spawns a `redis-server` grandchild. A hard BEAM SIGKILL leaves
       it orphaned. SIGKILL anything matching `redislite/bin/redis-server`
       before we boot — safe because this runs *before* our own Python init,
       so anything matching is by definition not ours-yet, and the path is
       unique to falkordblite.

    2. **Smoke-import `graphiti_core`** through PythonX so any venv / import
       failure surfaces at boot rather than on the first real call.

    Pythonx's interpreter + venv materialisation are configured in
    `config/config.exs` via `:pythonx, :uv_init` and start automatically with
    the `:pythonx` OTP application; `Gralkor.Python` does not duplicate that
    work.

  See `ex-python-runtime` in `gralkor/TEST_TREES.md`.
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    list_orphans = Keyword.get(opts, :list_orphans, &list_redislite_orphans/0)
    kill_pid = Keyword.get(opts, :kill_pid, &sigkill/1)
    smoke_import = Keyword.get(opts, :smoke_import, &smoke_import_graphiti/0)
    install_loop? = Keyword.get(opts, :install_loop, true)
    reap_orphans? = Keyword.get(opts, :reap_orphans, true)

    with :ok <- maybe_reap(reap_orphans?, list_orphans, kill_pid),
         :ok <- smoke_import.(),
         :ok <- maybe_install_loop(install_loop?) do
      {:ok, %{}}
    else
      {:error, reason} -> {:stop, {:boot_failed, reason}}
    end
  end

  defp maybe_reap(false, _list, _kill), do: :ok
  defp maybe_reap(true, list, kill), do: reap_redislite_orphans(list, kill)

  defp maybe_install_loop(false), do: :ok
  defp maybe_install_loop(true), do: install_async_runtime()

  @doc """
  Spin up a daemon-thread asyncio event loop and stash it on `asyncio` as
  `_gralkor_loop` plus a `_gralkor_run(coro)` helper that submits onto it.

  Must run once per Pythonx interpreter, before any code that calls into
  graphiti via `asyncio._gralkor_run`. Idempotent — the second call is a
  no-op.

  Why: Pythonx.eval creates a fresh event loop per `asyncio.run` call.
  AsyncFalkorDB (and any redis-async connection) binds its connections to
  the loop they were created on; reusing them on a different loop raises
  "Future attached to a different loop". The spike measured the alternative
  pattern (Step 6 in `pythonx-spike/spike.exs`) at ~56µs per call vs ~112µs
  for `asyncio.run` — and, crucially, it shares one loop across all calls
  so connection reuse works.
  """
  @spec install_async_runtime() :: :ok | {:error, term()}
  def install_async_runtime do
    Pythonx.eval(
      """
      import asyncio, threading
      if not hasattr(asyncio, '_gralkor_loop'):
          loop = asyncio.new_event_loop()
          started = threading.Event()
          def _run():
              asyncio.set_event_loop(loop)
              started.set()
              loop.run_forever()
          threading.Thread(target=_run, daemon=True).start()
          started.wait()
          asyncio._gralkor_loop = loop
          asyncio._gralkor_run = lambda coro: asyncio.run_coroutine_threadsafe(coro, loop).result()
      """,
      %{}
    )

    :ok
  rescue
    e in Pythonx.Error -> {:error, {:install_async_runtime, Exception.message(e)}}
  end

  @doc """
  SIGKILL every pid the listing function returns. Pure plumbing — accepts
  injected list/kill functions so the unit test doesn't have to spawn real
  redis processes.
  """
  @spec reap_redislite_orphans((-> [integer()]), (integer() -> any())) :: :ok | {:error, term()}
  def reap_redislite_orphans(list_orphans, kill_pid)
      when is_function(list_orphans, 0) and is_function(kill_pid, 1) do
    Enum.each(list_orphans.(), fn pid ->
      Logger.warning("[gralkor] reaping redislite orphan pid #{pid}")
      kill_pid.(pid)
    end)

    :ok
  end

  @doc """
  Try to `import graphiti_core` via Pythonx; surface any failure as
  `{:error, _}`.
  """
  @spec smoke_import_graphiti() :: :ok | {:error, term()}
  def smoke_import_graphiti do
    Pythonx.eval("import graphiti_core", %{})
    :ok
  rescue
    e -> {:error, {:graphiti_import, Exception.message(e)}}
  end

  # ── default OS plumbing ────────────────────────────────────

  defp list_redislite_orphans do
    case System.cmd("pgrep", ["-af", "redislite/bin/redis-server"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          [pid_str | _] = String.split(line, " ", parts: 2)
          String.to_integer(pid_str)
        end)

      {_, _} ->
        # pgrep exits non-zero when nothing matches — that's fine.
        []
    end
  end

  defp sigkill(pid) do
    System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
    :ok
  end
end
