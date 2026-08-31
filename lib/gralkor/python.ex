defmodule Gralkor.Python do
  @moduledoc """
  PythonX runtime owner for the embedded Gralkor stack.

  Responsibilities, all in `init/1`:

    1. **Reap redislite orphans, once per VM.** `falkordblite` (loaded into
       PythonX in this BEAM) spawns a `redis-server` grandchild, which
       daemonises and is reparented to init — so nothing about a running
       server says which VM started it. A hard BEAM SIGKILL leaves it
       orphaned. SIGKILL anything matching `redislite/bin/redis-server`,
       but only on the first `Gralkor.Python` to boot in this VM: that is
       the one moment when every matching server predates us. A later sweep
       could only kill a live server this VM owns.

    2. **Materialise the venv + initialise the interpreter** via
       `Pythonx.uv_init/2` from the jido_gralkor-owned `@pyproject_toml`. This
       is what makes the embedded Python stack self-contained: the consumer
       (e.g. susu) configures nothing about Python — the graphiti-core pin is
       jido_gralkor's private detail. Guarded against re-init (the Pythonx NIF
       throws "already been initialized" on a second call) so multiple boots
       in one VM — as functional-test modules do — are safe.

    3. **Smoke-import `graphiti_core` and every supported provider client**
       through PythonX so any venv / import failure surfaces at boot rather
       than on the first real call.

  See `test-trees/unit/python-runtime_TEST_TREES.md`.
  """

  use GenServer

  require Logger

  @pyproject_path Path.join([__DIR__, "..", "..", "priv", "python", "pyproject.toml"])
  @external_resource @pyproject_path
  @pyproject_toml File.read!(@pyproject_path)

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    list_orphans = Keyword.get(opts, :list_orphans, &list_redislite_orphans/0)
    kill_pid = Keyword.get(opts, :kill_pid, &sigkill/1)
    uv_init = Keyword.get(opts, :uv_init, &ensure_initialised/0)
    smoke_import = Keyword.get(opts, :smoke_import, &smoke_import_graphiti/0)

    smoke_import_provider =
      Keyword.get(opts, :smoke_import_provider, &smoke_import_provider_clients/1)

    install_loop? = Keyword.get(opts, :install_loop, true)
    install_loop_fn = Keyword.get(opts, :install_loop_fn, &install_async_runtime/0)
    reap_orphans? = Keyword.get(opts, :reap_orphans, true)

    with :ok <- maybe_reap(reap_orphans?, list_orphans, kill_pid),
         :ok <- uv_init.(),
         :ok <- smoke_import.(),
         :ok <- smoke_import_supported_providers(smoke_import_provider),
         :ok <- maybe_install_loop(install_loop?, install_loop_fn) do
      {:ok, %{}}
    else
      {:error, reason} -> {:stop, {:boot_failed, reason}}
    end
  end

  defp maybe_reap(false, _list, _kill), do: :ok
  defp maybe_reap(true, list, kill), do: sweep_orphans_once(list, kill)

  @doc """
  Reap on the first sweep this VM performs, and nothing on any later one.

  Only the first `Gralkor.Python` to boot runs before this VM has started a
  server of its own, so every later sweep would be aiming at a live server we
  own — a daemonised, init-reparented `redis-server` does not identify which VM
  spawned it.
  """
  @spec sweep_orphans_once((-> [integer()]), (integer() -> any())) :: :ok
  def sweep_orphans_once(list_orphans, kill_pid)
      when is_function(list_orphans, 0) and is_function(kill_pid, 1) do
    if :persistent_term.get({__MODULE__, :swept}, false) do
      :ok
    else
      :persistent_term.put({__MODULE__, :swept}, true)
      reap_redislite_orphans(list_orphans, kill_pid)
    end
  end

  @doc """
  Materialise the uv-managed venv and initialise the PythonX interpreter from
  the jido_gralkor-owned `@pyproject_toml`. Idempotent within a VM: a flag in
  `:persistent_term` short-circuits the second call so we never hit the NIF's
  "already been initialized" guard when more than one `Gralkor.Python` boots.
  """
  @spec ensure_initialised() :: :ok | {:error, term()}
  def ensure_initialised do
    if :persistent_term.get({__MODULE__, :uv_inited}, false) do
      :ok
    else
      Pythonx.uv_init(@pyproject_toml)
      :persistent_term.put({__MODULE__, :uv_inited}, true)
      :ok
    end
  rescue
    e -> {:error, {:uv_init, Exception.message(e)}}
  end

  defp maybe_install_loop(false, _install_loop), do: :ok
  defp maybe_install_loop(true, install_loop), do: install_loop.()

  defp smoke_import_supported_providers(smoke_import_provider) do
    Enum.reduce_while(Gralkor.GraphitiPool.supported_providers(), :ok, fn provider, :ok ->
      case smoke_import_provider.(provider) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

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

  # One import block per provider the pool will accept, so a provider that
  # configuration admits can never fail later on a missing package. `openai`
  # arrives as an unconditional graphiti-core dependency; `google-genai` via the
  # extra named in priv/python/pyproject.toml.
  @provider_client_imports %{
    google: """
    from graphiti_core.llm_client.gemini_client import GeminiClient
    from graphiti_core.embedder.gemini import GeminiEmbedder
    from graphiti_core.cross_encoder.gemini_reranker_client import GeminiRerankerClient
    """,
    openai: """
    from graphiti_core.llm_client.openai_client import OpenAIClient
    from graphiti_core.embedder.openai import OpenAIEmbedder
    from graphiti_core.cross_encoder.openai_reranker_client import OpenAIRerankerClient
    """
  }

  @doc """
  Import the graphiti LLM, embedder, and reranker clients for `provider`.
  Returns `{:error, {:unsupported_provider, provider}}` for a provider the pool
  would refuse anyway.
  """
  @spec smoke_import_provider_clients(atom()) :: :ok | {:error, term()}
  def smoke_import_provider_clients(provider) do
    case Map.fetch(@provider_client_imports, provider) do
      {:ok, source} ->
        Pythonx.eval(source, %{})
        :ok

      :error ->
        {:error, {:unsupported_provider, provider}}
    end
  rescue
    e -> {:error, {:provider_client_import, provider, Exception.message(e)}}
  end

  # ── default OS plumbing ────────────────────────────────────

  defp list_redislite_orphans do
    case System.cmd("pgrep", ["-f", "redislite/bin/redis-server"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.to_integer(String.trim(&1)))

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
