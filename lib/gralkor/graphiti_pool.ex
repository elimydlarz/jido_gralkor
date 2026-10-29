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

  See `test-trees/integration/graphiti-pool_TEST_TREES.md`.
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

  @episode_writer_hydration """
  async def hydrate_episode_writers(driver, episodes):
      from graphiti_core.driver.driver import GraphProvider
      if not episodes or getattr(driver, 'provider', None) != GraphProvider.FALKORDB:
          return
      records, _, _ = await driver.execute_query(
          'MATCH (e:Episodic) WHERE e.uuid IN $uuids '
          'RETURN e.uuid AS uuid, e._gralkor_writer AS writer',
          uuids=[episode.uuid for episode in episodes],
      )
      direct_ids = {record['uuid'] for record in records if record.get('writer') == 'direct'}
      for episode in episodes:
          if episode.uuid in direct_ids:
              episode.__dict__['_gralkor_writer'] = 'direct'
          else:
              episode.__dict__.pop('_gralkor_writer', None)
  """

  @pyproject_path Path.join([__DIR__, "..", "..", "priv", "python", "pyproject.toml"])
  @external_resource @pyproject_path
  @graphiti_core_version (case Regex.run(
                                 ~r/"graphiti-core(?:\[[^\]]*\])?==([^"]+)"/,
                                 File.read!(@pyproject_path)
                               ) do
                            [_, version] -> version
                          end)

  # graphiti-core 0.31.2's SearchFilters restricts edges by uuid but has no
  # node or episode uuid filter, its episode full-text search ignores the
  # filter entirely, and it renders several node labels as the label
  # expression `n:A|B`, which FalkorDB rejects. Pool start wraps graphiti's
  # filter constructors and episode full-text search once, before any search:
  #
  # * several node labels become `(n:A OR n:B)` for FalkorDB;
  # * a `LensSearchFilters` carrying `node_uuids` adds `n.uuid IN …` to every
  #   node search;
  # * one carrying `episode_uuids` runs the FalkorDB episode full-text query
  #   with `e.uuid IN …` before its limit.
  #
  # Without those fields every query is graphiti's own. These are graphiti
  # internals, so each wrapped or reused function is checked for its pinned
  # signature first and nothing is wrapped unless every check passes.
  @search_filters """
  def install_search_filters(pinned_version):
      import inspect
      import graphiti_core.search.search as search_module
      import graphiti_core.search.search_utils as search_utils
      import graphiti_core.driver.falkordb.operations.search_ops as falkor_search_ops
      from graphiti_core.driver.driver import GraphProvider
      from graphiti_core.search.search_filters import SearchFilters
      installed = getattr(search_utils, '_gralkor_search_filters', None)
      if installed is not None:
          return installed

      def unsupported(qualified, expected, found):
          raise RuntimeError(
              f'Gralkor search filters require {qualified}({", ".join(expected)}) '
              f'from graphiti-core {pinned_version}; found {found}'
          )

      def required(module, name, expected):
          qualified = f'{module.__name__}.{name}'
          function = getattr(module, name, None)
          if not callable(function):
              unsupported(qualified, expected, 'no such function')
          parameters = list(inspect.signature(function).parameters)
          if parameters != expected:
              unsupported(qualified, expected, f'{qualified}({", ".join(parameters)})')
          return function

      filter_parameters = ['filters', 'provider']
      episode_parameters = ['driver', 'query', '_search_filter', 'group_ids', 'limit']
      targets = [
          (search_utils, 'node_search_filter_query_constructor', filter_parameters, 'node'),
          (search_utils, 'edge_search_filter_query_constructor', filter_parameters, 'edge'),
          (falkor_search_ops, 'node_search_filter_query_constructor', filter_parameters, 'node'),
          (falkor_search_ops, 'edge_search_filter_query_constructor', filter_parameters, 'edge'),
          (search_module, 'episode_fulltext_search', episode_parameters, 'episode'),
      ]
      originals = [
          (module, name, required(module, name, expected), kind)
          for module, name, expected, kind in targets
      ]
      fulltext_query = required(search_utils, 'fulltext_query', ['query', 'group_ids', 'driver'])
      get_nodes_query = required(search_utils, 'get_nodes_query', ['name', 'query', 'limit', 'provider'])
      get_episodic_node_from_record = required(search_utils, 'get_episodic_node_from_record', ['record'])
      episode_return = getattr(search_utils, 'EPISODIC_NODE_RETURN', None)
      if not isinstance(episode_return, str):
          unsupported('graphiti_core.search.search_utils.EPISODIC_NODE_RETURN', [], 'no such query')

      class LensSearchFilters(SearchFilters):
          node_uuids: list[str] | None = None
          episode_uuids: list[str] | None = None

      def label_disjunction(queries, filters, provider):
          labels = list(filters.node_labels or [])
          if provider != GraphProvider.FALKORDB or len(labels) < 2:
              return queries
          joined = '|'.join(labels)
          rewritten = []
          for query in queries:
              for variable in ('n', 'm'):
                  query = query.replace(
                      f'{variable}:{joined}',
                      '(' + ' OR '.join(f'{variable}:{label}' for label in labels) + ')',
                  )
              rewritten.append(query)
          if rewritten == list(queries):
              raise RuntimeError(
                  f'graphiti-core {pinned_version} no longer renders several node labels as '
                  f'n:{joined}; Gralkor cannot rewrite them for FalkorDB'
              )
          return rewritten

      def node_constructor(original):
          def constructed(filters, provider):
              queries, params = original(filters, provider)
              queries = label_disjunction(list(queries), filters, provider)
              node_uuids = getattr(filters, 'node_uuids', None)
              if node_uuids is not None:
                  queries = queries + ['n.uuid IN $gralkor_node_uuids']
                  params = {**params, 'gralkor_node_uuids': list(node_uuids)}
              return queries, params
          constructed._gralkor_original = original
          return constructed

      def edge_constructor(original):
          def constructed(filters, provider):
              queries, params = original(filters, provider)
              return label_disjunction(list(queries), filters, provider), params
          constructed._gralkor_original = original
          return constructed

      def episode_search(original):
          async def episode_fulltext_search(driver, query, _search_filter, group_ids=None, limit=search_utils.RELEVANT_SCHEMA_LIMIT):
              episode_uuids = getattr(_search_filter, 'episode_uuids', None)
              if episode_uuids is None:
                  return await original(driver, query, _search_filter, group_ids, limit)
              if driver.search_interface or driver.provider != GraphProvider.FALKORDB:
                  raise RuntimeError(
                      f'Gralkor Lens search filters support only FalkorDB, not {driver.provider}'
                  )
              fuzzy_query = fulltext_query(query, group_ids, driver)
              if fuzzy_query == '':
                  return []
              params = {}
              group_filter = ''
              if group_ids is not None:
                  group_filter = '\\nAND e.group_id IN $group_ids'
                  params['group_ids'] = group_ids
              cypher = (
                  get_nodes_query('episode_content', '$query', limit=limit, provider=driver.provider)
                  + '\\nYIELD node AS episode, score'
                  + '\\nMATCH (e:Episodic)'
                  + '\\nWHERE e.uuid = episode.uuid AND e.uuid IN $gralkor_episode_uuids'
                  + group_filter
                  + '\\nRETURN\\n'
                  + episode_return
                  + '\\nORDER BY score DESC\\nLIMIT $limit'
              )
              records, _, _ = await driver.execute_query(
                  cypher,
                  query=fuzzy_query,
                  limit=limit,
                  routing_='r',
                  gralkor_episode_uuids=list(episode_uuids),
                  **params,
              )
              return [get_episodic_node_from_record(record) for record in records]
          episode_fulltext_search._gralkor_original = original
          return episode_fulltext_search

      wrap = {'node': node_constructor, 'edge': edge_constructor, 'episode': episode_search}
      wrapped = [(module, name, wrap[kind](function)) for module, name, function, kind in originals]
      for module, name, function in wrapped:
          setattr(module, name, function)
      search_utils._gralkor_search_filter_originals = [
          (module, name, function) for module, name, function, _kind in originals
      ]
      search_utils._gralkor_search_filters = LensSearchFilters
      return LensSearchFilters
  """

  @fact_rendering """
  async def render_facts(g, edges, lens_names=(), lens_suffixes=()):
      from graphiti_core.nodes import EpisodicNode
      episode_ids = list(dict.fromkeys(
          episode_id for edge in edges for episode_id in (getattr(edge, "episodes", None) or [])
      ))
      episodes = await EpisodicNode.get_by_uuids(g.driver, episode_ids) if episode_ids else []
      if episodes:
          await hydrate_episode_writers(g.driver, episodes)
      episodes_by_id = {episode.uuid: episode for episode in episodes}
      source_kinds = {
          "message": "conversation",
          "text": "document",
          "json": "structured_record",
      }

      endpoint_ids = list(dict.fromkeys(
          endpoint_id
          for edge in edges
          for endpoint_id in (getattr(edge, "source_node_uuid", None), getattr(edge, "target_node_uuid", None))
          if endpoint_id
      ))
      endpoint_names = {}
      if endpoint_ids:
          records, _, _ = await g.driver.execute_query(
              'MATCH (n:Entity) WHERE n.uuid IN $uuids RETURN n.uuid AS uuid, n.name AS name',
              uuids=endpoint_ids,
          )
          endpoint_names = {record['uuid']: record['name'] for record in records}

      def endpoint(endpoint_id):
          if not endpoint_id:
              return None
          return {"uuid": endpoint_id, "name": endpoint_names.get(endpoint_id)}

      rendered = []
      for edge in edges:
          fact = {
              "fact": edge.fact,
              "relationship": getattr(edge, "name", None),
              "source_node": endpoint(getattr(edge, "source_node_uuid", None)),
              "target_node": endpoint(getattr(edge, "target_node_uuid", None)),
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
                  "_gralkor_writer": getattr(episodes_by_id[episode_id], '_gralkor_writer', None),
              }
              for episode_id in (getattr(edge, "episodes", None) or [])
              if episode_id in episodes_by_id
              and (not lens_names or (episodes_by_id[episode_id].source_description or "").endswith(lens_suffixes))
          ]
          if sources:
              fact["sources"] = sources
          rendered.append(fact)

      return rendered
  """

  @upstream_failure_classification """
  def upstream_failure(error):
      import openai
      from google.genai.errors import APIError as GoogleAPIError
      from graphiti_core.llm_client.errors import (
          EmptyResponseError,
          RateLimitError,
          RefusalError,
      )
      chain = []
      current = error
      while current is not None and all(current is not seen for seen in chain):
          chain.append(current)
          current = current.__cause__
      for candidate in chain:
          if isinstance(candidate, (RateLimitError, openai.RateLimitError)) or (
              isinstance(candidate, GoogleAPIError) and candidate.code == 429
          ):
              return ['rate_limited', f'{type(candidate).__name__}: {candidate}']
      for candidate in chain:
          if isinstance(
              candidate,
              (openai.OpenAIError, GoogleAPIError, RefusalError, EmptyResponseError),
          ):
              return ['provider', f'{type(candidate).__name__}: {candidate}']
      return None
  """

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

  For retrieving custom-entity *nodes* as well, use `search_memory/5` — edge search's
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

        #{@episode_writer_hydration}
        #{@fact_rendering}
        q = query.decode('utf-8') if isinstance(query, (bytes, bytearray)) else query
        types = (
          [t.decode('utf-8') if isinstance(t, (bytes, bytearray)) else t for t in edge_types]
          if edge_types else None
        )
        async def search_with_sources():
          filters = SearchFilters(edge_types=types)
          edges = await g.search(q, num_results=max_results, search_filter=filters)

          return await render_facts(g, edges)

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
    e in Pythonx.Error -> {:error, {:python, summarise_python_error(e)}}
  end

  @doc """
  One memory search against `group_id` through ONE graphiti `search_` call.

  The config is graphiti's `COMBINED_HYBRID_SEARCH_RRF` recipe without its
  community layer: edges and nodes are each retrieved by BM25 plus cosine
  similarity and reranked by reciprocal rank fusion, and episodes by BM25.
  Graphiti applies one limit to every layer, so the search asks for the largest
  of `limits`, then cuts each kind to its own limit in relevance order. The
  query is embedded once for every kind.

  The search runs on the physically encoded group's own graph instance, whose
  driver is bound to that group's database, and passes no `group_ids`: content
  a Lens graph replacement inserted with any stored `group_id` is still found,
  as 11.2.0's edge search found it.

  One `SearchFilters(node_labels: …, edge_types: …)` applies to the whole
  search. Graphiti applies `node_labels` to nodes directly and to edges through
  both endpoints; `edge_types` restricts edges only; neither restricts episodes.
  A query longer than FalkorDB's full-text limit is cut to its earliest
  supported terms. A Reflection episode without its durable
  extraction-completion marker is excluded before the episode limit applies.

  Returns `{:ok, %{facts: [fact], nodes: [node], episodes: [episode]}}`: facts
  rendered as `search/5` renders them, nodes as `%{name:, summary:,
  attributes:}`, and episodes as `%{content:, source_description:,
  source_kind:}` plus `writer: :direct` for durable direct writes.

  ## Options

    * `:node_labels` — optional `[String.t()]` entity-type labels.
    * `:edge_types` — optional `[String.t()]` relationship names.
    * `:lenses` — optional `[String.t()]` Lens names. Episodes are restricted
      to those whose source description ends with a selected ` [lens: NAME]`
      marker (never a durable direct write); edges to those drawn from such an
      episode or carrying a selected `_gralkor_lens`; nodes to those such an
      episode `MENTIONS` or carrying a selected `_gralkor_lens`. Edges use
      `SearchFilters.edge_uuids`; nodes and episodes use the `node_uuids` and
      `episode_uuids` that `install_lens_search_filters` adds to graphiti's
      node and FalkorDB episode full-text queries, so every restriction applies
      before ranking and limits. Fact sources keep only selected-Lens episodes.
      When nothing in the group matches, no graph search runs and every kind
      is empty.
  """
  @spec search_memory(
          GenServer.server(),
          String.t(),
          String.t(),
          %{facts: pos_integer(), nodes: pos_integer(), episodes: pos_integer()},
          keyword()
        ) :: {:ok, %{facts: [map()], nodes: [map()], episodes: [map()]}} | {:error, term()}
  def search_memory(server \\ __MODULE__, group_id, query, limits, opts \\ [])

  def search_memory(
        server,
        group_id,
        query,
        %{facts: facts, nodes: nodes, episodes: episodes} = limits,
        opts
      )
      when is_binary(group_id) and is_binary(query) and is_integer(facts) and facts > 0 and
             is_integer(nodes) and nodes > 0 and is_integer(episodes) and episodes > 0 and
             is_list(opts) do
    instance = __MODULE__.for(server, group_id)

    {raw, _} =
      Pythonx.eval(
        """
        import asyncio
        from graphiti_core.driver.falkordb import STOPWORDS
        from graphiti_core.driver.falkordb.fulltext import (
          MAX_QUERY_LENGTH,
          sanitize_falkor_fulltext_query,
        )
        from graphiti_core.search.search_config_recipes import COMBINED_HYBRID_SEARCH_RRF
        from graphiti_core.search.search_filters import SearchFilters

        import graphiti_core.search.search_utils as search_utils

        #{@episode_writer_hydration}
        #{@fact_rendering}
        LensSearchFilters = search_utils._gralkor_search_filters
        if LensSearchFilters is None:
          raise RuntimeError('Gralkor search filters are not installed; start Gralkor.GraphitiPool first')

        def text(value):
          return value.decode('utf-8') if isinstance(value, (bytes, bytearray)) else value

        q = text(query)
        labels = [text(label) for label in node_labels] if node_labels else None
        types = [text(edge_type) for edge_type in edge_types] if edge_types else None
        lens_names = [text(name) for name in lenses] if lenses else []
        lens_suffixes = tuple(f' [lens: {name}]' for name in lens_names)
        supported_query_terms = [
          word
          for word in sanitize_falkor_fulltext_query(q).split()
          if word.lower() not in STOPWORDS
        ]
        if max(0, len(supported_query_terms) * 2 - 1) + 1 >= MAX_QUERY_LENGTH:
          q = ' '.join(supported_query_terms[:(MAX_QUERY_LENGTH - 1) // 2])

        config = COMBINED_HYBRID_SEARCH_RRF.model_copy(deep=True)
        config.community_config = None
        config.limit = max(fact_limit, node_limit, episode_limit)

        def lens_episode(episode):
          source_description = episode.source_description or ''
          lens_marker = ' [lens: '
          lens_start = source_description.rfind(lens_marker)
          return (
            lens_start >= 0
            and source_description.endswith(']')
            and bool(source_description[lens_start + len(lens_marker):-1])
          )

        def direct_episode(episode):
          return getattr(episode, '_gralkor_writer', None) == 'direct'

        def reflection_episode(episode):
          source_description = episode.source_description or ''
          return (
            not direct_episode(episode)
            and not source_description.endswith(' [gralkor: direct]')
            and not lens_episode(episode)
            and source_description.startswith('reflection:')
            and bool(source_description[len('reflection:'):])
          )

        async def completed_reflection_episodes(episodes):
          episode_ids = [e.uuid for e in episodes if reflection_episode(e)]
          if not episode_ids:
            return episodes
          if hasattr(g.driver, 'execute_query'):
            records, _, _ = await g.driver.execute_query(
              "MATCH (e:Episodic) WHERE e.uuid IN $uuids AND coalesce(e._gralkor_extraction_complete, false) = true RETURN e.uuid AS uuid",
              uuids=episode_ids,
            )
            completed_ids = {record['uuid'] for record in records}
          else:
            completed_ids = set(getattr(g.driver, '_gralkor_completed_episode_uuids', set()))
          return [e for e in episodes if not reflection_episode(e) or e.uuid in completed_ids]

        def episode_result(episode):
          result = {
            "content": episode.content,
            "source_description": episode.source_description,
          }
          if direct_episode(episode):
            result["_gralkor_writer"] = "direct"
          source = getattr(episode, 'source', None)
          if source is not None:
            result['source_kind'] = {'message': 'conversation', 'text': 'document', 'json': 'structured_record'}.get(source.value)
          return result

        async def lens_scope():
          def uuids(records):
            return list(dict.fromkeys(
              record['uuid'] for record in records if record['uuid'] is not None
            ))

          episode_records, _, _ = await g.driver.execute_query(
            '''
            MATCH (episode:Episodic)
            WHERE any(suffix IN $lens_suffixes WHERE episode.source_description ENDS WITH suffix)
              AND episode.uuid IS NOT NULL
            RETURN episode.uuid AS uuid
            ''',
            lens_suffixes=list(lens_suffixes),
          )
          episode_uuids = uuids(episode_records)
          edge_records, _, _ = await g.driver.execute_query(
            '''
            MATCH (:Entity)-[edge:RELATES_TO]->(:Entity)
            WHERE (edge._gralkor_lens IN $lens_names
              OR any(id IN coalesce(edge.episodes, []) WHERE id IN $episode_uuids))
              AND edge.uuid IS NOT NULL
            RETURN edge.uuid AS uuid
            ''',
            lens_names=lens_names,
            episode_uuids=episode_uuids,
          )
          mentioned_records, _, _ = await g.driver.execute_query(
            '''
            MATCH (episode:Episodic)-[:MENTIONS]->(node:Entity)
            WHERE episode.uuid IN $episode_uuids AND node.uuid IS NOT NULL
            RETURN node.uuid AS uuid
            ''',
            episode_uuids=episode_uuids,
          )
          owned_records, _, _ = await g.driver.execute_query(
            'MATCH (node:Entity) WHERE node._gralkor_lens IN $lens_names AND node.uuid IS NOT NULL '
            'RETURN node.uuid AS uuid',
            lens_names=lens_names,
          )
          return (
            episode_uuids,
            uuids(edge_records),
            uuids(mentioned_records + owned_records),
          )

        async def search_memory():
          if lens_names:
            episode_uuids, edge_uuids, node_uuids = await lens_scope()
            if not (episode_uuids or edge_uuids or node_uuids):
              return {"facts": [], "nodes": [], "episodes": []}
            search_filter = LensSearchFilters(
              node_labels=labels,
              edge_types=types,
              edge_uuids=edge_uuids,
              node_uuids=node_uuids,
              episode_uuids=episode_uuids,
            )
          else:
            search_filter = SearchFilters(node_labels=labels, edge_types=types)
          results = await g.search_(q, config=config, search_filter=search_filter)
          facts = await render_facts(g, list(results.edges)[:fact_limit], lens_names, lens_suffixes)
          nodes = [
            {
              "name": n.name,
              "summary": n.summary,
              "attributes": {k: str(v) for k, v in (n.attributes or {}).items()},
            }
            for n in list(results.nodes)[:node_limit]
          ]
          episodes = list(results.episodes)
          if episodes:
            await hydrate_episode_writers(getattr(g, 'driver', None), episodes)
          episodes = (await completed_reflection_episodes(episodes))[:episode_limit]
          return {
            "facts": facts,
            "nodes": nodes,
            "episodes": [episode_result(e) for e in episodes],
          }

        asyncio._gralkor_run(search_memory())
        """,
        %{
          "g" => instance,
          "query" => query,
          "fact_limit" => limits.facts,
          "node_limit" => limits.nodes,
          "episode_limit" => limits.episodes,
          "node_labels" => Keyword.get(opts, :node_labels),
          "edge_types" => Keyword.get(opts, :edge_types),
          "lenses" => Keyword.get(opts, :lenses)
        }
      )

    %{"facts" => facts, "nodes" => nodes, "episodes" => episodes} = Pythonx.decode(raw)

    {:ok,
     %{
       facts: Enum.map(facts, &atomize_keys/1),
       nodes: Enum.map(nodes, &node_map/1),
       episodes: Enum.map(episodes, &episode_map/1)
     }}
  rescue
    e in Pythonx.Error -> {:error, {:python, summarise_python_error(e)}}
  end

  defp episode_map(%{} = m) do
    episode = %{
      content: Map.get(m, "content"),
      source_description: Map.get(m, "source_description")
    }

    episode =
      if Map.has_key?(m, "source_kind"),
        do: Map.put(episode, :source_kind, m["source_kind"]),
        else: episode

    if Map.get(m, "_gralkor_writer") == "direct",
      do: Map.put(episode, :writer, :direct),
      else: episode
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

    direct_writer = Keyword.get(opts, :writer) == :direct

    source_description =
      if direct_writer do
        source_description <> " [gralkor: direct]"
      else
        lens_source_description(source_description, Keyword.get(opts, :lens))
      end

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
      with_episode_write_admission(server, uuid, fn ->
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
                    if fence is not None and fence.get('writer') == 'direct':
                        self.__dict__['_gralkor_writer'] = 'direct'
                        if not fence.get('distributed') and getattr(driver, 'provider', None) == GraphProvider.FALKORDB:
                            episode = dict(self)
                            episode['source'] = self.source.value
                            episode['_gralkor_writer'] = 'direct'
                            episode.pop('labels', None)
                            return await driver.execute_query(
                                'MERGE (e:Episodic {uuid: $uuid}) SET e = $episode RETURN e.uuid AS uuid',
                                uuid=self.uuid,
                                episode=episode,
                            )
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
                    if fence is not None and fence.get('writer') == 'direct':
                        for episode in episodic_nodes:
                            episode.__dict__['_gralkor_writer'] = 'direct'
                    if (
                        fence is None
                        or (not fence.get('distributed') and fence.get('writer') != 'direct')
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
                            _gralkor_writer='direct' if guard.get() and guard.get().get('writer') == 'direct' else None,
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

                    distributed = bool(fence.get('distributed'))
                    params = dict(
                        claim_uuid=fence['uuid'],
                        owner=fence['owner'],
                        generation=fence['generation'],
                    ) if distributed else {}
                    clauses = [
                        '''
                        MATCH (claim:_GralkorEpisodeClaim {uuid: $claim_uuid})
                        WHERE claim.owner = $owner AND claim.generation = $generation
                        SET claim._gralkor_fenced_generation = $generation
                        WITH claim
                        '''
                    ] if distributed else ['WITH 1 AS claim']

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
                              _gralkor_writer: ${parameter}._gralkor_writer
                              {', _gralkor_extraction_complete: true' if distributed else ''}
                            }}
                            WITH claim
                        ''')

                    for index, node in enumerate(nodes):
                        parameter = f'entity_node_{index}'
                        variable = f'entity_node_{index}'
                        labels = ':'.join(
                            '`' + label.replace('`', '``') + '`'
                            for label in node.pop('labels')
                        )
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
                        if distributed else
                        'RETURN claim AS completed /* gralkor_direct_graph_effects */'
                    )
                    records, _, _ = await driver.execute_query(
                        '\\n'.join(clauses),
                        **params,
                    )
                    if distributed and not records:
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
                            writer='direct' if direct_writer else None,
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

                        try:
                            await g.add_episode(**kwargs)
                            await record_extraction_complete()
                            return 'created'
                        finally:
                            guard.reset(token)
                    finally:
                        heartbeat.cancel()
                        try:
                            await heartbeat
                        except asyncio.CancelledError:
                            pass
                        await release_claim()
                else:
                    token = guard.set(
                        {'writer': 'direct', 'uuid': None, 'distributed': False}
                        if direct_writer else None
                    )

                try:
                    await g.add_episode(**kwargs)
                    return 'created'
                finally:
                    if token is not None:
                        guard.reset(token)
            #{@upstream_failure_classification}
            try:
                result = asyncio._gralkor_run(add_episode())
            except BaseException as e:
                print(f"[gralkor] add_episode failed: {type(e).__name__}: {(str(e).splitlines() or [''])[0]}", file=sys.stderr)
                upstream = upstream_failure(e)
                if upstream is None:
                    raise
                result = upstream
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
              "direct_writer" => direct_writer,
              "extraction_instructions" => extraction_instructions
            }
          )

        Pythonx.decode(raw)
      end)

    case result do
      "conflict" -> {:error, {:episode_conflict, uuid}}
      ["rate_limited", detail] -> {:error, {:upstream_llm, {:rate_limited, detail}}}
      ["provider", detail] -> {:error, {:upstream_llm, {:provider, detail}}}
      _ -> :ok
    end
  rescue
    e in Pythonx.Error -> {:error, {:python, summarise_python_error(e)}}
  end

  defp with_episode_write_admission(server, uuid, operation) do
    with_uuid_write_admission(server, uuid, fn ->
      case GenServer.call(server, :acquire_episode_write, :infinity) do
        :unbounded ->
          operation.()

        :acquired ->
          try do
            operation.()
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
          print(f"[gralkor] remove_episode failed: {type(e).__name__}: {(str(e).splitlines() or [''])[0]}", file=sys.stderr)
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
    e in Pythonx.Error -> {:error, {:python, summarise_python_error(e)}}
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
    e in Pythonx.Error -> {:error, {:python, summarise_python_error(e)}}
  end

  defp install_search_filters! do
    Pythonx.eval(
      """
      #{@search_filters}
      install_search_filters(pinned_version.decode('utf-8'))
      None
      """,
      %{"pinned_version" => @graphiti_core_version}
    )

    :ok
  rescue
    e in Pythonx.Error -> raise RuntimeError, summarise_python_error(e)
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

  # Each role — llm, LLM route, reranker, and embedder — picks its provider from
  # its own spec, so an OpenAI LLM alongside a Google embedder is a supported
  # pair. An unconfigured reranker follows the llm role's provider.
  @supported_providers [:openai, :google]
  @credential_env %{openai: "OPENAI_API_KEY", google: "GOOGLE_API_KEY"}

  # Which providers' clients accept each LLM tuning setting.
  @tuning_providers %{
    temperature: [:openai, :google],
    max_tokens: [:openai, :google],
    reasoning: [:openai],
    verbosity: [:openai],
    thinking_budget: [:google]
  }

  @doc false
  @spec supported_providers() :: [atom()]
  def supported_providers, do: @supported_providers

  @doc """
  The inference settings the pool builds its clients from: the LLM and embedder
  specs plus the optional reranker, LLM routes, LLM tuning, embedder dimension,
  and embedder batch size. Each option absent from `opts` is read from
  `Gralkor.Config`.
  """
  @spec inference_settings(keyword()) :: map()
  def inference_settings(opts) do
    %{
      llm: Keyword.get_lazy(opts, :llm_model, &Config.llm_model/0),
      embedder: Keyword.get_lazy(opts, :embedder_model, &Config.embedder_model/0),
      reranker: Keyword.get_lazy(opts, :reranker_model, &Config.reranker_model/0),
      llm_routes: Keyword.get_lazy(opts, :llm_routes, &Config.llm_routes/0),
      llm_tuning: Keyword.get_lazy(opts, :llm_tuning, &Config.llm_tuning/0),
      embedder_dimension:
        Keyword.get_lazy(opts, :embedder_dimension, &Config.embedder_dimension/0),
      embedder_batch_size:
        Keyword.get_lazy(opts, :embedder_batch_size, &Config.embedder_batch_size/0)
    }
  end

  @doc """
  Decide how each shared client is built. Pure — no Pythonx, no credentials
  read — so the per-role dispatch is pinned deterministically and
  `default_construct_shared_clients/1` is left with nothing to decide.

  Accepts the two role specs plus optional settings (see
  `inference_settings/1`), or a complete settings map.

  Each role takes its own spec's provider. `:llm_clients` lists one client per
  distinct provider and tuning; the LLM and every route name theirs by index,
  so routes sharing a provider and tuning share one client, and the LLM's own
  tuning reaches only the LLM's client. An unconfigured reranker follows the
  LLM's provider with no model of its own. A Google embedder carries
  `:batch_size`, 1 unless configured; the OpenAI embedder takes none.
  """
  @spec shared_client_spec(map(), map(), map()) :: map()
  def shared_client_spec(llm_model, embedder_model, settings \\ %{}) do
    settings
    |> Map.merge(%{llm: llm_model, embedder: embedder_model})
    |> shared_client_spec()
  end

  @spec shared_client_spec(map()) :: map()
  def shared_client_spec(settings) do
    llm = model_spec(settings.llm)
    llm_tuning = Map.get(settings, :llm_tuning, %{})

    routes =
      settings
      |> Map.get(:llm_routes, %{})
      |> Enum.sort_by(fn {key, _route} -> key end)
      |> Enum.map(fn {key, route} ->
        Map.merge(model_spec(route.model), %{key: key, tuning: route.tuning})
      end)

    llm = Map.put(llm, :tuning, llm_tuning)

    llm_clients =
      [llm | routes]
      |> Enum.map(&%{provider: &1.provider, id: &1.id, tuning: &1.tuning})
      |> Enum.uniq_by(&{&1.provider, &1.tuning})

    client_index = fn model ->
      Enum.find_index(llm_clients, &(&1.provider == model.provider and &1.tuning == model.tuning))
    end

    %{
      llm: Map.put(llm, :client, client_index.(llm)),
      routes: Enum.map(routes, &Map.put(&1, :client, client_index.(&1))),
      llm_clients: llm_clients,
      cross_encoder: cross_encoder_spec(Map.get(settings, :reranker), llm),
      embedder: embedder_spec(settings)
    }
  end

  defp model_spec(model), do: %{provider: model[:provider], id: model[:id]}

  defp cross_encoder_spec(nil, llm), do: %{provider: llm.provider, id: nil}
  defp cross_encoder_spec(reranker, _llm), do: model_spec(reranker)

  # gemini-embedding-2-preview returns ONE embedding for N inputs in a single
  # call — graphiti's batched create_batch then fails with "zip() argument 2 is
  # shorter than argument 1". An unconfigured Google embedder therefore sends
  # one input per request (getzep/graphiti#1467). OpenAI's embedder unpacks
  # result.data 1:1 and exposes no batch_size.
  defp embedder_spec(settings) do
    embedder = settings.embedder

    base = %{
      provider: embedder[:provider],
      id: embedder[:id],
      dimension: Map.get(settings, :embedder_dimension)
    }

    case embedder[:provider] do
      :google -> Map.put(base, :batch_size, Map.get(settings, :embedder_batch_size) || 1)
      _ -> base
    end
  end

  @doc false
  @spec validate_native_models!(map(), map()) :: :ok
  def validate_native_models!(llm_model, embedder_model),
    do: validate_native_models!(%{llm: llm_model, embedder: embedder_model})

  @doc false
  @spec validate_native_models!(map()) :: :ok
  def validate_native_models!(settings) do
    roles = model_roles(settings)

    validate_supported_providers!(roles)
    validate_tuning!(settings)
    # Only a provider some role actually selected needs a credential — an unused
    # provider's absent key is not a misconfiguration.
    Enum.each(roles, &validate_credential!/1)

    :ok
  end

  defp model_roles(settings) do
    reranker =
      case Map.get(settings, :reranker) do
        nil -> []
        model -> [{"reranker", model}]
      end

    routes =
      settings
      |> Map.get(:llm_routes, %{})
      |> Enum.sort_by(fn {key, _route} -> key end)
      |> Enum.map(fn {key, route} -> {"llm route #{inspect(key)}", route.model} end)

    [{"llm", settings.llm}, {"embedder", settings.embedder}] ++ reranker ++ routes
  end

  defp validate_supported_providers!(roles) do
    unless Enum.all?(roles, fn {_role, model} -> model[:provider] in @supported_providers end) do
      supported = Enum.map_join(@supported_providers, ", ", &inspect/1)
      specs = Enum.map_join(roles, ", ", fn {role, model} -> "#{role}=#{inspect(model)}" end)

      raise ArgumentError,
            "Gralkor.GraphitiPool native Graphiti supports #{supported} models; got #{specs}"
    end

    :ok
  end

  defp validate_tuning!(settings) do
    Enum.each(Map.get(settings, :llm_tuning, %{}), fn {setting, _value} ->
      validate_tuning_setting!(
        setting,
        settings.llm,
        "GRALKOR_LLM_#{setting |> Atom.to_string() |> String.upcase()} is configured",
        "the llm model spec"
      )
    end)

    Enum.each(Map.get(settings, :llm_routes, %{}), fn {key, route} ->
      Enum.each(route.tuning, fn {setting, _value} ->
        validate_tuning_setting!(
          setting,
          route.model,
          "GRALKOR_LLM_ROUTES route #{inspect(key)} sets #{setting}",
          "its model spec"
        )
      end)
    end)

    if Map.get(settings, :embedder_batch_size) != nil and settings.embedder[:provider] != :google do
      raise_rejected_tuning!(
        "GRALKOR_EMBEDDER_BATCH_SIZE is configured",
        "the embedder model spec",
        settings.embedder
      )
    end

    :ok
  end

  defp validate_tuning_setting!(setting, model, configured, role) do
    unless model[:provider] in Map.fetch!(@tuning_providers, setting) do
      raise_rejected_tuning!(configured, role, model)
    end
  end

  defp raise_rejected_tuning!(configured, role, model) do
    raise ArgumentError,
          "#{configured}, but the #{inspect(model[:provider])} provider of #{role} " <>
            "#{inspect(model)} does not accept it"
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

  @fact_keys ~w(fact relationship source_node target_node created_at valid_at invalid_at expired_at sources)a
  @fact_keys_strings Enum.map(@fact_keys, &Atom.to_string/1)
  @source_keys ~w(id source_kind source_description _gralkor_writer)a
  @source_keys_strings Enum.map(@source_keys, &Atom.to_string/1)

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if k in @fact_keys_strings, do: String.to_atom(k), else: k

      v =
        case key do
          :sources -> Enum.map(v, &atomize_source_keys/1)
          endpoint when endpoint in [:source_node, :target_node] -> endpoint_map(v)
          _ -> v
        end

      {key, v}
    end)
  end

  defp endpoint_map(%{} = endpoint),
    do: %{uuid: Map.get(endpoint, "uuid"), name: Map.get(endpoint, "name")}

  defp endpoint_map(nil), do: nil

  defp atomize_source_keys(map) do
    source =
      Map.new(map, fn {key, value} ->
        key = if key in @source_keys_strings, do: String.to_atom(key), else: key
        {key, value}
      end)

    case source do
      %{source_description: description} when is_binary(description) ->
        if source[:_gralkor_writer] == "direct" do
          source
          |> Map.put(
            :source_description,
            String.replace_suffix(description, " [gralkor: direct]", "")
          )
          |> Map.put(:writer, :direct)
          |> Map.delete(:_gralkor_writer)
        else
          Map.delete(source, :_gralkor_writer)
        end

      _ ->
        source
    end
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

        #{@episode_writer_hydration}
        uid = episode_uuid.decode('utf-8') if isinstance(episode_uuid, (bytes, bytearray)) else episode_uuid
        async def get_episode():
            try:
                episode = await EpisodicNode.get_by_uuid(g.driver, uid)
            except NodeNotFoundError:
                return None

            await hydrate_episode_writers(g.driver, [episode])
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
                **({'_gralkor_writer': 'direct'} if getattr(episode, '_gralkor_writer', None) == 'direct' else {}),
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
    Process.flag(:trap_exit, true)
    table = Keyword.get(opts, :table, @default_table)
    falkordb_spec = Keyword.fetch!(opts, :falkordb_spec)
    inference = inference_settings(opts)
    validate_native_models!(inference)
    install_search_filters!()

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
      Keyword.get(opts, :construct_shared_clients, &default_construct_shared_clients/1)

    construct_instance = Keyword.get(opts, :construct_instance, &default_construct_instance/3)
    initialise_instance = Keyword.get(opts, :initialise_instance, &initialise_instance/1)
    warmup? = Keyword.get(opts, :warmup, true)
    install_loop_fn = Keyword.get(opts, :install_loop_fn, &Gralkor.Python.install_async_runtime/0)

    :ets.new(table, [:set, :public, :named_table, read_concurrency: true])
    register_table(self(), table)

    :ok = install_loop_fn.()

    shared = construct_shared_clients.(shared_client_spec(inference))

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

  # Graphiti refuses an LLM runtime combined with an LLM client, so an instance
  # receives exactly one: the runtime when routes are configured, otherwise the
  # LLM client, which keeps Graphiti's own main/small model split.
  defp default_construct_instance(falkor_db, shared, sanitized_group_id) do
    {instance, _} =
      Pythonx.eval(
        """
        import asyncio
        from graphiti_core import Graphiti
        from graphiti_core.driver.falkordb_driver import FalkorDriver
        gid = group_id.decode('utf-8') if isinstance(group_id, (bytes, bytearray)) else group_id
        driver = FalkorDriver(falkor_db=falkor_db, database=gid)
        if llm_runtime is not None:
            inference = dict(llm_runtime=llm_runtime)
        else:
            inference = dict(llm_client=llm_client)
        g = Graphiti(
          graph_driver=driver,
          embedder=embedder,
          cross_encoder=cross_encoder,
          **inference,
        )
        g
        """,
        %{
          "falkor_db" => falkor_db,
          "group_id" => sanitized_group_id,
          "llm_client" => Map.get(shared, :llm_client),
          "llm_runtime" => Map.get(shared, :llm_runtime),
          "embedder" => Map.get(shared, :embedder),
          "cross_encoder" => Map.get(shared, :cross_encoder)
        }
      )

    instance
  end

  defp default_construct_shared_clients(spec) do
    # A Google role needs one shared genai.Client threaded through its
    # constructors; the OpenAI clients build their own AsyncOpenAI internally.
    genai_client = if :google in providers(spec), do: construct_genai_client()

    llm_clients = Enum.map(spec.llm_clients, &construct_llm_client(&1, genai_client))
    llm = Enum.at(llm_clients, spec.llm.client)

    %{
      llm_client: llm,
      llm_runtime: construct_llm_runtime(spec, llm_clients),
      embedder: construct_embedder(spec.embedder, genai_client),
      cross_encoder: construct_cross_encoder(spec.cross_encoder, genai_client)
    }
  end

  defp providers(spec) do
    Enum.map(spec.llm_clients, & &1.provider) ++
      [spec.embedder.provider, spec.cross_encoder.provider]
  end

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

  # Elixir binaries cross into Python as bytes.
  @python_text "text = lambda value: value.decode('utf-8') if isinstance(value, (bytes, bytearray)) else value"

  # One client per distinct provider and tuning. Only configured tuning is
  # passed, so every unset setting keeps the graph library's own default.
  defp construct_llm_client(%{provider: :google, id: id, tuning: tuning}, genai_client) do
    {llm, _} =
      Pythonx.eval(
        """
        #{@python_text}
        import json
        from google.genai import types
        from graphiti_core.llm_client.config import LLMConfig
        from graphiti_core.llm_client.gemini_client import GeminiClient
        t = json.loads(tuning)
        config = dict(model=text(model_id))
        if 'temperature' in t:
            config['temperature'] = t['temperature']
        if 'max_tokens' in t:
            config['max_tokens'] = t['max_tokens']
        options = {}
        if 'max_tokens' in t:
            options['max_tokens'] = t['max_tokens']
        if 'thinking_budget' in t:
            options['thinking_config'] = types.ThinkingConfig(thinking_budget=t['thinking_budget'])
        GeminiClient(config=LLMConfig(**config), client=client, **options)
        """,
        %{"model_id" => id, "client" => genai_client, "tuning" => Jason.encode!(tuning)}
      )

    llm
  end

  defp construct_llm_client(%{provider: :openai, id: id, tuning: tuning}, _genai_client) do
    {llm, _} =
      Pythonx.eval(
        """
        #{@python_text}
        import json
        from graphiti_core.llm_client.config import LLMConfig
        from graphiti_core.llm_client.openai_client import OpenAIClient
        t = json.loads(tuning)
        config = dict(model=text(model_id), api_key=text(api_key))
        if 'temperature' in t:
            config['temperature'] = t['temperature']
        if 'max_tokens' in t:
            config['max_tokens'] = t['max_tokens']
        options = {key: t[key] for key in ('max_tokens', 'reasoning', 'verbosity') if key in t}
        OpenAIClient(config=LLMConfig(**config), **options)
        """,
        %{"model_id" => id, "api_key" => api_key!(:openai), "tuning" => Jason.encode!(tuning)}
      )

    llm
  end

  # Without routes Graphiti receives the LLM client alone. With routes, one
  # LLMTransport wraps each distinct client; the LLM spec is the runtime's
  # default model and each route key becomes a whole-group route or, for a
  # group-qualified prompt, a field of that group's nested routes class whose
  # `default` is the group-level route.
  defp construct_llm_runtime(%{routes: []}, _llm_clients), do: nil

  defp construct_llm_runtime(spec, llm_clients) do
    {runtime, _} =
      Pythonx.eval(
        """
        #{@python_text}
        import json
        from graphiti_core.llm_client import LLMRuntime, LLMTransport, PromptRoutes
        transports = [LLMTransport(client) for client in clients]
        default = json.loads(default_model)
        groups = {}
        for route in json.loads(routes):
            group, _, prompt = route['key'].partition('.')
            model = transports[route['client']].model(route['id'])
            groups.setdefault(group, {})[prompt or 'default'] = model
        group_routes = {}
        for group, models in groups.items():
            if list(models) == ['default']:
                group_routes[group] = models['default']
            else:
                nested = getattr(PromptRoutes, ''.join(part.capitalize() for part in group.split('_')))
                group_routes[group] = nested(**models)
        LLMRuntime(
            model=transports[default['client']].model(default['id']),
            routes=PromptRoutes(**group_routes),
        )
        """,
        %{
          "clients" => llm_clients,
          "default_model" => Jason.encode!(Map.take(spec.llm, [:id, :client])),
          "routes" => Jason.encode!(Enum.map(spec.routes, &Map.take(&1, [:key, :id, :client])))
        }
      )

    runtime
  end

  defp construct_embedder(%{provider: :google} = embedder, genai_client) do
    {client, _} =
      Pythonx.eval(
        """
        #{@python_text}
        from graphiti_core.embedder.gemini import GeminiEmbedder, GeminiEmbedderConfig
        config = dict(embedding_model=text(embedder_id))
        if dimension is not None:
            config['embedding_dim'] = dimension
        GeminiEmbedder(GeminiEmbedderConfig(**config), client=client, batch_size=batch_size)
        """,
        %{
          "embedder_id" => embedder.id,
          "dimension" => embedder.dimension,
          "batch_size" => embedder.batch_size,
          "client" => genai_client
        }
      )

    client
  end

  # OpenAIEmbedder unpacks result.data 1:1 from a single batched call and takes
  # no batch_size parameter. It slices each vector to EmbedderConfig's
  # embedding_dim (the graph library's default unless a dimension is
  # configured), which text-embedding-3's Matryoshka training makes safe, but
  # the truncation is silent — unlike Gemini, which asks for the dimension
  # explicitly via output_dimensionality.
  defp construct_embedder(%{provider: :openai} = embedder, _genai_client) do
    {client, _} =
      Pythonx.eval(
        """
        #{@python_text}
        from graphiti_core.embedder.openai import OpenAIEmbedder, OpenAIEmbedderConfig
        config = dict(embedding_model=text(embedder_id), api_key=text(api_key))
        if dimension is not None:
            config['embedding_dim'] = dimension
        OpenAIEmbedder(OpenAIEmbedderConfig(**config))
        """,
        %{
          "embedder_id" => embedder.id,
          "dimension" => embedder.dimension,
          "api_key" => api_key!(:openai)
        }
      )

    client
  end

  # A reranker without a configured model passes none, so the graph library's
  # default reranker model applies.
  defp construct_cross_encoder(%{provider: :google, id: id}, genai_client) do
    {cross_encoder, _} =
      Pythonx.eval(
        """
        #{@python_text}
        from graphiti_core.cross_encoder.gemini_reranker_client import GeminiRerankerClient
        from graphiti_core.llm_client.config import LLMConfig
        model = text(model_id)
        GeminiRerankerClient(config=LLMConfig(model=model), client=client)
        """,
        %{"model_id" => id, "client" => genai_client}
      )

    cross_encoder
  end

  defp construct_cross_encoder(%{provider: :openai, id: id}, _genai_client) do
    {cross_encoder, _} =
      Pythonx.eval(
        """
        #{@python_text}
        from graphiti_core.cross_encoder.openai_reranker_client import OpenAIRerankerClient
        from graphiti_core.llm_client.config import LLMConfig
        model = text(model_id)
        OpenAIRerankerClient(config=LLMConfig(model=model, api_key=text(api_key)))
        """,
        %{"model_id" => id, "api_key" => api_key!(:openai)}
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
    e in Pythonx.Error -> {:error, summarise_python_error(e)}
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
