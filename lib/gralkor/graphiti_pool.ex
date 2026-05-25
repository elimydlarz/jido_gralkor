defmodule Gralkor.GraphitiPool do
  @moduledoc """
  Per-group Graphiti instance cache, plus the gateway for graphiti operations.

  Holds one shared `AsyncFalkorDB` (the embedded redis-server child lives
  here) and lazily constructs one `Graphiti` instance per `group_id`. Cached
  in ETS for concurrent reads — `for/1` only hits the GenServer on a cache
  miss (i.e. the first time any caller asks for a given group). Once cached,
  thousands of callers can read the instance simultaneously without going
  through the GenServer.

  This is intentional. The spike (`pythonx-spike/LEARNINGS.md`) showed that
  Pythonx releases the GIL during graphiti's awaited I/O, so concurrent
  Elixir callers parallelise naturally. Serialising calls through a single
  GenServer would throw that away.

  See `ex-graphiti-pool` in `gralkor/TEST_TREES.md`.
  """

  use GenServer

  require Logger

  alias Gralkor.Client
  alias Gralkor.Config

  @default_table :gralkor_graphiti_instances

  # ── Public API ──────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Return the Graphiti instance for `group_id`, creating it on first use.

  Concurrent callers do not block each other once the instance is cached.
  Construction itself is serialised through the GenServer so two callers
  asking for the same group_id at the same time don't both construct it.
  """
  @spec for(GenServer.server(), String.t()) :: any()
  def for(server \\ __MODULE__, group_id) when is_binary(group_id) do
    sanitized = Client.sanitize_group_id(group_id)
    table = table_for(server)

    case :ets.lookup(table, sanitized) do
      [{^sanitized, instance}] -> instance
      [] -> GenServer.call(server, {:create, sanitized}, :infinity)
    end
  end

  @doc """
  Run graphiti's hybrid search against `group_id`. Returns
  `{:ok, [%{fact:, created_at:, valid_at:, invalid_at:, expired_at:}]}`
  ready for `Gralkor.Format.format_facts/1`.
  """
  @spec search(GenServer.server(), String.t(), String.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def search(server \\ __MODULE__, group_id, query, max_results)
      when is_binary(group_id) and is_binary(query) and is_integer(max_results) do
    instance = __MODULE__.for(server, group_id)

    {raw, _} =
      Pythonx.eval(
        """
        import asyncio
        q = query.decode('utf-8') if isinstance(query, (bytes, bytearray)) else query
        edges = asyncio._gralkor_run(g.search(q, num_results=max_results))
        [
          {
            "fact": e.fact,
            "created_at": str(e.created_at) if e.created_at else None,
            "valid_at": str(e.valid_at) if e.valid_at else None,
            "invalid_at": str(e.invalid_at) if e.invalid_at else None,
            "expired_at": str(e.expired_at) if e.expired_at else None,
          } for e in edges
        ]
        """,
        %{"g" => instance, "query" => query, "max_results" => max_results}
      )

    {:ok, raw |> Pythonx.decode() |> Enum.map(&atomize_keys/1)}
  rescue
    e in Pythonx.Error -> {:error, {:python, Exception.message(e)}}
  end

  @doc """
  Ingest one episode (text content) into `group_id` via graphiti's
  `add_episode`. Auto-generates `name` and `idempotency_key`. When
  `ontology` is a module declared with `use Gralkor.Ontology`, its payload
  is materialised into graphiti's `entity_types`, `edge_types`,
  `edge_type_map`, and `excluded_entity_types` (cached per ontology module
  in the GenServer state).

  ## Options

    * `:uuid` — optional episode UUID forwarded to graphiti's `add_episode`.
      When given, graphiti fetches the existing episode and re-runs extraction
      against it (update path). When nil (default), graphiti generates a new
      UUID.
  """
  @spec add_episode(GenServer.server(), String.t(), String.t(), String.t(), module() | nil, keyword()) ::
          :ok | {:error, term()}
  def add_episode(server \\ __MODULE__, group_id, content, source_description, ontology, opts \\ [])

  def add_episode(server, group_id, content, source_description, ontology, opts)
      when is_binary(group_id) and is_binary(content) and is_binary(source_description) and is_list(opts) do
    instance = __MODULE__.for(server, group_id)

    name = "manual-add-" <> Integer.to_string(System.system_time(:millisecond))
    idempotency_key = "key-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

    sanitized = Client.sanitize_group_id(group_id)

    ontology_dicts =
      case ontology do
        nil -> nil
        module when is_atom(module) -> GenServer.call(server, {:materialise, module}, :infinity)
      end

    uuid = Keyword.get(opts, :uuid)

    {_, _} =
      Pythonx.eval(
        """
        import asyncio
        from datetime import datetime, timezone
        from graphiti_core.nodes import EpisodeType
        c = content.decode('utf-8') if isinstance(content, (bytes, bytearray)) else content
        s = source.decode('utf-8') if isinstance(source, (bytes, bytearray)) else source
        n = name.decode('utf-8') if isinstance(name, (bytes, bytearray)) else name
        gid = group.decode('utf-8') if isinstance(group, (bytes, bytearray)) else group
        kwargs = dict(
          name=n,
          episode_body=c,
          source=EpisodeType.text,
          source_description=s,
          group_id=gid,
          reference_time=datetime.now(timezone.utc),
        )
        if ontology_dicts is not None:
            def _dec(x):
                return x.decode('utf-8') if isinstance(x, (bytes, bytearray)) else x
            for k, v in ontology_dicts.items():
                kwargs[_dec(k)] = [_dec(i) for i in v] if isinstance(v, list) else v
        if uuid is not None:
            kwargs['uuid'] = uuid
        import traceback, sys
        try:
            asyncio._gralkor_run(g.add_episode(**kwargs))
        except BaseException:
            print("[gralkor-debug] add_episode raised:", file=sys.stderr)
            traceback.print_exc()
            raise
        None
        """,
        %{
          "g" => instance,
          "content" => content,
          "source" => source_description,
          "name" => name,
          "group" => sanitized,
          "_idem" => idempotency_key,
          "ontology_dicts" => ontology_dicts,
          "uuid" => uuid
        }
      )

    :ok
  rescue
    e in Pythonx.Error -> {:error, {:python, Exception.message(e)}}
  end

  @doc "Build indices and constraints across the whole graph."
  @spec build_indices(GenServer.server()) :: {:ok, %{status: String.t()}} | {:error, term()}
  def build_indices(server \\ __MODULE__) do
    instance = __MODULE__.for(server, "default_db")

    {_, _} =
      Pythonx.eval(
        """
        import asyncio
        asyncio._gralkor_run(g.build_indices_and_constraints())
        None
        """,
        %{"g" => instance}
      )

    {:ok, %{status: "built"}}
  rescue
    e in Pythonx.Error -> {:error, {:python, Exception.message(e)}}
  end

  @doc "Build communities for `group_id`."
  @spec build_communities(GenServer.server(), String.t()) ::
          {:ok, %{communities: non_neg_integer(), edges: non_neg_integer()}} | {:error, term()}
  def build_communities(server \\ __MODULE__, group_id) when is_binary(group_id) do
    instance = __MODULE__.for(server, group_id)

    {raw, _} =
      Pythonx.eval(
        """
        import asyncio
        nodes, edges = asyncio._gralkor_run(g.build_communities())
        {"communities": len(nodes or []), "edges": len(edges or [])}
        """,
        %{"g" => instance}
      )

    decoded = Pythonx.decode(raw)
    {:ok, %{communities: decoded["communities"], edges: decoded["edges"]}}
  rescue
    e in Pythonx.Error -> {:error, {:python, Exception.message(e)}}
  end

  @fact_keys ~w(fact created_at valid_at invalid_at expired_at)a
  @fact_keys_strings Enum.map(@fact_keys, &Atom.to_string/1)

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if k in @fact_keys_strings, do: String.to_atom(k), else: k
      {key, v}
    end)
  end

  # ── GenServer ──────────────────────────────────────────────

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @default_table)
    falkordb_spec = Keyword.fetch!(opts, :falkordb_spec)
    llm_model = Keyword.get(opts, :llm_model, Config.llm_model())
    embedder_model = Keyword.get(opts, :embedder_model, Config.embedder_model())
    interpret_fn = Keyword.get(opts, :interpret_fn)

    construct_falkor_db = Keyword.get(opts, :construct_falkor_db, &default_construct_falkor_db/1)

    construct_shared_clients =
      Keyword.get(opts, :construct_shared_clients, &default_construct_shared_clients/2)

    construct_instance = Keyword.get(opts, :construct_instance, &default_construct_instance/3)
    warmup? = Keyword.get(opts, :warmup, true)
    install_loop_fn = Keyword.get(opts, :install_loop_fn, &Gralkor.Python.install_async_runtime/0)

    :ets.new(table, [:set, :public, :named_table, read_concurrency: true])
    register_table(self(), table)

    :ok = install_loop_fn.()

    shared = construct_shared_clients.(llm_model, embedder_model)

    falkor_db =
      case falkordb_spec do
        {:embedded, _} -> construct_falkor_db.(falkordb_spec)
        {:remote, _} -> nil
      end

    state = %{
      table: table,
      falkordb_spec: falkordb_spec,
      construct_falkor_db: construct_falkor_db,
      falkor_db: falkor_db,
      shared: shared,
      construct_instance: construct_instance,
      interpret_fn: interpret_fn,
      ontology_cache: %{}
    }

    if warmup?, do: do_warmup(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:create, sanitized_group_id}, _from, state) do
    instance =
      case state.falkordb_spec do
        {:embedded, _} ->
          case :ets.lookup(state.table, sanitized_group_id) do
            [{^sanitized_group_id, existing}] ->
              existing

            [] ->
              fresh = state.construct_instance.(state.falkor_db, state.shared, sanitized_group_id)
              :ets.insert(state.table, {sanitized_group_id, fresh})
              fresh
          end

        {:remote, _} ->
          falkor_db = state.construct_falkor_db.(state.falkordb_spec)
          state.construct_instance.(falkor_db, state.shared, sanitized_group_id)
      end

    {:reply, instance, state}
  end

  @impl true
  def handle_call({:materialise, module}, _from, state) do
    case Map.fetch(state.ontology_cache, module) do
      {:ok, dicts} ->
        {:reply, dicts, state}

      :error ->
        payload = module.__ontology__()
        dicts = build_ontology_dicts(payload)
        {:reply, dicts, %{state | ontology_cache: Map.put(state.ontology_cache, module, dicts)}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    unregister_table(self())
    :ets.delete(state.table)
    :ok
  end

  # ── Ontology materialisation ────────────────────────────────

  @doc """
  Pure projection from an `__ontology__/0` payload to the plain data handed
  across the Pythonx boundary. A graphiti `add_episode` kwarg
  (`entity_types`, `edge_types`, `edge_type_map`, `excluded_entity_types`) is
  populated iff its payload collection is present; the Pythonx side never
  re-decides inclusion, it materialises exactly what this spec carries. No
  Pythonx, no LLM — this is the deterministic contract the materialisation
  half trusts.
  """
  @spec graphiti_boundary_spec(map()) :: %{optional(atom()) => term()}
  def graphiti_boundary_spec(%{
        entity_types: entity_types,
        edge_types: edge_types,
        edge_type_map: edge_type_map,
        excluded_entity_types: excluded_entity_types
      }) do
    [
      {:entity_types, entity_types != [], Enum.map(entity_types, &spec_for_python/1)},
      {:edge_types, edge_types != [], Enum.map(edge_types, &spec_for_python/1)},
      {:edge_type_map, edge_type_map != [], Enum.map(edge_type_map, &edge_pair_for_python/1)},
      {:excluded_entity_types, excluded_entity_types != nil, excluded_entity_types}
    ]
    |> Enum.filter(fn {_key, present?, _value} -> present? end)
    |> Map.new(fn {key, _present?, value} -> {key, value} end)
  end

  defp build_ontology_dicts(payload) do
    payload
    |> graphiti_boundary_spec()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), materialise_boundary(key, value)} end)
  end

  defp materialise_boundary(key, specs) when key in [:entity_types, :edge_types] do
    {classes, _} = Pythonx.eval(ontology_build_script(), %{"specs" => specs})
    classes
  end

  defp materialise_boundary(:edge_type_map, pairs) do
    {dict, _} =
      Pythonx.eval(
        """
        def decode(value):
            return value.decode("utf-8") if isinstance(value, (bytes, bytearray)) else value

        def get(d, key):
            if key in d:
                return d[key]
            bkey = key.encode("utf-8")
            if bkey in d:
                return d[bkey]
            return None

        result = {}
        for entry in pairs:
            src = decode(get(entry, "src"))
            tgt = decode(get(entry, "dst"))
            names = [decode(n) for n in (get(entry, "names") or [])]
            result[(src, tgt)] = names
        result
        """,
        %{"pairs" => pairs}
      )

    dict
  end

  defp materialise_boundary(:excluded_entity_types, list), do: list

  defp spec_for_python(%{name: name, fields: fields}) do
    %{
      "name" => name,
      "fields" =>
        Enum.map(fields, fn %{name: fname, type: ftype, required: required, doc: doc} ->
          %{
            "name" => Atom.to_string(fname),
            "type" => Atom.to_string(ftype),
            "required" => required,
            "doc" => doc
          }
        end)
    }
  end

  defp edge_pair_for_python({{src, dst}, names}) do
    %{"src" => src, "dst" => dst, "names" => names}
  end

  defp ontology_build_script do
    """
    from typing import Optional
    from pydantic import BaseModel, Field

    type_map = {
        "string": str,
        "integer": int,
        "float": float,
        "boolean": bool,
    }

    def decode(value):
        return value.decode("utf-8") if isinstance(value, (bytes, bytearray)) else value

    def get(d, key):
        if key in d:
            return d[key]
        bkey = key.encode("utf-8")
        if bkey in d:
            return d[bkey]
        return None

    classes = {}
    for spec in specs:
        name = decode(get(spec, "name"))
        annotations = {}
        defaults = {}
        for f in (get(spec, "fields") or []):
            fname = decode(get(f, "name"))
            ftype_key = decode(get(f, "type"))
            py_type = type_map[ftype_key]
            required = bool(get(f, "required"))
            doc_raw = get(f, "doc")
            doc = decode(doc_raw) if doc_raw is not None else None
            if required:
                annotations[fname] = py_type
                defaults[fname] = Field(..., description=doc) if doc else Field(...)
            else:
                annotations[fname] = Optional[py_type]
                defaults[fname] = Field(default=None, description=doc) if doc else Field(default=None)
        namespace = {"__annotations__": annotations, **defaults}
        cls = type(name, (BaseModel,), namespace)
        classes[name] = cls
    classes
    """
  end

  # ── Defaults: real Pythonx-backed construction ──────────────

  defp default_construct_falkor_db({:embedded, data_dir}) do
    File.mkdir_p!(data_dir)
    db_path = Path.join(data_dir, "gralkor.db")
    # See `ex-graphiti-pool > embedded` in TEST_TREES.md and the contract
    # at gralkor/ts/server/tests/test_redislite_resume_trap.py.
    _ = File.rm(Path.join(data_dir, "gralkor.db.settings"))

    {db, _} =
      Pythonx.eval(
        """
        from redislite.async_falkordb_client import AsyncFalkorDB
        AsyncFalkorDB(db_path.decode('utf-8') if isinstance(db_path, (bytes, bytearray)) else db_path)
        """,
        %{"db_path" => db_path}
      )

    db
  end

  defp default_construct_falkor_db({:remote, kw}) do
    host = Keyword.fetch!(kw, :host)
    port = Keyword.fetch!(kw, :port)
    username = Keyword.get(kw, :username)
    password = Keyword.get(kw, :password)
    ssl = Keyword.get(kw, :ssl, false)

    {db, _} =
      Pythonx.eval(
        """
        from falkordb.asyncio import FalkorDB
        h = host.decode('utf-8') if isinstance(host, (bytes, bytearray)) else host
        u = username.decode('utf-8') if isinstance(username, (bytes, bytearray)) else username
        p = password.decode('utf-8') if isinstance(password, (bytes, bytearray)) else password
        FalkorDB(host=h, port=port, username=u, password=p, ssl=ssl)
        """,
        %{
          "host" => host,
          "port" => port,
          "username" => username,
          "password" => password,
          "ssl" => ssl
        }
      )

    db
  end

  defp default_construct_instance(falkor_db, shared, sanitized_group_id) do
    {instance, _} =
      Pythonx.eval(
        """
        import asyncio
        from graphiti_core import Graphiti
        from graphiti_core.driver.falkordb_driver import FalkorDriver
        gid = group_id.decode('utf-8') if isinstance(group_id, (bytes, bytearray)) else group_id
        driver = FalkorDriver(falkor_db=falkor_db, database=gid)
        g = Graphiti(
          graph_driver=driver,
          llm_client=llm_client,
          embedder=embedder,
          cross_encoder=cross_encoder,
        )
        # Build indices on this database so the first search can find anything.
        # FalkorDB indices are per-database; CREATE INDEX is idempotent so running
        # this every time we construct a fresh instance is cheap.
        import traceback, sys
        try:
            asyncio._gralkor_run(g.build_indices_and_constraints())
        except BaseException as e:
            # Best-effort — surface as a warning via the return value rather than
            # crashing instance construction.
            print(f"[gralkor] build_indices_and_constraints failed (non-fatal): {e}", file=sys.stderr)
            print("[gralkor-debug] traceback:", file=sys.stderr)
            traceback.print_exc()
        g
        """,
        %{
          "falkor_db" => falkor_db,
          "group_id" => sanitized_group_id,
          "llm_client" => Map.get(shared, :llm_client),
          "embedder" => Map.get(shared, :embedder),
          "cross_encoder" => Map.get(shared, :cross_encoder)
        }
      )

    instance
  end

  defp default_construct_shared_clients(llm_model, embedder_model) do
    %{provider: llm_provider, id: llm_name} = llm_model
    %{provider: embedder_provider, id: embedder_name} = embedder_model

    if llm_provider != :google or embedder_provider != :google do
      raise ArgumentError,
            "Gralkor.GraphitiPool currently only supports Google models; got llm=#{inspect(llm_model)}, embedder=#{inspect(embedder_model)}"
    end

    {client, _} = Pythonx.eval("from google import genai\ngenai.Client()\n", %{})

    {llm, _} =
      Pythonx.eval(
        """
        from graphiti_core.llm_client.config import LLMConfig
        from graphiti_core.llm_client.gemini_client import GeminiClient
        ln = llm_name.decode('utf-8') if isinstance(llm_name, (bytes, bytearray)) else llm_name
        GeminiClient(config=LLMConfig(model=ln), client=client)
        """,
        %{"llm_name" => llm_name, "client" => client}
      )

    # gemini-embedding-2-preview returns ONE embedding for N inputs in a single
    # call — graphiti's batched create_batch then fails with
    # "zip() argument 2 is shorter than argument 1". Force batch_size=1 so each
    # input becomes its own request. gemini-embedding-001 batches fine but
    # we set batch_size=1 uniformly so the call shape is identical regardless
    # of model choice.
    #
    # Filed upstream as getzep/graphiti#1467 — remove this workaround once the
    # fix lands and we've bumped past the affected version.
    {embedder, _} =
      Pythonx.eval(
        """
        from graphiti_core.embedder.gemini import GeminiEmbedder, GeminiEmbedderConfig
        en = embedder_name.decode('utf-8') if isinstance(embedder_name, (bytes, bytearray)) else embedder_name
        GeminiEmbedder(GeminiEmbedderConfig(embedding_model=en), client=client, batch_size=1)
        """,
        %{"embedder_name" => embedder_name, "client" => client}
      )

    {cross_encoder, _} =
      Pythonx.eval(
        """
        from graphiti_core.cross_encoder.gemini_reranker_client import GeminiRerankerClient
        GeminiRerankerClient(client=client)
        """,
        %{"client" => client}
      )

    %{llm_client: llm, embedder: embedder, cross_encoder: cross_encoder}
  end

  defp do_warmup(state) do
    t0 = System.monotonic_time(:millisecond)
    instance = ensure_warmup_instance(state)

    {search_result, search_ms} = time(fn -> warmup_search(instance) end)
    {interpret_result, interpret_ms} = time_warmup_interpret(state)

    Logger.info(
      "[gralkor] warmup — search:#{search_ms} interpret:#{interpret_ms} #{System.monotonic_time(:millisecond) - t0}ms"
    )

    case {search_result, interpret_result} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _} -> log_warmup_failure(:search, reason)
      {_, {:error, reason}} -> log_warmup_failure(:interpret, reason)
    end
  end

  defp ensure_warmup_instance(state) do
    sanitized = "warmup"

    case state.falkordb_spec do
      {:embedded, _} ->
        case :ets.lookup(state.table, sanitized) do
          [{^sanitized, instance}] ->
            instance

          [] ->
            instance = state.construct_instance.(state.falkor_db, state.shared, sanitized)
            :ets.insert(state.table, {sanitized, instance})
            instance
        end

      {:remote, _} ->
        falkor_db = state.construct_falkor_db.(state.falkordb_spec)
        state.construct_instance.(falkor_db, state.shared, sanitized)
    end
  end

  defp warmup_search(instance) do
    Pythonx.eval(
      """
      import asyncio
      asyncio._gralkor_run(g.search('warmup', num_results=1))
      """,
      %{"g" => instance}
    )

    :ok
  rescue
    e in Pythonx.Error -> {:error, Exception.message(e)}
  end

  defp time_warmup_interpret(%{interpret_fn: nil}), do: {0, :ok}

  defp time_warmup_interpret(%{interpret_fn: interpret_fn}) when is_function(interpret_fn, 2) do
    time(fn ->
      try do
        interpret_fn.("Conversation context:\n\n\nMemory facts to interpret:\n- warmup", 2_000)
        :ok
      rescue
        e -> {:error, Exception.message(e)}
      end
    end)
  end

  defp time(fun) do
    t0 = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - t0}
  end

  defp log_warmup_failure(stage, reason) do
    Logger.warning("[gralkor] warmup failed (non-fatal) — #{stage}: #{inspect(reason)}")
    :ok
  end

  # ── Per-server table lookup ─────────────────────────────────
  # When tests start unnamed pools, the ETS table name is per-instance.
  # We map server pid → table via the process dictionary of the GenServer
  # (looked up via `:sys.get_state` is too heavy; use a tiny ETS table).

  @registry :gralkor_graphiti_pool_registry

  defp ensure_registry do
    if :ets.whereis(@registry) == :undefined do
      :ets.new(@registry, [:set, :public, :named_table])
    end

    @registry
  end

  defp register_table(pid, table) do
    ensure_registry()
    :ets.insert(@registry, {pid, table})
  end

  defp unregister_table(pid) do
    ensure_registry()
    :ets.delete(@registry, pid)
  end

  defp table_for(server) when is_atom(server) do
    @default_table
  end

  defp table_for(server) when is_pid(server) do
    ensure_registry()

    case :ets.lookup(@registry, server) do
      [{^server, table}] -> table
      [] -> @default_table
    end
  end
end
