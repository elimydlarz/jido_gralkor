defmodule Gralkor.GraphitiPool do
  @moduledoc """
  Per-group Graphiti instance cache, plus the gateway for graphiti operations.

  Holds one shared `AsyncFalkorDB` (the embedded redis-server child lives
  here) and lazily constructs one `Graphiti` instance per `group_id`. Cached
  in ETS for concurrent reads — `for/1` only hits the GenServer on a cache
  miss (i.e. the first time any caller asks for a given group). Once cached,
  thousands of callers can read the instance simultaneously without going
  through the GenServer.

  Pythonx releases the GIL during graphiti's awaited I/O, so searches and
  remote operations parallelise naturally. Embedded `add_episode` calls alone
  use monitored admission through the GenServer because every group shares one
  locally owned Redis connection; searches do not enter that queue.

  See `test-trees/unit/graphiti-pool_TEST_TREES.md`.
  """

  use GenServer

  require Logger

  alias Gralkor.Client

  @provenance_extraction_instructions """
  Preserve source attribution and epistemic wording in extracted facts. Retain uncertainty,
  speculation, proposals, opinions, and reported claims instead of rewriting them as categorical
  facts. Include the speaker or document attribution when it is needed to preserve that distinction.
  """
  alias Gralkor.Config

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

      def native(value):
          if isinstance(value, (bytes, bytearray)):
              return value.decode('utf-8')
          if isinstance(value, dict):
              return {text(key): native(item) for key, item in value.items()}
          if isinstance(value, (list, tuple)):
              return [native(item) for item in value]
          return value

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
          properties = native(supplied_properties)
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
          properties = native(supplied_properties)
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
  whose individual entries can be rendered by `Gralkor.Format.format_fact/1`.

  For retrieving custom-entity *nodes*, use `search_nodes/5` — edge search's
  node-label filtering matches edges by endpoint and misses standalone nodes.
  """
  @spec search(GenServer.server(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def search(server \\ __MODULE__, group_id, query, max_results, opts \\ [])

  def search(server, group_id, query, max_results, opts)
      when is_binary(group_id) and is_binary(query) and is_integer(max_results) and
             max_results > 0 and is_list(opts) do
    instance = __MODULE__.for(server, group_id)
    edge_types = Keyword.get(opts, :edge_types)

    {raw, _} =
      Pythonx.eval(
        """
        import asyncio
        from graphiti_core.nodes import EpisodicNode
        from graphiti_core.search.search_filters import SearchFilters

        q = query.decode('utf-8') if isinstance(query, (bytes, bytearray)) else query
        types = (
          [t.decode('utf-8') if isinstance(t, (bytes, bytearray)) else t for t in edge_types]
          if edge_types else None
        )
        async def search_with_sources():
          if types:
            edges = await g.search(
              q,
              num_results=max_results,
              search_filter=SearchFilters(edge_types=types),
            )
          else:
            edges = await g.search(q, num_results=max_results)

          episode_ids = list(dict.fromkeys(
            episode_id for edge in edges for episode_id in (getattr(edge, "episodes", None) or [])
          ))
          episodes = await EpisodicNode.get_by_uuids(g.driver, episode_ids) if episode_ids else []
          episodes_by_id = {episode.uuid: episode for episode in episodes}
          source_kinds = {
            "message": "conversation",
            "text": "document",
            "json": "structured_record",
          }

          rendered = []
          for edge in edges:
            fact = {
              "fact": edge.fact,
              "created_at": str(edge.created_at) if edge.created_at else None,
              "valid_at": str(edge.valid_at) if edge.valid_at else None,
              "invalid_at": str(edge.invalid_at) if edge.invalid_at else None,
              "expired_at": str(edge.expired_at) if edge.expired_at else None,
            }
            sources = [
              {
                "id": episode_id,
                "source_kind": source_kinds.get(episodes_by_id[episode_id].source.value),
                "source_description": episodes_by_id[episode_id].source_description,
              }
              for episode_id in (getattr(edge, "episodes", None) or [])
              if episode_id in episodes_by_id
            ]
            if sources:
              fact["sources"] = sources
            rendered.append(fact)

          return rendered

        asyncio._gralkor_run(search_with_sources())
        """,
        %{
          "g" => instance,
          "query" => query,
          "max_results" => max_results,
          "edge_types" => edge_types
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

  This is the primitive for content Gralkor must read back verbatim. Edge and
  node search both return what an extractor *derived* from an episode, which is
  a different text and may be nothing at all: an episode naming one subject
  yields a node and no edge. Graphiti searches episodes by BM25 over their
  content, so retrieval here depends on the stored words rather than extraction.
  Internal completion-only callers may request identity convergence. Ranked
  results choose artefact identifiers; every completed episode carrying a
  selected identifier is then enumerated independently of BM25 so conflicts
  outside the ranked window remain visible to the caller. Mixed public episode
  searches may require completion only for Reflection-authored episodes while
  leaving ordinary historical episodes visible.
  """
  @spec search_episodes(String.t(), String.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def search_episodes(group_id, query, max_results),
    do: search_episodes(__MODULE__, group_id, query, max_results, [])

  @spec search_episodes(GenServer.server(), String.t(), String.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def search_episodes(server, group_id, query, max_results),
    do: search_episodes(server, group_id, query, max_results, [])

  @spec search_episodes(
          GenServer.server(),
          String.t(),
          String.t(),
          pos_integer(),
          keyword()
        ) :: {:ok, [map()]} | {:error, term()}
  def search_episodes(server, group_id, query, max_results, opts)
      when is_binary(group_id) and is_binary(query) and is_integer(max_results) and
             max_results > 0 and is_list(opts) do
    instance = __MODULE__.for(server, group_id)
    require_extraction_complete = Keyword.get(opts, :require_extraction_complete, false)
    require_reflection_complete = Keyword.get(opts, :require_reflection_complete, false)
    converge_by_identity = Keyword.get(opts, :converge_by_identity, false)
    lenses = Keyword.get(opts, :lenses, [])

    {raw, _} =
      Pythonx.eval(
        """
        import asyncio
        import json
        from graphiti_core.search.search_config import (
          EpisodeSearchConfig,
          EpisodeSearchMethod,
          SearchConfig,
        )
        from graphiti_core.search.search_filters import SearchFilters

        q = query.decode('utf-8') if isinstance(query, (bytes, bytearray)) else query
        gid = group_id.decode('utf-8') if isinstance(group_id, (bytes, bytearray)) else group_id
        lens_names = [
          name.decode('utf-8') if isinstance(name, (bytes, bytearray)) else name
          for name in lenses
        ]
        search_limit = max_results
        if converge_by_identity or lens_names or require_reflection_complete:
          if hasattr(g.driver, 'execute_query'):
            records, _, _ = asyncio._gralkor_run(
              g.driver.execute_query(
                "MATCH (e:Episodic {group_id: $group_id}) RETURN count(e) AS count",
                group_id=gid,
              )
            )
            if records:
              search_limit = max(search_limit, int(records[0]['count']))
          else:
            search_limit = max(
              search_limit,
              int(getattr(g.driver, '_gralkor_episode_count', search_limit)),
            )
        config = SearchConfig(
          episode_config=EpisodeSearchConfig(search_methods=[EpisodeSearchMethod.bm25]),
          limit=search_limit,
        )
        res = asyncio._gralkor_run(
          g.search_(q, config=config, group_ids=[gid], search_filter=SearchFilters())
        )

        episodes = res.episodes
        def reflection_episode(episode):
          return (episode.source_description or '').startswith('reflection:')

        if require_extraction_complete or require_reflection_complete:
          episode_ids = [
            e.uuid
            for e in episodes
            if require_extraction_complete or reflection_episode(e)
          ]
          if hasattr(g.driver, 'execute_query') and episode_ids:
            records, _, _ = asyncio._gralkor_run(
              g.driver.execute_query(
                "MATCH (e:Episodic) WHERE e.uuid IN $uuids AND coalesce(e._gralkor_extraction_complete, false) = true RETURN e.uuid AS uuid",
                uuids=episode_ids,
              )
            )
            completed_ids = {record['uuid'] for record in records}
          else:
            completed_ids = set(
              getattr(g.driver, '_gralkor_completed_episode_uuids', set())
            )
          episodes = [
            e
            for e in episodes
            if not (
              require_extraction_complete
              or (require_reflection_complete and reflection_episode(e))
            )
            or e.uuid in completed_ids
          ]

        if lens_names:
          lens_suffixes = tuple(f" [lens: {name}]" for name in lens_names)
          episodes = [
            episode
            for episode in episodes
            if (episode.source_description or '').endswith(lens_suffixes)
          ]

        def artefact_id_for(content):
          try:
            decoded = json.loads(content)
          except (TypeError, ValueError):
            return None
          identifier = decoded.get('id') if isinstance(decoded, dict) else None
          return identifier if isinstance(identifier, str) and identifier else None

        def episode_result(episode):
          return {
            "content": episode.content,
            "source_description": episode.source_description,
          }

        if converge_by_identity:
          selected_ids = []
          for episode in episodes:
            identifier = artefact_id_for(episode.content)
            if identifier is not None and identifier not in selected_ids:
              selected_ids.append(identifier)
              if len(selected_ids) == max_results:
                break

          if hasattr(g.driver, 'execute_query') and selected_ids:
            records, _, _ = asyncio._gralkor_run(
              g.driver.execute_query(
                '''
                MATCH (e:Episodic {group_id: $group_id})
                WHERE $include_incomplete OR
                      coalesce(e._gralkor_extraction_complete, false) = true
                RETURN e.uuid AS uuid,
                       e.content AS content,
                       e.source_description AS source_description
                /* gralkor_exhaustive_identity_convergence */
                ''',
                group_id=gid,
                include_incomplete=not require_extraction_complete,
              )
            )
            candidates = [
              {
                "content": record['content'],
                "source_description": record['source_description'],
              }
              for record in records
            ]
          elif selected_ids and hasattr(g.driver, 'episodes'):
            completed_ids = set(
              getattr(g.driver, '_gralkor_completed_episode_uuids', set())
            )
            candidates = [
              episode_result(episode)
              for episode in g.driver.episodes.values()
              if getattr(episode, 'group_id', gid) == gid
              and (
                not require_extraction_complete
                or episode.uuid in completed_ids
              )
            ]
          elif selected_ids:
            raise RuntimeError(
              'identity convergence requires exhaustive episode enumeration'
            )
          else:
            candidates = []

          candidates_by_id = {}
          for candidate in candidates:
            identifier = artefact_id_for(candidate['content'])
            if identifier in selected_ids:
              candidates_by_id.setdefault(identifier, []).append(candidate)

          episode_results = [
            candidate
            for identifier in selected_ids
            for candidate in candidates_by_id.get(identifier, [])
          ]
        else:
          episode_results = [episode_result(episode) for episode in episodes[:max_results]]

        episode_results
        """,
        %{
          "g" => instance,
          "query" => query,
          "group_id" => Client.sanitize_group_id(group_id),
          "max_results" => max_results,
          "require_extraction_complete" => require_extraction_complete,
          "require_reflection_complete" => require_reflection_complete,
          "converge_by_identity" => converge_by_identity,
          "lenses" => lenses
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
  whose `node_labels` filter matches edges by endpoint), this returns *nodes*
  that are not reliably reachable through edge search.

  Returns `{:ok, [%{name:, summary:, attributes:}]}` ordered by relevance.

  ## Options

    * `:node_labels` — optional `[String.t()]`. When present, a
      `SearchFilters(node_labels: …)` restricts results to nodes carrying one of
      those labels. When absent, all nodes are eligible.
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

    * `:uuid` — optional deterministic episode UUID. A graph-backed renewable
      claim serializes that UUID across application runtimes. The episode,
      extracted entities and edges, and durable completion marker persist in
      one generation-fenced graph query. A missing UUID is created, an equal
      marked episode succeeds without extraction, an equal unmarked episode
      resumes extraction, and conflicting immutable episode content returns an
      episode conflict.
    * `:lens` — optional originating Lens name. It is appended to the episode's
      source description before the single graphiti `add_episode` call.
    * `:source_kind` — `:conversation`, `:document`, or `:structured_record`,
      mapped to graphiti's message, text, or JSON episode type respectively.
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

    ontology_dicts =
      case ontology do
        nil -> nil
        module when is_atom(module) -> GenServer.call(server, {:materialise, module}, :infinity)
      end

    uuid = Keyword.get(opts, :uuid)
    source_kind = Keyword.get(opts, :source_kind)
    extraction_instructions = @provenance_extraction_instructions

    result =
      with_episode_write_admission(server, uuid, fn skip_empty_edge_candidates ->
        {raw, _} =
          Pythonx.eval(
            """
            import asyncio
            from contextvars import ContextVar
            from datetime import datetime, timezone
            from uuid import uuid4
            from graphiti_core.driver.driver import GraphProvider
            from graphiti_core.errors import NodeNotFoundError
            import graphiti_core.graphiti as graphiti_module
            from graphiti_core.utils.maintenance import edge_operations
            from graphiti_core.nodes import EpisodeType, EpisodicNode
            c = content.decode('utf-8') if isinstance(content, (bytes, bytearray)) else content
            s = source.decode('utf-8') if isinstance(source, (bytes, bytearray)) else source
            n = name.decode('utf-8') if isinstance(name, (bytes, bytearray)) else name
            gid = group.decode('utf-8') if isinstance(group, (bytes, bytearray)) else group
            sk = source_kind.decode('utf-8') if isinstance(source_kind, (bytes, bytearray)) else source_kind
            instructions = extraction_instructions.decode('utf-8') if isinstance(extraction_instructions, (bytes, bytearray)) else extraction_instructions
            episode_type = {
              'conversation': EpisodeType.message,
              'structured_record': EpisodeType.json,
            }.get(sk, EpisodeType.text)
            kwargs = dict(
              name=n,
              episode_body=c,
              source=episode_type,
              source_description=s,
              group_id=gid,
              reference_time=datetime.now(timezone.utc),
              custom_extraction_instructions=instructions,
            )
            if ontology_dicts is not None:
                def _dec(x):
                    return x.decode('utf-8') if isinstance(x, (bytes, bytearray)) else x
                for k, v in ontology_dicts.items():
                    kwargs[_dec(k)] = [_dec(i) for i in v] if isinstance(v, list) else v
            if uuid is not None:
                uid = uuid.decode('utf-8') if isinstance(uuid, (bytes, bytearray)) else uuid
                kwargs['uuid'] = uid

            guard = getattr(EpisodicNode, '_gralkor_requested_uuid_guard', None)
            if guard is None:
                guard = ContextVar('_gralkor_requested_uuid_guard', default=None)
                original_get_by_uuid = EpisodicNode.get_by_uuid
                original_save = EpisodicNode.save

                class ClaimLostError(RuntimeError):
                    pass

                async def guarded_get_by_uuid(cls, driver, requested_uuid):
                    try:
                        return await original_get_by_uuid(driver, requested_uuid)
                    except NodeNotFoundError:
                        seed = guard.get()
                        if (
                            seed is None
                            or requested_uuid != seed['uuid']
                            or not seed['synthesise_missing']
                        ):
                            raise
                        return EpisodicNode(**seed['episode'])

                async def guarded_save(self, driver):
                    fence = guard.get()
                    if fence is None or self.uuid != fence['uuid'] or not fence['distributed']:
                        return await original_save(self, driver)

                    fence_params = dict(
                        claim_uuid=fence['uuid'],
                        owner=fence['owner'],
                        generation=fence['generation'],
                    )
                    if getattr(driver, 'provider', None) == GraphProvider.FALKORDB:
                        records, _, _ = await driver.execute_query(
                            '''
                            MATCH (c:_GralkorEpisodeClaim {uuid: $claim_uuid})
                            WHERE c.owner = $owner AND c.generation = $generation
                            RETURN c.generation AS generation
                            /* gralkor_claim_fence_check */
                            ''',
                            **fence_params,
                        )
                    else:
                        # Test/custom drivers cannot execute Falkor's episode mutation,
                        # but they must still prove ownership before their native save.
                        records, _, _ = await driver.execute_query(
                            '''
                            MATCH (c:_GralkorEpisodeClaim {uuid: $claim_uuid})
                            WHERE c.owner = $owner AND c.generation = $generation
                            RETURN c.generation AS generation /* gralkor_claim_fence_check */
                            ''',
                            **fence_params,
                        )
                        if records:
                            return await original_save(self, driver)

                    if not records:
                        raise ClaimLostError(
                            f'episode claim lost for {self.uuid} generation {fence["generation"]}'
                        )

                EpisodicNode._gralkor_requested_uuid_guard = guard
                EpisodicNode._gralkor_claim_lost_error = ClaimLostError
                EpisodicNode.get_by_uuid = classmethod(guarded_get_by_uuid)
                EpisodicNode.save = guarded_save

            ClaimLostError = EpisodicNode._gralkor_claim_lost_error

            if not hasattr(graphiti_module, '_gralkor_original_add_nodes_and_edges_bulk'):
                original_add_nodes_and_edges_bulk = graphiti_module.add_nodes_and_edges_bulk

                async def claim_fenced_add_nodes_and_edges_bulk(
                    driver,
                    episodic_nodes,
                    episodic_edges,
                    entity_nodes,
                    entity_edges,
                    embedder,
                ):
                    fence = guard.get()
                    if (
                        fence is None
                        or not fence['distributed']
                        or getattr(driver, 'provider', None) != GraphProvider.FALKORDB
                    ):
                        return await original_add_nodes_and_edges_bulk(
                            driver,
                            episodic_nodes,
                            episodic_edges,
                            entity_nodes,
                            entity_edges,
                            embedder,
                        )

                    episodes = []
                    for episode in episodic_nodes:
                        episodes.append(dict(
                            uuid=episode.uuid,
                            name=episode.name,
                            group_id=episode.group_id,
                            source_description=episode.source_description,
                            source=episode.source.value,
                            content=episode.content,
                            entity_edges=episode.entity_edges,
                            created_at=episode.created_at,
                            valid_at=episode.valid_at,
                        ))

                    nodes = []
                    for node in entity_nodes:
                        if node.name_embedding is None:
                            await node.generate_name_embedding(embedder)
                        entity_data = dict(
                            uuid=node.uuid,
                            name=node.name,
                            group_id=node.group_id,
                            summary=node.summary,
                            created_at=node.created_at,
                            name_embedding=node.name_embedding,
                            labels=sorted(set(node.labels + ['Entity'])),
                        )
                        for key, value in (node.attributes or {}).items():
                            if key not in entity_data:
                                entity_data[key] = value
                        nodes.append(entity_data)

                    relations = []
                    for edge in entity_edges:
                        if edge.fact_embedding is None:
                            await edge.generate_embedding(embedder)
                        edge_data = dict(
                            uuid=edge.uuid,
                            source_node_uuid=edge.source_node_uuid,
                            target_node_uuid=edge.target_node_uuid,
                            name=edge.name,
                            fact=edge.fact,
                            group_id=edge.group_id,
                            episodes=edge.episodes,
                            created_at=edge.created_at,
                            expired_at=edge.expired_at,
                            valid_at=edge.valid_at,
                            invalid_at=edge.invalid_at,
                            reference_time=edge.reference_time,
                            fact_embedding=edge.fact_embedding,
                        )
                        for key, value in (edge.attributes or {}).items():
                            if key not in edge_data:
                                edge_data[key] = value
                        relations.append(edge_data)

                    params = dict(
                        claim_uuid=fence['uuid'],
                        owner=fence['owner'],
                        generation=fence['generation'],
                    )
                    clauses = [
                        '''
                        MATCH (claim:_GralkorEpisodeClaim {uuid: $claim_uuid})
                        WHERE claim.owner = $owner AND claim.generation = $generation
                        SET claim._gralkor_fenced_generation = $generation
                        WITH claim
                        '''
                    ]

                    for index, episode in enumerate(episodes):
                        parameter = f'episode_{index}'
                        variable = f'episode_{index}'
                        params[parameter] = episode
                        clauses.append(f'''
                            MERGE ({variable}:Episodic {{uuid: ${parameter}.uuid}})
                            SET {variable} = {{
                              uuid: ${parameter}.uuid,
                              name: ${parameter}.name,
                              group_id: ${parameter}.group_id,
                              source_description: ${parameter}.source_description,
                              source: ${parameter}.source,
                              content: ${parameter}.content,
                              entity_edges: ${parameter}.entity_edges,
                              created_at: ${parameter}.created_at,
                              valid_at: ${parameter}.valid_at,
                              _gralkor_extraction_complete: true
                            }}
                            WITH claim
                        ''')

                    for index, node in enumerate(nodes):
                        parameter = f'entity_node_{index}'
                        variable = f'entity_node_{index}'
                        labels = ':'.join(node['labels'])
                        params[parameter] = node
                        clauses.append(f'''
                            MERGE ({variable}:Entity {{uuid: ${parameter}.uuid}})
                            SET {variable}:{labels}
                            SET {variable} = ${parameter}
                            SET {variable}.name_embedding = vecf32(${parameter}.name_embedding)
                            WITH claim
                        ''')

                    for index, edge in enumerate(episodic_edges):
                        parameter = f'episodic_edge_{index}'
                        source = f'episodic_source_{index}'
                        target = f'episodic_target_{index}'
                        relation = f'episodic_relation_{index}'
                        params[parameter] = edge.model_dump()
                        clauses.append(f'''
                            MATCH ({source}:Episodic {{uuid: ${parameter}.source_node_uuid}})
                            MATCH ({target}:Entity {{uuid: ${parameter}.target_node_uuid}})
                            MERGE ({source})-[{relation}:MENTIONS {{uuid: ${parameter}.uuid}}]->({target})
                            SET {relation}.group_id = ${parameter}.group_id,
                                {relation}.created_at = ${parameter}.created_at
                            WITH claim
                        ''')

                    for index, edge in enumerate(relations):
                        parameter = f'entity_edge_{index}'
                        source = f'entity_source_{index}'
                        target = f'entity_target_{index}'
                        relation = f'entity_relation_{index}'
                        params[parameter] = edge
                        clauses.append(f'''
                            MATCH ({source}:Entity {{uuid: ${parameter}.source_node_uuid}})
                            MATCH ({target}:Entity {{uuid: ${parameter}.target_node_uuid}})
                            MERGE ({source})-[{relation}:RELATES_TO {{uuid: ${parameter}.uuid}}]->({target})
                            SET {relation} = ${parameter}
                            SET {relation}.fact_embedding = vecf32(${parameter}.fact_embedding)
                            WITH claim
                        ''')

                    clauses.append(
                        'RETURN claim.generation AS generation '
                        '/* gralkor_claim_fenced_graph_effects */'
                    )
                    records, _, _ = await driver.execute_query(
                        '\\n'.join(clauses),
                        **params,
                    )
                    if not records:
                        raise ClaimLostError(
                            f'episode claim lost before graph effects for '
                            f'{fence["uuid"]} generation {fence["generation"]}'
                        )

                graphiti_module._gralkor_original_add_nodes_and_edges_bulk = (
                    original_add_nodes_and_edges_bulk
                )
                graphiti_module.add_nodes_and_edges_bulk = (
                    claim_fenced_add_nodes_and_edges_bulk
                )

            import sys

            async def extraction_complete():
                if not hasattr(g.driver, 'execute_query'):
                    completed = getattr(g.driver, '_gralkor_completed_episode_uuids', set())
                    return uid in completed
                records, _, _ = await g.driver.execute_query(
                    "MATCH (e:Episodic {uuid: $uuid}) RETURN coalesce(e._gralkor_extraction_complete, false) AS complete",
                    uuid=uid,
                )
                return bool(records and records[0]['complete'])

            async def record_extraction_complete():
                if not hasattr(g.driver, 'execute_query'):
                    completed = getattr(g.driver, '_gralkor_completed_episode_uuids', set())
                    completed.add(uid)
                    g.driver._gralkor_completed_episode_uuids = completed
                    return
                if claim_state['distributed']:
                    records, _, _ = await g.driver.execute_query(
                        '''
                        MATCH (c:_GralkorEpisodeClaim {uuid: $uuid})
                        WHERE c.owner = $owner AND c.generation = $generation
                        WITH c
                        MATCH (e:Episodic {uuid: $uuid})
                        SET e._gralkor_extraction_complete = true
                        RETURN e.uuid AS uuid
                        ''',
                        uuid=uid,
                        owner=claim_owner,
                        generation=claim_state['generation'],
                    )
                    if not records:
                        raise ClaimLostError(
                            f'episode claim lost before completion for {uid} '
                            f'generation {claim_state["generation"]}'
                        )
                    return
                await g.driver.execute_query(
                    "MATCH (e:Episodic {uuid: $uuid}) SET e._gralkor_extraction_complete = true RETURN e.uuid AS uuid",
                    uuid=uid,
                )

            claim_owner = str(uuid4()) if uuid is not None else None
            claim_lease_ms = getattr(g, '_gralkor_claim_lease_ms', 30_000)
            claim_state = {'distributed': False, 'generation': None}

            async def ensure_claim_constraint():
                if getattr(g.driver, 'provider', None) != GraphProvider.FALKORDB:
                    return
                if getattr(g.driver, '_gralkor_claim_constraint_ready', False):
                    return

                graph = g.driver._get_graph(g.driver._database)
                creation_error = None
                try:
                    await graph.create_node_unique_constraint(
                        '_GralkorEpisodeClaim', 'uuid'
                    )
                except Exception as error:
                    # Another runtime may be creating the same asynchronous
                    # constraint. Its operational status below is authoritative.
                    creation_error = error

                for _ in range(1000):
                    constraints = await graph.list_constraints()
                    matching = [
                        constraint for constraint in constraints
                        if constraint.get('type') == 'UNIQUE'
                        and constraint.get('label') == '_GralkorEpisodeClaim'
                        and constraint.get('properties') == ['uuid']
                    ]
                    if matching:
                        status = str(matching[0].get('status', '')).upper()
                        if status in {'OPERATIONAL', 'ACTIVE'}:
                            g.driver._gralkor_claim_constraint_ready = True
                            return
                        if status in {'FAILED', 'ERROR'}:
                            raise RuntimeError(
                                f'episode claim uniqueness constraint failed: {matching[0]}'
                            )
                    await asyncio.sleep(0.01)

                if creation_error is not None:
                    raise RuntimeError(
                        f'episode claim uniqueness constraint unavailable: {creation_error}'
                    )
                raise RuntimeError('episode claim uniqueness constraint did not become operational')

            async def acquire_claim():
                if not hasattr(g.driver, 'execute_query'):
                    return 'acquired'

                await ensure_claim_constraint()

                source_value = getattr(episode_type, 'value', str(episode_type))
                while True:
                    records, _, _ = await g.driver.execute_query(
                        '''
                        OPTIONAL MATCH (e:Episodic {uuid: $uuid})
                        MERGE (c:_GralkorEpisodeClaim {uuid: $uuid})
                        ON CREATE SET
                          c.group_id = CASE WHEN e IS NULL THEN $group_id ELSE e.group_id END,
                          c.content = CASE WHEN e IS NULL THEN $content ELSE e.content END,
                          c.source = CASE WHEN e IS NULL THEN $source ELSE e.source END,
                          c.source_description = CASE WHEN e IS NULL THEN $source_description ELSE e.source_description END,
                          c.owner = $owner,
                          c.generation = 1,
                          c.lease_until_ms = timestamp() + $lease_ms
                        RETURN c.group_id AS group_id,
                               c.content AS content,
                               c.source AS source,
                               c.source_description AS source_description,
                               c.owner AS owner,
                               coalesce(c.generation, 0) AS generation,
                               coalesce(c.lease_until_ms, 0) AS lease_until_ms,
                               e.uuid AS episode_uuid,
                               e.group_id AS episode_group_id,
                               e.content AS episode_content,
                               e.source AS episode_source,
                               e.source_description AS episode_source_description
                        ''',
                        uuid=uid,
                        group_id=gid,
                        content=c,
                        source=source_value,
                        source_description=s,
                        owner=claim_owner,
                        lease_ms=claim_lease_ms,
                    )
                    claim_keys = {
                        'group_id', 'content', 'source', 'source_description',
                        'owner', 'generation', 'lease_until_ms'
                    }
                    if not records or not claim_keys.issubset(records[0].keys()):
                        raise RuntimeError('graph-backed episode claim contract is unavailable')
                    claim_state['distributed'] = True
                    claim = records[0]
                    if claim['owner'] == claim_owner:
                        claim_state['generation'] = claim['generation']
                    episode_equal = (
                        claim.get('episode_uuid') is None
                        or (
                            claim.get('episode_group_id') == gid
                            and claim.get('episode_content') == c
                            and claim.get('episode_source') == source_value
                            and claim.get('episode_source_description') == s
                        )
                    )
                    if not episode_equal:
                        return 'conflict'
                    equal = (
                        claim['group_id'] == gid
                        and claim['content'] == c
                        and claim['source'] == source_value
                        and claim['source_description'] == s
                    )
                    if not equal:
                        return 'conflict'
                    if await extraction_complete():
                        return 'existing'
                    if claim['owner'] == claim_owner:
                        return 'acquired'

                    acquired, _, _ = await g.driver.execute_query(
                        '''
                        MATCH (c:_GralkorEpisodeClaim {uuid: $uuid})
                        WHERE c.owner IS NULL OR c.owner = $owner OR
                              coalesce(c.lease_until_ms, 0) <= timestamp()
                        SET c.owner = $owner,
                            c.generation = coalesce(c.generation, 0) + 1,
                            c.lease_until_ms = timestamp() + $lease_ms
                        RETURN c.owner AS owner, c.generation AS generation
                        ''',
                        uuid=uid,
                        owner=claim_owner,
                        lease_ms=claim_lease_ms,
                    )
                    if acquired and acquired[0]['owner'] == claim_owner:
                        claim_state['generation'] = acquired[0]['generation']
                        return 'acquired'
                    await asyncio.sleep(0.01)

            async def renew_claim():
                if not claim_state['distributed']:
                    return
                while True:
                    await asyncio.sleep(claim_lease_ms / 3000)
                    renewed, _, _ = await g.driver.execute_query(
                        '''
                        MATCH (c:_GralkorEpisodeClaim {uuid: $uuid})
                        WHERE c.owner = $owner AND c.generation = $generation
                        SET c.lease_until_ms = timestamp() + $lease_ms
                        RETURN c.generation AS generation
                        ''',
                        uuid=uid,
                        owner=claim_owner,
                        generation=claim_state['generation'],
                        lease_ms=claim_lease_ms,
                    )
                    if not renewed:
                        raise ClaimLostError(
                            f'episode claim renewal lost for {uid} '
                            f'generation {claim_state["generation"]}'
                        )

            async def release_claim():
                if not claim_state['distributed']:
                    return
                await g.driver.execute_query(
                    '''
                    MATCH (c:_GralkorEpisodeClaim {uuid: $uuid})
                    WHERE c.owner = $owner AND c.generation = $generation
                    SET c.owner = NULL, c.lease_until_ms = NULL
                    RETURN c.uuid AS uuid
                    ''',
                    uuid=uid,
                    owner=claim_owner,
                    generation=claim_state['generation'],
                )

            async def add_episode():
                if uuid is not None:
                    claim = await acquire_claim()
                    if claim != 'acquired':
                        await release_claim()
                        return claim

                    heartbeat = asyncio.create_task(renew_claim())
                    try:
                        try:
                            existing = await EpisodicNode.get_by_uuid(g.driver, uid)
                        except NodeNotFoundError:
                            existing = None

                        if existing is not None:
                            equal = (
                                existing.group_id == gid
                                and existing.content == c
                                and existing.source == episode_type
                                and existing.source_description == s
                            )
                            if not equal:
                                return 'conflict'
                            if await extraction_complete():
                                return 'existing'

                        token = guard.set(dict(
                            uuid=uid,
                            owner=claim_owner,
                            generation=claim_state['generation'],
                            distributed=claim_state['distributed'],
                            synthesise_missing=existing is None,
                            episode=dict(
                                uuid=uid,
                                name=n,
                                group_id=gid,
                                labels=[],
                                source=episode_type,
                                content=c,
                                source_description=s,
                                created_at=datetime.now(timezone.utc),
                                valid_at=kwargs['reference_time'],
                            ),
                        ))

                        if not skip_empty_edge_candidates:
                            try:
                                await g.add_episode(**kwargs)
                                await record_extraction_complete()
                                return 'created'
                            finally:
                                guard.reset(token)

                        empty_edge_guard = edge_operations._gralkor_skip_empty_edge_candidates
                        empty_edge_token = empty_edge_guard.set(True)
                        try:
                            await g.add_episode(**kwargs)
                            await record_extraction_complete()
                            return 'created'
                        finally:
                            empty_edge_guard.reset(empty_edge_token)
                            guard.reset(token)
                    finally:
                        heartbeat.cancel()
                        try:
                            await heartbeat
                        except asyncio.CancelledError:
                            pass
                        await release_claim()
                else:
                    token = None

                if not skip_empty_edge_candidates:
                    try:
                        await g.add_episode(**kwargs)
                        return 'created'
                    finally:
                        if token is not None:
                            guard.reset(token)

                empty_edge_guard = edge_operations._gralkor_skip_empty_edge_candidates
                empty_edge_token = empty_edge_guard.set(True)
                try:
                    await g.add_episode(**kwargs)
                    return 'created'
                finally:
                    empty_edge_guard.reset(empty_edge_token)
                    if token is not None:
                        guard.reset(token)
            try:
                result = asyncio._gralkor_run(add_episode())
            except BaseException as e:
                print(f"[gralkor] add_episode failed: {type(e).__name__}: {e}", file=sys.stderr)
                raise
            result
            """,
            %{
              "g" => instance,
              "content" => content,
              "source" => source_description,
              "name" => name,
              "group" => sanitized,
              "ontology_dicts" => ontology_dicts,
              "uuid" => uuid,
              "source_kind" => source_kind && Atom.to_string(source_kind),
              "extraction_instructions" => extraction_instructions,
              "skip_empty_edge_candidates" => skip_empty_edge_candidates
            }
          )

        Pythonx.decode(raw)
      end)

    case result do
      "conflict" -> {:error, {:episode_conflict, uuid}}
      _ -> :ok
    end
  rescue
    e in Pythonx.Error -> {:error, {:python, summarise_python_error(e)}}
  end

  defp with_episode_write_admission(server, uuid, operation) do
    with_uuid_write_admission(server, uuid, fn ->
      case GenServer.call(server, :acquire_episode_write, :infinity) do
        :unbounded ->
          operation.(false)

        :acquired ->
          try do
            operation.(true)
          after
            GenServer.cast(server, {:release_episode_write, self()})
          end
      end
    end)
  end

  defp with_uuid_write_admission(_server, nil, operation), do: operation.()

  defp with_uuid_write_admission(server, uuid, operation) do
    :acquired = GenServer.call(server, {:acquire_episode_uuid, uuid}, :infinity)

    try do
      operation.()
    after
      GenServer.cast(server, {:release_episode_uuid, uuid, self()})
    end
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

  @fact_keys ~w(fact created_at valid_at invalid_at expired_at sources)a
  @fact_keys_strings Enum.map(@fact_keys, &Atom.to_string/1)
  @source_keys ~w(id source_kind source_description)a
  @source_keys_strings Enum.map(@source_keys, &Atom.to_string/1)

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if k in @fact_keys_strings, do: String.to_atom(k), else: k
      v = if key == :sources, do: Enum.map(v, &atomize_source_keys/1), else: v
      {key, v}
    end)
  end

  defp atomize_source_keys(map) do
    Map.new(map, fn {key, value} ->
      key = if key in @source_keys_strings, do: String.to_atom(key), else: key
      {key, value}
    end)
  end

  @doc "Returns one episode by its exact UUID."
  @spec get_episode(GenServer.server(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def get_episode(server \\ __MODULE__, group_id, episode_uuid)
      when is_binary(group_id) and is_binary(episode_uuid) do
    instance = __MODULE__.for(server, group_id)

    {raw, _} =
      Pythonx.eval(
        """
        import asyncio
        from graphiti_core.errors import NodeNotFoundError
        from graphiti_core.nodes import EpisodicNode

        uid = episode_uuid.decode('utf-8') if isinstance(episode_uuid, (bytes, bytearray)) else episode_uuid
        async def get_episode():
            try:
                episode = await EpisodicNode.get_by_uuid(g.driver, uid)
            except NodeNotFoundError:
                return None

            if hasattr(g.driver, 'execute_query'):
                records, _, _ = await g.driver.execute_query(
                    "MATCH (e:Episodic {uuid: $uuid}) RETURN coalesce(e._gralkor_extraction_complete, false) AS complete",
                    uuid=uid,
                )
                extraction_complete = bool(records and records[0]['complete'])
            else:
                extraction_complete = uid in getattr(
                    g.driver,
                    '_gralkor_completed_episode_uuids',
                    set(),
                )

            return {
                'uuid': episode.uuid,
                'group_id': episode.group_id,
                'content': episode.content,
                'source': episode.source.value,
                'source_description': episode.source_description,
                'extraction_complete': extraction_complete,
            }

        asyncio._gralkor_run(get_episode())
        """,
        %{"g" => instance, "episode_uuid" => episode_uuid}
      )

    case Pythonx.decode(raw) do
      nil -> {:error, :not_found}
      episode -> {:ok, episode}
    end
  rescue
    e in Pythonx.Error -> {:error, {:python, summarise_python_error(e)}}
  end

  # ── GenServer ──────────────────────────────────────────────

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @default_table)
    falkordb_spec = Keyword.fetch!(opts, :falkordb_spec)
    llm_model = Keyword.get(opts, :llm_model, Config.llm_model())
    embedder_model = Keyword.get(opts, :embedder_model, Config.embedder_model())
    validate_native_models!(llm_model, embedder_model)

    socket_timeout = embedded_falkordb_socket_timeout(falkordb_spec, opts)
    construct_falkor_db = Keyword.get(opts, :construct_falkor_db, &default_construct_falkor_db/2)

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
    :ok = install_empty_edge_candidate_guard(falkordb_spec)

    shared = construct_shared_clients.(llm_model, embedder_model)

    case falkordb_spec do
      {:embedded, data_dir} ->
        File.mkdir_p!(data_dir)
        File.rm(Path.join(data_dir, "gralkor.db.settings"))

      {:remote, _opts} ->
        :ok
    end

    falkor_db = construct_falkor_db(construct_falkor_db, falkordb_spec, socket_timeout)

    state = %{
      table: table,
      falkordb_spec: falkordb_spec,
      falkor_db: falkor_db,
      close_falkor_db: close_falkor_db,
      shared: shared,
      construct_instance: construct_instance,
      initialise_instance: initialise_instance,
      ontology_cache: %{},
      episode_write_admission: episode_write_admission(falkordb_spec),
      episode_uuid_admissions: %{}
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

  def handle_call(:acquire_episode_write, _from, %{episode_write_admission: :unbounded} = state) do
    {:reply, :unbounded, state}
  end

  def handle_call(
        :acquire_episode_write,
        from,
        %{episode_write_admission: %{owner: nil} = admission} = state
      ) do
    owner = elem(from, 0)
    monitor = Process.monitor(owner)
    admission = %{admission | owner: owner, monitor: monitor}
    {:reply, :acquired, %{state | episode_write_admission: admission}}
  end

  def handle_call(
        :acquire_episode_write,
        from,
        %{episode_write_admission: admission} = state
      ) do
    admission = %{admission | waiting: :queue.in(from, admission.waiting)}
    {:noreply, %{state | episode_write_admission: admission}}
  end

  def handle_call({:acquire_episode_uuid, uuid}, from, state) do
    case Map.get(state.episode_uuid_admissions, uuid) do
      nil ->
        owner = elem(from, 0)
        admission = %{owner: owner, monitor: Process.monitor(owner), waiting: :queue.new()}

        {:reply, :acquired,
         %{
           state
           | episode_uuid_admissions: Map.put(state.episode_uuid_admissions, uuid, admission)
         }}

      admission ->
        admission = %{admission | waiting: :queue.in(from, admission.waiting)}

        {:noreply,
         %{
           state
           | episode_uuid_admissions: Map.put(state.episode_uuid_admissions, uuid, admission)
         }}
    end
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
  def handle_cast(
        {:release_episode_write, owner},
        %{episode_write_admission: %{owner: owner} = admission} = state
      ) do
    Process.demonitor(admission.monitor, [:flush])
    {:noreply, admit_next_episode_write(state, admission)}
  end

  def handle_cast({:release_episode_write, _owner}, state), do: {:noreply, state}

  def handle_cast({:release_episode_uuid, uuid, owner}, state) do
    case Map.get(state.episode_uuid_admissions, uuid) do
      %{owner: ^owner} = admission ->
        Process.demonitor(admission.monitor, [:flush])
        {:noreply, admit_next_episode_uuid_write(state, uuid, admission)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, owner, _reason},
        %{episode_write_admission: %{owner: owner, monitor: monitor} = admission} = state
      ) do
    {:noreply, admit_next_episode_write(state, admission)}
  end

  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    case Enum.find(state.episode_uuid_admissions, fn {_uuid, admission} ->
           admission.owner == owner and admission.monitor == monitor
         end) do
      {uuid, admission} -> {:noreply, admit_next_episode_uuid_write(state, uuid, admission)}
      nil -> {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    :ok = state.close_falkor_db.(state.falkor_db)
    unregister_table(self())
    :ets.delete(state.table)
    :ok
  end

  defp episode_write_admission({:embedded, _data_dir}) do
    %{owner: nil, monitor: nil, waiting: :queue.new()}
  end

  defp episode_write_admission({:remote, _options}), do: :unbounded

  defp install_empty_edge_candidate_guard({:remote, _options}), do: :ok

  defp install_empty_edge_candidate_guard({:embedded, _data_dir}) do
    Pythonx.eval(
      """
      from contextvars import ContextVar
      from graphiti_core.search.search_config import SearchResults
      from graphiti_core.utils.maintenance import edge_operations

      guard = getattr(edge_operations, '_gralkor_skip_empty_edge_candidates', None)
      if guard is None:
          guard = ContextVar('_gralkor_skip_empty_edge_candidates', default=False)
          edge_operations._gralkor_skip_empty_edge_candidates = guard

      current_search = edge_operations.search
      if not getattr(current_search, '_gralkor_empty_edge_candidate_guard', False):
          async def guarded_search(*args, **kwargs):
              search_filter = kwargs.get('search_filter')
              if (
                  guard.get()
                  and search_filter is not None
                  and search_filter.edge_uuids == []
              ):
                  return SearchResults()
              return await current_search(*args, **kwargs)

          guarded_search._gralkor_empty_edge_candidate_guard = True
          edge_operations.search = guarded_search
      None
      """,
      %{}
    )

    :ok
  end

  defp embedded_falkordb_socket_timeout({:embedded, _data_dir}, opts) do
    opts
    |> Keyword.get_lazy(
      :embedded_falkordb_socket_timeout_ms,
      &Config.embedded_falkordb_socket_timeout_ms/0
    )
    |> Config.validate_embedded_falkordb_socket_timeout_ms!()
    |> Kernel./(1_000)
  end

  defp embedded_falkordb_socket_timeout({:remote, _options}, _opts), do: nil

  defp construct_falkor_db(constructor, spec, socket_timeout) do
    case :erlang.fun_info(constructor, :arity) do
      {:arity, 1} -> constructor.(spec)
      {:arity, 2} -> constructor.(spec, socket_timeout)
    end
  end

  defp admit_next_episode_write(state, admission) do
    case :queue.out(admission.waiting) do
      {:empty, waiting} ->
        %{
          state
          | episode_write_admission: %{admission | owner: nil, monitor: nil, waiting: waiting}
        }

      {{:value, from}, waiting} ->
        owner = elem(from, 0)
        admission = %{admission | waiting: waiting}

        if Process.alive?(owner) do
          monitor = Process.monitor(owner)
          GenServer.reply(from, :acquired)

          %{
            state
            | episode_write_admission: %{admission | owner: owner, monitor: monitor}
          }
        else
          admit_next_episode_write(state, admission)
        end
    end
  end

  defp admit_next_episode_uuid_write(state, uuid, admission) do
    case :queue.out(admission.waiting) do
      {:empty, _waiting} ->
        %{state | episode_uuid_admissions: Map.delete(state.episode_uuid_admissions, uuid)}

      {{:value, from}, waiting} ->
        owner = elem(from, 0)
        admission = %{admission | waiting: waiting}

        if Process.alive?(owner) do
          monitor = Process.monitor(owner)
          GenServer.reply(from, :acquired)
          admission = %{admission | owner: owner, monitor: monitor}

          %{
            state
            | episode_uuid_admissions: Map.put(state.episode_uuid_admissions, uuid, admission)
          }
        else
          admit_next_episode_uuid_write(state, uuid, admission)
        end
    end
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

  defp default_construct_falkor_db({:embedded, data_dir}, socket_timeout) do
    db_path = Path.join(data_dir, "gralkor.db")

    {db, _} =
      Pythonx.eval(
        """
        from redislite.async_falkordb_client import AsyncFalkorDB
        AsyncFalkorDB(
          db_path.decode('utf-8') if isinstance(db_path, (bytes, bytearray)) else db_path,
          socket_timeout=socket_timeout,
        )
        """,
        %{"db_path" => db_path, "socket_timeout" => socket_timeout}
      )

    db
  end

  defp default_construct_falkor_db({:remote, kw}, _socket_timeout) do
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

    Logger.info(
      "[gralkor] warmup — search:#{search_ms} #{System.monotonic_time(:millisecond) - t0}ms"
    )

    case search_result do
      :ok -> :ok
      {:error, reason} -> log_warmup_failure(:search, reason)
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
