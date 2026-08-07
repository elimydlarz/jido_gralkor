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

  See `test-trees/unit/graphiti-pool_TEST_TREES.md`.
  """

  use GenServer

  require Logger

  alias Gralkor.Client
  alias Gralkor.Config
  alias Gralkor.Interpret
  alias Gralkor.LearningEntity

  @default_table :gralkor_graphiti_instances

  # ── Public API ──────────────────────────────────────────────

  @spec replace_graph(
          GenServer.server(),
          String.t(),
          String.t(),
          :property_graph,
          Gralkor.Graph.property_graph()
        ) ::
          :ok | {:error, term()}
  def replace_graph(
        server \\ __MODULE__,
        group_id,
        lens_name,
        :property_graph,
        %{nodes: nodes, relationships: relationships}
      ) do
    instance = __MODULE__.for(server, group_id)

    Pythonx.eval(
      """
      import asyncio
      def text(value):
          return value.decode('utf-8') if isinstance(value, (bytes, bytearray)) else str(value)

      def get(mapping, key):
          return mapping.get(key, mapping.get(key.encode('utf-8')))

      def identifier(value):
          return '`' + text(value).replace('`', '``') + '`'

      owner = lens.decode('utf-8') if isinstance(lens, (bytes, bytearray)) else lens
      asyncio._gralkor_run(g.driver.execute_query(
          'MATCH ()-[relationship]->() '
          'WHERE relationship._gralkor_lens = $lens '
          'DELETE relationship',
          lens=owner,
      ))
      asyncio._gralkor_run(g.driver.execute_query(
          'MATCH (node) '
          'WHERE node._gralkor_lens = $lens '
          'DELETE node',
          lens=owner,
      ))
      for supplied_node in nodes:
          node_id = text(get(supplied_node, 'id'))
          labels = ''.join(':' + identifier(label) for label in get(supplied_node, 'labels'))
          supplied_properties = get(supplied_node, 'properties')
          properties = {text(key): value for key, value in supplied_properties.items()}
          properties['id'] = node_id
          properties['_gralkor_lens'] = owner
          asyncio._gralkor_run(g.driver.execute_query(
              f'CREATE (node{labels}) SET node = $properties',
              properties=properties,
          ))
      for supplied_relationship in relationships:
          source_id = text(get(supplied_relationship, 'from'))
          destination_id = text(get(supplied_relationship, 'to'))
          relationship_type = identifier(get(supplied_relationship, 'type'))
          supplied_properties = get(supplied_relationship, 'properties')
          properties = {text(key): value for key, value in supplied_properties.items()}
          properties['_gralkor_lens'] = owner
          asyncio._gralkor_run(g.driver.execute_query(
              'MATCH (source), (destination) '
              'WHERE source._gralkor_lens = $lens AND source.id = $source_id '
              'AND destination._gralkor_lens = $lens AND destination.id = $destination_id '
              f'CREATE (source)-[relationship:{relationship_type}]->(destination) '
              'SET relationship = $properties',
              lens=owner,
              source_id=source_id,
              destination_id=destination_id,
              properties=properties,
          ))
      None
      """,
      %{
        "g" => instance,
        "lens" => lens_name,
        "nodes" => nodes,
        "relationships" => relationships
      }
    )

    :ok
  rescue
    e in Pythonx.Error -> {:error, {:python, summarise_python_error(e)}}
  end

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
  Run graphiti's hybrid EDGE search against `group_id`. Returns
  `{:ok, [%{fact:, created_at:, valid_at:, invalid_at:, expired_at:}]}`
  ready for `Gralkor.Format.format_facts/1`.

  For retrieving custom-entity *nodes* (e.g. `Learning` for ERL recall) use
  `search_nodes/5` — edge search's node-label filtering matches edges by
  endpoint and misses standalone nodes.
  """
  @spec search(GenServer.server(), String.t(), String.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def search(server \\ __MODULE__, group_id, query, max_results)

  def search(server, group_id, query, max_results)
      when is_binary(group_id) and is_binary(query) and is_integer(max_results) and
             max_results > 0 do
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
        %{
          "g" => instance,
          "query" => query,
          "max_results" => max_results
        }
      )

    {:ok, raw |> Pythonx.decode() |> Enum.map(&atomize_keys/1)}
  rescue
    e in Pythonx.Error -> {:error, {:python, Exception.message(e)}}
  end

  @doc """
  Episode search against `group_id` via graphiti's `search_` with an
  episode-only config. Returns `{:ok, [%{content:, source_description:}]}` —
  the episode bodies as they were written.

  This is the primitive for content Gralkor wrote in a format it must read back
  verbatim (a generalisation's `GEN|v1|` envelope). Edge and node search both
  return what an extractor *derived* from an episode, which is a different text
  and may be nothing at all: an episode naming one subject yields a node and no
  edge, and neither carries the wire envelope. graphiti searches episodes by
  BM25 over their content, so retrieval here depends on the stored words rather
  than on an extraction.
  """
  @spec search_episodes(GenServer.server(), String.t(), String.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def search_episodes(server \\ __MODULE__, group_id, query, max_results)

  def search_episodes(server, group_id, query, max_results)
      when is_binary(group_id) and is_binary(query) and is_integer(max_results) and
             max_results > 0 do
    instance = __MODULE__.for(server, group_id)

    {raw, _} =
      Pythonx.eval(
        """
        import asyncio
        from graphiti_core.search.search_config import (
          EpisodeSearchConfig,
          EpisodeSearchMethod,
          SearchConfig,
        )
        from graphiti_core.search.search_filters import SearchFilters

        q = query.decode('utf-8') if isinstance(query, (bytes, bytearray)) else query
        gid = group_id.decode('utf-8') if isinstance(group_id, (bytes, bytearray)) else group_id
        config = SearchConfig(
          episode_config=EpisodeSearchConfig(search_methods=[EpisodeSearchMethod.bm25]),
          limit=max_results,
        )
        res = asyncio._gralkor_run(
          g.search_(q, config=config, group_ids=[gid], search_filter=SearchFilters())
        )
        [
          {"content": e.content, "source_description": e.source_description}
          for e in res.episodes
        ]
        """,
        %{
          "g" => instance,
          "query" => query,
          "group_id" => Client.sanitize_group_id(group_id),
          "max_results" => max_results
        }
      )

    {:ok, raw |> Pythonx.decode() |> Enum.map(&episode_map/1)}
  rescue
    e in Pythonx.Error -> {:error, {:python, Exception.message(e)}}
  end

  defp episode_map(%{} = m) do
    %{
      content: Map.get(m, "content"),
      source_description: Map.get(m, "source_description")
    }
  end

  @doc """
  Node search against `group_id` via graphiti's `search_` with the
  `NODE_HYBRID_SEARCH_RRF` recipe. Unlike `search/4` (which returns *edges* and
  whose `node_labels` filter matches edges by endpoint), this returns *nodes* —
  the right primitive for retrieving custom-entity nodes like `Learning`, which
  are not reliably reachable through edge search.

  Returns `{:ok, [%{name:, summary:, attributes:}]}` ordered by relevance.

  ## Options

    * `:node_labels` — optional `[String.t()]`. When present, a
      `SearchFilters(node_labels: …)` restricts results to nodes carrying one of
      those labels (e.g. `["Learning"]` for ERL recall). When absent, all nodes
      are eligible.
  """
  @spec search_nodes(GenServer.server(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def search_nodes(server \\ __MODULE__, group_id, query, max_results, opts \\ [])

  def search_nodes(server, group_id, query, max_results, opts)
      when is_binary(group_id) and is_binary(query) and is_integer(max_results) and
             max_results > 0 and
             is_list(opts) do
    instance = __MODULE__.for(server, group_id)
    node_labels = Keyword.get(opts, :node_labels)

    {raw, _} =
      Pythonx.eval(
        """
        import asyncio
        from graphiti_core.search.search_config_recipes import NODE_HYBRID_SEARCH_RRF
        from graphiti_core.search.search_filters import SearchFilters

        q = query.decode('utf-8') if isinstance(query, (bytes, bytearray)) else query
        gid = group_id.decode('utf-8') if isinstance(group_id, (bytes, bytearray)) else group_id
        labels = (
          [l.decode('utf-8') if isinstance(l, (bytes, bytearray)) else l for l in node_labels]
          if node_labels else None
        )
        sf = SearchFilters(node_labels=labels) if labels else SearchFilters()
        config = NODE_HYBRID_SEARCH_RRF.model_copy(deep=True)
        config.limit = max_results
        res = asyncio._gralkor_run(g.search_(q, config=config, group_ids=[gid], search_filter=sf))
        [
          {
            "name": n.name,
            "summary": n.summary,
            "attributes": {k: str(v) for k, v in (n.attributes or {}).items()},
          } for n in res.nodes
        ]
        """,
        %{
          "g" => instance,
          "query" => query,
          "group_id" => Client.sanitize_group_id(group_id),
          "max_results" => max_results,
          "node_labels" => node_labels
        }
      )

    {:ok, raw |> Pythonx.decode() |> Enum.map(&node_map/1)}
  rescue
    e in Pythonx.Error -> {:error, {:python, Exception.message(e)}}
  end

  defp node_map(%{} = m) do
    %{
      name: Map.get(m, "name"),
      summary: Map.get(m, "summary"),
      attributes: Map.get(m, "attributes") || %{}
    }
  end

  @doc """
  Ingest one episode (text content) into `group_id` via graphiti's
  `add_episode`. Auto-generates a unique episode `name`. When
  `ontology` is a module declared with `use Gralkor.Ontology`, its payload
  is materialised into graphiti's `entity_types`, `edge_types`,
  `edge_type_map`, and `excluded_entity_types` (cached per ontology module
  in the GenServer state).

  ## Options

    * `:uuid` — optional episode UUID forwarded to graphiti's `add_episode`.
      When given, graphiti fetches the existing episode and re-runs extraction
      against it (update path). When nil (default), graphiti generates a new
      UUID.
    * `:lens` — optional originating Lens name. It is appended to the episode's
      source description before the single graphiti `add_episode` call.
  """
  @spec add_episode(
          GenServer.server(),
          String.t(),
          String.t(),
          String.t(),
          module() | nil,
          keyword()
        ) ::
          :ok | {:error, term()}
  def add_episode(
        server \\ __MODULE__,
        group_id,
        content,
        source_description,
        ontology,
        opts \\ []
      )

  def add_episode(server, group_id, content, source_description, ontology, opts)
      when is_binary(group_id) and is_binary(content) and is_binary(source_description) and
             is_list(opts) do
    instance = __MODULE__.for(server, group_id)
    source_description = lens_source_description(source_description, Keyword.get(opts, :lens))

    name =
      "manual-add-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive, :monotonic])}"

    sanitized = Client.sanitize_group_id(group_id)
    merge_learning? = Keyword.get(opts, :merge_learning_entity, false)

    ontology_dicts =
      cond do
        ontology == nil and not merge_learning? ->
          nil

        ontology == nil and merge_learning? ->
          GenServer.call(server, {:materialise, nil, true}, :infinity)

        is_atom(ontology) ->
          GenServer.call(server, {:materialise, ontology, merge_learning?}, :infinity)
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
            uid = uuid.decode('utf-8') if isinstance(uuid, (bytes, bytearray)) else uuid
            kwargs['uuid'] = uid
        import sys
        try:
            asyncio._gralkor_run(g.add_episode(**kwargs))
        except BaseException as e:
            print(f"[gralkor] add_episode failed: {type(e).__name__}: {e}", file=sys.stderr)
            raise
        None
        """,
        %{
          "g" => instance,
          "content" => content,
          "source" => source_description,
          "name" => name,
          "group" => sanitized,
          "ontology_dicts" => ontology_dicts,
          "uuid" => uuid
        }
      )

    :ok
  rescue
    e in Pythonx.Error -> {:error, {:python, summarise_python_error(e)}}
  end

  defp lens_source_description(source_description, nil), do: source_description

  defp lens_source_description(source_description, lens) do
    "#{source_description} [lens: #{lens}]"
  end

  @doc """
  Remove an episode and its orphaned edges/nodes from the graph.

  Calls graphiti's `remove_episode(uuid)` which deletes the episode, its
  entity edges that were created by that episode, and any entity nodes
  referenced only by the deleted episode.
  """
  @spec remove_episode(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def remove_episode(server \\ __MODULE__, group_id, episode_uuid)
      when is_binary(group_id) and is_binary(episode_uuid) do
    instance = __MODULE__.for(server, group_id)

    Pythonx.eval(
      """
      import asyncio
      import sys
      uid = episode_uuid.decode('utf-8') if isinstance(episode_uuid, (bytes, bytearray)) else episode_uuid
      try:
          asyncio._gralkor_run(g.remove_episode(uid))
      except BaseException as e:
          print(f"[gralkor] remove_episode failed: {type(e).__name__}: {e}", file=sys.stderr)
          raise
      None
      """,
      %{"g" => instance, "episode_uuid" => episode_uuid}
    )

    :ok
  rescue
    e in Pythonx.Error -> {:error, {:python, summarise_python_error(e)}}
  end

  @doc """
  Rebuild indices and constraints across the whole graph.

  Every group is its own FalkorDB database, so "the whole graph" is every
  group this pool holds an instance for — rebuilding one group's database
  would leave every other group untouched. A group whose instance has not been
  created yet needs no rebuild: `initialise_instance/1` builds its indices the
  moment it is.
  """
  @spec build_indices(GenServer.server()) :: {:ok, %{status: String.t()}} | {:error, term()}
  def build_indices(server \\ __MODULE__) do
    server
    |> table_for()
    |> :ets.tab2list()
    |> Enum.each(fn {_group_id, instance} -> initialise_instance(instance) end)

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

  @doc """
  Build a compact one-line reason from a `Pythonx.Error`.

  `Exception.message/1` on a `Pythonx.Error` joins the *entire* Python
  traceback (every frame, every embedding vector echoed in a call line) into
  one multi-line blob. On a transient FalkorDB reset that blob — and the whole
  embedding search vector inside it — gets dumped to the log via the rescue's
  `{:error, {:python, reason}}`.

  The struct's `:lines` field is the output of Python's
  `traceback.format_exception(type, value, traceback)`: a list whose final
  non-blank entry is the `"ExceptionClass: message"` summary line. We take that
  one line — the error's class and message — and drop the frames entirely.
  """
  @spec summarise_python_error(Pythonx.Error.t()) :: String.t()
  def summarise_python_error(%Pythonx.Error{lines: lines}) when is_list(lines) do
    lines
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> case do
      nil -> "Python exception raised (no detail available)"
      line -> line
    end
  end

  @doc false
  @spec initialise_instance(any()) :: :ok
  def initialise_instance(instance) do
    Pythonx.eval(
      """
      import asyncio
      asyncio._gralkor_run(g.build_indices_and_constraints())
      """,
      %{"g" => instance}
    )

    :ok
  end

  # Each role — llm and embedder — picks its provider from its own spec, so an
  # OpenAI LLM alongside a Google embedder is a supported pair. The cross-encoder
  # has no spec of its own and follows the llm role.
  @supported_providers [:openai, :google]
  @credential_env %{openai: "OPENAI_API_KEY", google: "GOOGLE_API_KEY"}

  @doc false
  @spec supported_providers() :: [atom()]
  def supported_providers, do: @supported_providers

  @doc """
  Decide which provider builds each shared client, from the two configured model
  specs. Pure — no Pythonx, no credentials read — so the per-role dispatch is
  pinned deterministically and `default_construct_shared_clients/2` is left with
  nothing to decide.

  Each role takes its own spec's provider. The cross-encoder has no spec of its
  own and follows the llm role. A Google embedder carries `:batch_size` of 1;
  the OpenAI embedder takes no batch size at all, its client having no such
  parameter and no equivalent of the Gemini batching defect.
  """
  @spec shared_client_spec(map(), map()) :: %{
          llm: map(),
          embedder: map(),
          cross_encoder: map()
        }
  def shared_client_spec(llm_model, embedder_model) do
    %{
      llm: llm_spec(llm_model),
      embedder: embedder_spec(embedder_model),
      cross_encoder: %{provider: llm_model[:provider]}
    }
  end

  defp llm_spec(%{provider: :openai, id: id}) do
    reasoning =
      if String.starts_with?(id, ["gpt-5.5", "gpt-5.6"]), do: "none", else: "auto"

    %{provider: :openai, id: id, reasoning: reasoning}
  end

  defp llm_spec(llm_model) do
    %{provider: llm_model[:provider], id: llm_model[:id]}
  end

  # gemini-embedding-2-preview returns ONE embedding for N inputs in a single
  # call — graphiti's batched create_batch then fails with "zip() argument 2 is
  # shorter than argument 1". Force batch_size=1 so each input becomes its own
  # request. Filed upstream as getzep/graphiti#1467. OpenAI's embedder unpacks
  # result.data 1:1 and exposes no batch_size, so the workaround is Google-only.
  defp embedder_spec(%{provider: :google} = embedder_model) do
    %{provider: :google, id: embedder_model[:id], batch_size: 1}
  end

  defp embedder_spec(embedder_model) do
    %{provider: embedder_model[:provider], id: embedder_model[:id]}
  end

  @doc false
  @spec validate_native_models!(map(), map()) :: :ok
  def validate_native_models!(llm_model, embedder_model) do
    roles = [{"llm", llm_model}, {"embedder", embedder_model}]

    validate_supported_providers!(roles, llm_model, embedder_model)
    # Only a provider some role actually selected needs a credential — an unused
    # provider's absent key is not a misconfiguration.
    Enum.each(roles, &validate_credential!/1)

    :ok
  end

  defp validate_supported_providers!(roles, llm_model, embedder_model) do
    unless Enum.all?(roles, fn {_role, model} -> model[:provider] in @supported_providers end) do
      supported = Enum.map_join(@supported_providers, ", ", &inspect/1)

      raise ArgumentError,
            "Gralkor.GraphitiPool native Graphiti supports #{supported} models; " <>
              "got llm=#{inspect(llm_model)}, embedder=#{inspect(embedder_model)}"
    end

    :ok
  end

  defp validate_credential!({role, model}) do
    var = Map.fetch!(@credential_env, model[:provider])

    case System.get_env(var) do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          raise_missing_credential!(var, role, model)
        end

        :ok

      _ ->
        raise_missing_credential!(var, role, model)
    end
  end

  defp raise_missing_credential!(var, role, model) do
    raise ArgumentError,
          "Gralkor.GraphitiPool requires #{var} because the #{role} model spec " <>
            "#{inspect(model)} selects the #{inspect(model[:provider])} provider; " <>
            "set it, or configure a different provider for the #{role} role"
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

    validate_native_models!(llm_model, embedder_model)

    construct_falkor_db = Keyword.get(opts, :construct_falkor_db, &default_construct_falkor_db/1)

    close_falkor_db =
      Keyword.get_lazy(opts, :close_falkor_db, fn ->
        if Keyword.has_key?(opts, :construct_falkor_db) do
          fn _database -> :ok end
        else
          fn database -> default_close_falkor_db(database, falkordb_spec) end
        end
      end)

    construct_shared_clients =
      Keyword.get(opts, :construct_shared_clients, &default_construct_shared_clients/2)

    construct_instance = Keyword.get(opts, :construct_instance, &default_construct_instance/3)
    initialise_instance = Keyword.get(opts, :initialise_instance, &initialise_instance/1)
    warmup? = Keyword.get(opts, :warmup, true)
    install_loop_fn = Keyword.get(opts, :install_loop_fn, &Gralkor.Python.install_async_runtime/0)

    :ets.new(table, [:set, :public, :named_table, read_concurrency: true])
    register_table(self(), table)

    :ok = install_loop_fn.()

    shared = construct_shared_clients.(llm_model, embedder_model)

    case falkordb_spec do
      {:embedded, data_dir} ->
        File.mkdir_p!(data_dir)
        File.rm(Path.join(data_dir, "gralkor.db.settings"))

      {:remote, _opts} ->
        :ok
    end

    falkor_db = construct_falkor_db.(falkordb_spec)

    state = %{
      table: table,
      falkordb_spec: falkordb_spec,
      falkor_db: falkor_db,
      close_falkor_db: close_falkor_db,
      shared: shared,
      construct_instance: construct_instance,
      initialise_instance: initialise_instance,
      interpret_fn: interpret_fn,
      ontology_cache: %{}
    }

    if warmup?, do: do_warmup(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:create, sanitized_group_id}, _from, state) do
    instance =
      case :ets.lookup(state.table, sanitized_group_id) do
        [{^sanitized_group_id, existing}] ->
          existing

        [] ->
          fresh = construct_initialised_instance(state, sanitized_group_id)
          :ets.insert(state.table, {sanitized_group_id, fresh})
          fresh
      end

    {:reply, instance, state}
  end

  @impl true
  def handle_call({:materialise, module, merge_learning?}, _from, state) do
    cache_key = {module, merge_learning?}

    case Map.fetch(state.ontology_cache, cache_key) do
      {:ok, dicts} ->
        {:reply, dicts, state}

      :error ->
        payload =
          case module do
            nil -> nil
            mod when is_atom(mod) -> mod.__ontology__()
          end

        payload =
          if merge_learning?, do: LearningEntity.merge_ontology_payload(payload), else: payload

        dicts = build_ontology_dicts(payload)

        {:reply, dicts,
         %{state | ontology_cache: Map.put(state.ontology_cache, cache_key, dicts)}}
    end
  end

  # Backward-compatible single-arg form: no Learning merge. Keeps callers that
  # don't pass the flag on the pre-ERL path.
  def handle_call({:materialise, module}, from, state) do
    handle_call({:materialise, module, false}, from, state)
  end

  @impl true
  def terminate(_reason, state) do
    :ok = state.close_falkor_db.(state.falkor_db)
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

  defp spec_for_python(%{name: name, fields: fields} = spec) do
    base = %{
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

    case Map.get(spec, :description) do
      nil -> base
      description -> Map.put(base, "description", description)
    end
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
        desc_raw = get(spec, "description")
        description = decode(desc_raw) if desc_raw is not None else None
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
        if description:
            namespace["__doc__"] = description
        cls = type(name, (BaseModel,), namespace)
        classes[name] = cls
    classes
    """
  end

  # ── Defaults: real Pythonx-backed construction ──────────────

  defp default_construct_falkor_db({:embedded, data_dir}) do
    db_path = Path.join(data_dir, "gralkor.db")

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

  defp default_close_falkor_db(falkor_db, {:embedded, _data_dir}) do
    Pythonx.eval(
      """
      import asyncio
      async def close_embedded(database):
          client = database.client
          await client._client.aclose()
          sync_client = client._sync_client
          sync_client._async_managed = False
          sync_client._cleanup()
          client._async_managed = True
      asyncio._gralkor_run(close_embedded(database))
      """,
      %{"database" => falkor_db}
    )

    :ok
  end

  defp default_close_falkor_db(falkor_db, {:remote, _options}) do
    Pythonx.eval(
      """
      import asyncio
      asyncio._gralkor_run(database.aclose())
      """,
      %{"database" => falkor_db}
    )

    :ok
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
    spec = shared_client_spec(llm_model, embedder_model)

    # A Google role needs one shared genai.Client threaded through its
    # constructors; the OpenAI clients build their own AsyncOpenAI internally.
    genai_client = if :google in providers(spec), do: construct_genai_client()

    llm = construct_llm_client(spec.llm, genai_client)
    embedder = construct_embedder(spec.embedder, genai_client)
    cross_encoder = construct_cross_encoder(spec.cross_encoder, genai_client, llm)

    %{llm_client: llm, embedder: embedder, cross_encoder: cross_encoder}
  end

  defp providers(spec), do: [spec.llm.provider, spec.embedder.provider]

  @doc """
  The credential for `provider`, read on the Elixir side.

  Erlang's `os:putenv` keeps its own table and never reaches the C environment,
  so a credential set from Elixir — a consumer's `runtime.exs`, or the test
  helper loading `.env` — is invisible to the embedded interpreter's
  `os.environ`. Every client constructor therefore takes its key as an explicit
  argument rather than letting the Python client read the variable itself.

  Raises when the variable is absent; `validate_native_models!/2` has already
  proven it present for every provider a role selects.
  """
  @spec api_key!(atom()) :: String.t()
  def api_key!(provider), do: System.fetch_env!(Map.fetch!(@credential_env, provider))

  defp construct_genai_client do
    {client, _} =
      Pythonx.eval(
        """
        from google import genai
        k = api_key.decode('utf-8') if isinstance(api_key, (bytes, bytearray)) else api_key
        genai.Client(api_key=k)
        """,
        %{"api_key" => api_key!(:google)}
      )

    client
  end

  defp construct_llm_client(%{provider: :google, id: llm_name}, genai_client) do
    {llm, _} =
      Pythonx.eval(
        """
        from graphiti_core.llm_client.config import LLMConfig
        from graphiti_core.llm_client.gemini_client import GeminiClient
        ln = llm_name.decode('utf-8') if isinstance(llm_name, (bytes, bytearray)) else llm_name
        GeminiClient(config=LLMConfig(model=ln), client=client)
        """,
        %{"llm_name" => llm_name, "client" => genai_client}
      )

    llm
  end

  defp construct_llm_client(
         %{provider: :openai, id: llm_name, reasoning: reasoning},
         _genai_client
       ) do
    {llm, _} =
      Pythonx.eval(
        """
        from graphiti_core.llm_client.config import LLMConfig
        from graphiti_core.llm_client.openai_client import OpenAIClient
        ln = llm_name.decode('utf-8') if isinstance(llm_name, (bytes, bytearray)) else llm_name
        k = api_key.decode('utf-8') if isinstance(api_key, (bytes, bytearray)) else api_key
        r = reasoning.decode('utf-8') if isinstance(reasoning, (bytes, bytearray)) else reasoning
        OpenAIClient(config=LLMConfig(model=ln, api_key=k), reasoning=r)
        """,
        %{
          "llm_name" => llm_name,
          "api_key" => api_key!(:openai),
          "reasoning" => reasoning
        }
      )

    llm
  end

  # batch_size=1 is the Google-only workaround decided in shared_client_spec/2:
  # gemini-embedding-2-preview returns ONE embedding for N inputs, and graphiti's
  # batched create_batch then fails with "zip() argument 2 is shorter than
  # argument 1". Filed upstream as getzep/graphiti#1467 — drop it once the fix
  # lands and we've bumped past the affected version.
  defp construct_embedder(
         %{provider: :google, id: embedder_name, batch_size: batch_size},
         genai_client
       ) do
    {embedder, _} =
      Pythonx.eval(
        """
        from graphiti_core.embedder.gemini import GeminiEmbedder, GeminiEmbedderConfig
        en = embedder_name.decode('utf-8') if isinstance(embedder_name, (bytes, bytearray)) else embedder_name
        GeminiEmbedder(GeminiEmbedderConfig(embedding_model=en), client=client, batch_size=batch_size)
        """,
        %{"embedder_name" => embedder_name, "client" => genai_client, "batch_size" => batch_size}
      )

    embedder
  end

  # OpenAIEmbedder unpacks result.data 1:1 from a single batched call and takes
  # no batch_size parameter. It slices each vector to EmbedderConfig's
  # embedding_dim (1024 by default), which text-embedding-3's Matryoshka
  # training makes safe, but the truncation is silent — unlike Gemini, which
  # asks for the dimension explicitly via output_dimensionality.
  defp construct_embedder(%{provider: :openai, id: embedder_name}, _genai_client) do
    {embedder, _} =
      Pythonx.eval(
        """
        from graphiti_core.embedder.openai import OpenAIEmbedder, OpenAIEmbedderConfig
        en = embedder_name.decode('utf-8') if isinstance(embedder_name, (bytes, bytearray)) else embedder_name
        k = api_key.decode('utf-8') if isinstance(api_key, (bytes, bytearray)) else api_key
        OpenAIEmbedder(OpenAIEmbedderConfig(embedding_model=en, api_key=k))
        """,
        %{"embedder_name" => embedder_name, "api_key" => api_key!(:openai)}
      )

    embedder
  end

  defp construct_cross_encoder(%{provider: :google}, genai_client, _llm) do
    {cross_encoder, _} =
      Pythonx.eval(
        """
        from graphiti_core.cross_encoder.gemini_reranker_client import GeminiRerankerClient
        GeminiRerankerClient(client=client)
        """,
        %{"client" => genai_client}
      )

    cross_encoder
  end

  # Reusing the already-constructed OpenAIClient avoids re-authenticating: the
  # reranker unwraps it to the underlying AsyncOpenAI. Left without a model of
  # its own, it falls back to its own small classifier default rather than
  # forcing the main LLM model onto every rerank.
  defp construct_cross_encoder(%{provider: :openai}, _genai_client, llm) do
    {cross_encoder, _} =
      Pythonx.eval(
        """
        from graphiti_core.cross_encoder.openai_reranker_client import OpenAIRerankerClient
        OpenAIRerankerClient(client=llm_client)
        """,
        %{"llm_client" => llm}
      )

    cross_encoder
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

    case :ets.lookup(state.table, sanitized) do
      [{^sanitized, instance}] ->
        instance

      [] ->
        instance = construct_initialised_instance(state, sanitized)
        :ets.insert(state.table, {sanitized, instance})
        instance
    end
  end

  defp construct_initialised_instance(state, sanitized_group_id) do
    instance = state.construct_instance.(state.falkor_db, state.shared, sanitized_group_id)

    try do
      state.initialise_instance.(instance)
    rescue
      error in Pythonx.Error ->
        Logger.warning(
          "[gralkor] build_indices_and_constraints failed (non-fatal): #{summarise_python_error(error)}"
        )

      error ->
        Logger.warning(
          "[gralkor] build_indices_and_constraints failed (non-fatal): #{Exception.message(error)}"
        )
    catch
      kind, reason ->
        Logger.warning(
          "[gralkor] build_indices_and_constraints failed (non-fatal): #{kind}: #{inspect(reason)}"
        )
    end

    instance
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

  defp time_warmup_interpret(%{interpret_fn: nil}), do: {:ok, 0}

  defp time_warmup_interpret(%{interpret_fn: interpret_fn}) when is_function(interpret_fn, 2) do
    time(fn ->
      try do
        prompt = Interpret.build_interpretation_context([], "warmup", "- warmup", "warmup")

        case interpret_fn.(prompt, 2_000) do
          :ok -> :ok
          {:ok, _result} -> :ok
          {:error, _reason} = error -> error
          other -> {:error, {:unexpected_result, other}}
        end
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
