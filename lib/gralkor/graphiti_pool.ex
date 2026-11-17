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
          'RETURN e.uuid AS uuid, e._gralkor_writer AS writer, e._gralkor_writers AS writers',
          uuids=[episode.uuid for episode in episodes],
      )
      by_uuid = {record['uuid']: record for record in records}
      for episode in episodes:
          record = by_uuid.get(episode.uuid, {})
          if record.get('writer') == 'direct':
              episode.__dict__['_gralkor_writer'] = 'direct'
          else:
              episode.__dict__.pop('_gralkor_writer', None)
          episode.__dict__['_gralkor_writers'] = list(record.get('writers') or [])
  """

  # Every Episodic, RELATES_TO edge, and Entity node carries `_gralkor_writers`:
  # an episode its one writer, an edge the writers of every episode in its
  # `episodes`, and an entity the writers of every episode that MENTIONS it.
  # graphiti saves nodes and edges by replacing their properties, so after each
  # episode write the touched nodes and edges are recomputed from their
  # episodes, which unions writers instead of overwriting them. Memory written
  # before writers were recorded is tagged in place, in batches, when its graph
  # instance is initialised; only elements lacking the property are touched.
  @writer_recording """
  def episode_writer(source_description, durable_writer=None):
      description = source_description or ''
      if durable_writer == 'direct' or description.endswith(' [gralkor: direct]'):
          return 'direct'
      marker = ' [lens: '
      start = description.rfind(marker)
      if start >= 0 and description.endswith(']') and description[start + len(marker):-1]:
          return 'lens:' + description[start + len(marker):-1]
      if description.startswith('reflection:') and description[len('reflection:'):]:
          return description
      return 'unknown'

  GRALKOR_WRITER_UNION = '''
  WITH gralkor_target, collect(
    CASE WHEN gralkor_episode IS NULL THEN null
    ELSE coalesce(gralkor_episode._gralkor_writers, ['unknown']) END
  ) AS gralkor_lists
  WITH gralkor_target, reduce(
    gralkor_union = [], gralkor_list IN gralkor_lists |
    gralkor_union + [gralkor_writer IN gralkor_list WHERE NOT gralkor_writer IN gralkor_union]
  ) AS gralkor_writers
  WITH gralkor_target,
    CASE WHEN size(gralkor_writers) = 0 THEN ['unknown'] ELSE gralkor_writers END AS gralkor_writers
  WHERE gralkor_target._gralkor_writers IS NULL OR gralkor_target._gralkor_writers <> gralkor_writers
  SET gralkor_target._gralkor_writers = gralkor_writers
  RETURN count(gralkor_target) AS tagged
  '''

  GRALKOR_EDGE_WRITERS = '''
  WITH DISTINCT gralkor_target
  UNWIND (
    CASE WHEN size(coalesce(gralkor_target.episodes, [])) = 0 THEN [null]
    ELSE gralkor_target.episodes END
  ) AS gralkor_episode_uuid
  OPTIONAL MATCH (gralkor_episode:Episodic {uuid: gralkor_episode_uuid})
  ''' + GRALKOR_WRITER_UNION

  GRALKOR_NODE_WRITERS = '''
  WITH DISTINCT gralkor_target
  OPTIONAL MATCH (gralkor_episode:Episodic)-[:MENTIONS]->(gralkor_target)
  ''' + GRALKOR_WRITER_UNION

  def records_writers(driver):
      from graphiti_core.driver.driver import GraphProvider
      return getattr(driver, 'provider', None) == GraphProvider.FALKORDB

  async def record_writers(driver, writer, written):
      if not records_writers(driver):
          return
      await driver.execute_query(
          'MATCH (e:Episodic {uuid: $uuid}) SET e._gralkor_writers = [$writer] RETURN e.uuid AS uuid',
          uuid=written.episode.uuid,
          writer=writer,
      )
      edge_refs = [
          {'uuid': edge.uuid, 'source': edge.source_node_uuid, 'target': edge.target_node_uuid}
          for edge in written.edges
      ]
      if edge_refs:
          await driver.execute_query(
              '''
              UNWIND $edges AS gralkor_ref
              MATCH (:Entity {uuid: gralkor_ref.source})-[gralkor_target:RELATES_TO {uuid: gralkor_ref.uuid}]->(:Entity {uuid: gralkor_ref.target})
              ''' + GRALKOR_EDGE_WRITERS,
              edges=edge_refs,
          )
      node_uuids = list(dict.fromkeys(node.uuid for node in written.nodes))
      if node_uuids:
          await driver.execute_query(
              '''
              UNWIND $uuids AS gralkor_uuid
              MATCH (gralkor_target:Entity {uuid: gralkor_uuid})
              ''' + GRALKOR_NODE_WRITERS,
              uuids=node_uuids,
          )

  async def tag_in_batches(driver, cypher, tagged, kind):
      while True:
          records, _, _ = await driver.execute_query(cypher, batch=5000)
          count = records[0]['tagged'] if records else 0
          if not count:
              return
          tagged[kind] += count

  async def backfill_writers(driver, tagged):
      if not records_writers(driver):
          return
      records, _, _ = await driver.execute_query(
          'MATCH (e:Episodic) WHERE e._gralkor_writers IS NULL AND e.uuid IS NOT NULL '
          'RETURN e.uuid AS uuid, e.source_description AS source_description, e._gralkor_writer AS writer'
      )
      rows = [
          {'uuid': record['uuid'], 'writer': episode_writer(record['source_description'], record['writer'])}
          for record in records
      ]
      for start in range(0, len(rows), 1000):
          batch = rows[start:start + 1000]
          await driver.execute_query(
              'UNWIND $rows AS row MATCH (e:Episodic {uuid: row.uuid}) SET e._gralkor_writers = [row.writer]',
              rows=batch,
          )
          tagged['episodes'] += len(batch)
      await tag_in_batches(
          driver,
          '''
          MATCH (:Entity)-[gralkor_target:RELATES_TO]->(:Entity)
          WHERE gralkor_target._gralkor_writers IS NULL
          WITH gralkor_target LIMIT $batch
          ''' + GRALKOR_EDGE_WRITERS,
          tagged,
          'facts',
      )
      await tag_in_batches(
          driver,
          '''
          MATCH (gralkor_target:Entity)
          WHERE gralkor_target._gralkor_writers IS NULL
          WITH gralkor_target LIMIT $batch
          ''' + GRALKOR_NODE_WRITERS,
          tagged,
          'entities',
      )
  """

  @pyproject_path Path.join([__DIR__, "..", "..", "priv", "python", "pyproject.toml"])
  @external_resource @pyproject_path
  @graphiti_core_version (case Regex.run(
                                 ~r/"graphiti-core(?:\[[^\]]*\])?==([^"]+)"/,
                                 File.read!(@pyproject_path)
                               ) do
                            [_, version] -> version
                          end)

  @vector_indexes """
  from graphiti_core.driver.driver import GraphProvider
  VECTOR_INDEXES = {
      'fact': {'entitytype': 'RELATIONSHIP', 'label': 'RELATES_TO', 'field': 'fact_embedding',
               'pattern': '()-[e:RELATES_TO]-() ON (e.fact_embedding)'},
      'entity': {'entitytype': 'NODE', 'label': 'Entity', 'field': 'name_embedding',
                 'pattern': '(n:Entity) ON (n.name_embedding)'},
  }
  NEAREST_FLOOR = 2000
  NEAREST_PER_RESULT = 20
  NEAREST_TRUSTED_SHARE = 0.2
  VECTOR_INDEX_STATUS = (
      'CALL db.indexes() YIELD label, types, options, entitytype, status\\n'
      'WHERE label = $gralkor_label AND entitytype = $gralkor_entitytype\\n'
      'RETURN types, options, status'
  )

  def nearest_count(limit):
      return max(NEAREST_FLOOR, NEAREST_PER_RESULT * limit)

  def trusted_count(limit):
      return int(nearest_count(limit) * NEAREST_TRUSTED_SHARE)

  async def vector_index(driver, kind):
      spec = VECTOR_INDEXES[kind]
      records, _, _ = await driver.execute_query(
          VECTOR_INDEX_STATUS,
          gralkor_label=spec['label'],
          gralkor_entitytype=spec['entitytype'],
          routing_='r',
      )
      rows = [record for record in records if 'VECTOR' in ((record['types'] or {}).get(spec['field']) or [])]
      if not rows:
          return None
      operational = [row for row in rows if row['status'] == 'OPERATIONAL']
      options = ((operational or rows)[0]['options'] or {}).get(spec['field']) or {}
      return {
          'built': bool(operational),
          'dimension': options.get('dimension'),
          'similarity': options.get('similarityFunction'),
      }

  def vector_index_mismatch(driver, kind, index, dimension):
      if index['dimension'] == dimension and index['similarity'] == 'cosine':
          return None
      spec = VECTOR_INDEXES[kind]
      return (
          f"graph {driver._database}: the {spec['label']}.{spec['field']} vector index compares "
          f"{index['similarity']} at {index['dimension']} dimensions, but the embedder writes {dimension}, "
          f"compared by cosine; drop it with DROP VECTOR INDEX FOR {spec['pattern']}, wait until db.indexes() "
          f"no longer lists it, and build the graph's indexes again"
      )

  async def create_vector_indexes(g, progress):
      driver = getattr(g, 'driver', None)
      embedder = getattr(g, 'embedder', None)
      if (
          getattr(driver, 'provider', None) != GraphProvider.FALKORDB
          or getattr(driver, 'search_interface', None)
          or embedder is None
      ):
          return
      dimension = int(embedder.config.embedding_dim)
      progress['dimension'] = dimension
      for kind in ('fact', 'entity'):
          spec = VECTOR_INDEXES[kind]
          name = spec['label'] + '.' + spec['field']
          index = await vector_index(driver, kind)
          if index is None:
              progress['unanswered'] = name
              result = await driver.execute_query(
                  'CREATE VECTOR INDEX FOR ' + spec['pattern']
                  + ' OPTIONS {dimension: ' + str(dimension) + ", similarityFunction: 'cosine'}"
              )
              progress['unanswered'] = None
              if result is not None:
                  progress['created'].append(name)
          else:
              mismatch = vector_index_mismatch(driver, kind, index, dimension)
              if mismatch:
                  progress['mismatched'].append(mismatch)
              else:
                  progress['found'].append(name)
  """

  # graphiti-core 0.31.2's SearchFilters has no writer filter, its episode
  # full-text search ignores the filter entirely, and it renders several node
  # labels as the label expression `n:A|B`, which FalkorDB rejects. Pool start
  # wraps graphiti's filter constructors and episode full-text search once,
  # before any search:
  #
  # * several node labels become `(n:A OR n:B)` for FalkorDB;
  # * a `WriterSearchFilters` carrying `writers` adds to every node, edge, and
  #   FalkorDB episode full-text query a per-row check that a writer recorded
  #   in the record's own `_gralkor_writers` is included, and one carrying
  #   `excluded_writers` a check that a recorded writer is not excluded, and one
  #   carrying `since` a check that the record's own `created_at` is at or after
  #   it, each before its query's limit. Only the requested writer names,
  #   `lens:` or `reflection:` prefixes, and the time (as the UTC ISO 8601 text
  #   graphiti's FalkorDB driver stores) are passed, never record identifiers;
  # * with `since`, fact similarity search reads facts through the creation-time
  #   index before it binds their entities, and episode full-text search checks
  #   the node the full-text index yields instead of matching it again;
  # * once the graph's vector index for facts or entities is built, fact and
  #   entity similarity searches read their nearest candidates from it and
  #   filter them in the same query; they answer with graphiti's own query (the
  #   creation-time one with `since`) when the index gave every candidate asked
  #   for and the last result kept, or with fewer results than the search keeps
  #   any candidate above the minimum, lies beyond the nearest share of them,
  #   where the index's ranking is least exact, or when nothing passed, or when
  #   fewer passed from an index that gave fewer candidates than asked for,
  #   or when FalkorDB refuses the lookup because the index is gone (a dropped
  #   index is still listed as built until its drop finishes);
  # * a built vector index at another similarity or dimension fails the search;
  # * fact searches that name facts or their entities never ask the index;
  # * entity similarity search is wrapped where ingestion's entity
  #   deduplication binds it, in node_operations, as well;
  # * fact and entity queries return every property but the embedding;
  # * the FalkorDB client's query takes the query timeout a search sets.
  #
  # Without those fields every query is graphiti's own. These are graphiti
  # internals, so each wrapped or reused function is checked for its pinned
  # signature first and nothing is wrapped unless every check passes.
  @search_filters """
  #{@vector_indexes}
  def install_search_filters(pinned_version):
      import contextvars
      import inspect
      from datetime import timezone
      from pydantic import AwareDatetime
      from redis.exceptions import ResponseError
      import falkordb.asyncio.graph as falkordb_graph
      import graphiti_core.search.search as search_module
      import graphiti_core.search.search_utils as search_utils
      import graphiti_core.utils.maintenance.node_operations as node_operations
      import graphiti_core.edges as edges_module
      import graphiti_core.driver.falkordb.operations.search_ops as falkor_search_ops
      from graphiti_core.driver.driver import GraphProvider
      from graphiti_core.errors import EdgeNotFoundError
      from graphiti_core.search.search_filters import SearchFilters
      installed = getattr(search_utils, '_gralkor_search_filters', None)
      if installed is not None:
          return installed

      def unsupported(qualified, expected, found):
          raise RuntimeError(
              f'Gralkor search filters require {qualified}({", ".join(expected)}) '
              f'from graphiti-core {pinned_version}; found {found}'
          )

      def required(owner, name, expected):
          prefix = owner.__name__ if inspect.ismodule(owner) else f'{owner.__module__}.{owner.__qualname__}'
          qualified = f'{prefix}.{name}'
          function = getattr(owner, name, None)
          if not callable(function):
              unsupported(qualified, expected, 'no such function')
          parameters = list(inspect.signature(function).parameters)
          if parameters != expected:
              unsupported(qualified, expected, f'{qualified}({", ".join(parameters)})')
          return function

      filter_parameters = ['filters', 'provider']
      episode_parameters = ['driver', 'query', '_search_filter', 'group_ids', 'limit']
      similarity_parameters = [
          'driver', 'search_vector', 'source_node_uuid', 'target_node_uuid',
          'search_filter', 'group_ids', 'limit', 'min_score',
      ]
      node_similarity_parameters = ['driver', 'search_vector', 'search_filter', 'group_ids', 'limit', 'min_score']
      targets = [
          (search_utils, 'node_search_filter_query_constructor', filter_parameters, 'node'),
          (search_utils, 'edge_search_filter_query_constructor', filter_parameters, 'edge'),
          (falkor_search_ops, 'node_search_filter_query_constructor', filter_parameters, 'node'),
          (falkor_search_ops, 'edge_search_filter_query_constructor', filter_parameters, 'edge'),
          (search_module, 'episode_fulltext_search', episode_parameters, 'episode'),
          (search_module, 'edge_similarity_search', similarity_parameters, 'similarity'),
          (search_module, 'node_similarity_search', node_similarity_parameters, 'entity_similarity'),
          (node_operations, 'node_similarity_search', node_similarity_parameters, 'entity_similarity'),
          (edges_module.EntityEdge, 'get_by_uuids', ['driver', 'uuids'], 'fact_fetch'),
          (edges_module.EntityEdge, 'load_fact_embedding', ['self', 'driver'], 'fact_embedding'),
          (edges_module.Edge, 'delete_by_uuids', ['driver', 'uuids'], 'relationship_delete'),
          (search_utils, 'get_entity_edge_return_query', ['provider'], 'edge_columns'),
          (search_utils, 'get_entity_node_return_query', ['provider'], 'node_columns'),
          (falkordb_graph.AsyncGraph, 'query', ['self', 'q', 'params', 'timeout'], 'query'),
      ]
      originals = [
          (owner, name, required(owner, name, expected), kind)
          for owner, name, expected, kind in targets
      ]
      fulltext_query = required(search_utils, 'fulltext_query', ['query', 'group_ids', 'driver'])
      get_nodes_query = required(search_utils, 'get_nodes_query', ['name', 'query', 'limit', 'provider'])
      get_episodic_node_from_record = required(search_utils, 'get_episodic_node_from_record', ['record'])
      get_entity_edge_from_record = required(search_utils, 'get_entity_edge_from_record', ['record', 'provider'])
      get_entity_node_from_record = required(search_utils, 'get_entity_node_from_record', ['record', 'provider'])
      entity_edge_return = required(edges_module, 'get_entity_edge_return_query', ['provider'])
      entity_edge_from_record = required(edges_module, 'get_entity_edge_from_record', ['record', 'provider'])
      get_vector_cosine_func_query = required(search_utils, 'get_vector_cosine_func_query', ['vec1', 'vec2', 'provider'])
      own_edge_constructor = required(search_utils, 'edge_search_filter_query_constructor', filter_parameters)
      episode_return = getattr(search_utils, 'EPISODIC_NODE_RETURN', None)
      if not isinstance(episode_return, str):
          unsupported('graphiti_core.search.search_utils.EPISODIC_NODE_RETURN', [], 'no such query')
      column_replacements = {
          'edge_columns': ('properties(e) AS attributes', 'e {.*, fact_embedding: NULL} AS attributes'),
          'node_columns': ('properties(n) AS attributes', 'n {.*, name_embedding: NULL} AS attributes'),
      }
      for owner, name, function, kind in originals:
          if kind in column_replacements:
              replaced = column_replacements[kind][0]
              if function(GraphProvider.FALKORDB).count(replaced) != 1:
                  unsupported(f'{owner.__name__}.{name}', ['provider'], f'a FalkorDB query without {replaced}')
      read_timeout = contextvars.ContextVar('gralkor_read_timeout', default=None)

      class WriterSearchFilters(SearchFilters):
          writers: list[str] | None = None
          excluded_writers: list[str] | None = None
          since: AwareDatetime | None = None

      def writer_clauses(variable, filters):
          clauses = []
          params = {}
          for field, excluded in (('writers', False), ('excluded_writers', True)):
              selected = getattr(filters, field, None)
              if not selected:
                  continue
              names = f'gralkor_{field}'
              prefixes = f'gralkor_{field}_prefixes'
              named = (
                  f'(gralkor_writer IN ${names} OR '
                  f'any(gralkor_prefix IN ${prefixes} WHERE gralkor_writer STARTS WITH gralkor_prefix))'
              )
              clauses.append(
                  f"any(gralkor_writer IN coalesce({variable}._gralkor_writers, ['unknown']) "
                  f"WHERE {'NOT ' if excluded else ''}{named})"
              )
              params[names] = [writer for writer in selected if not writer.endswith(':*')]
              params[prefixes] = [writer[:-1] for writer in selected if writer.endswith(':*')]
          since = getattr(filters, 'since', None)
          if since is not None:
              clauses.append(f'{variable}.created_at >= $gralkor_since')
              params['gralkor_since'] = since.astimezone(timezone.utc).isoformat()
          return clauses, params

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

      def filter_constructor(original, variable):
          def constructed(filters, provider):
              queries, params = original(filters, provider)
              queries = label_disjunction(list(queries), filters, provider)
              clauses, writer_params = writer_clauses(variable, filters)
              return queries + clauses, {**params, **writer_params}
          constructed._gralkor_original = original
          return constructed

      def node_constructor(original):
          return filter_constructor(original, 'n')

      def edge_constructor(original):
          return filter_constructor(original, 'e')

      def falkordb_only(driver):
          if driver.search_interface or driver.provider != GraphProvider.FALKORDB:
              raise RuntimeError(
                  f'Gralkor writer and creation-time search filters support only FalkorDB, not {driver.provider}'
              )

      def episode_search(original):
          async def episode_fulltext_search(driver, query, _search_filter, group_ids=None, limit=search_utils.RELEVANT_SCHEMA_LIMIT):
              clauses, params = writer_clauses('e', _search_filter)
              if not clauses:
                  return await original(driver, query, _search_filter, group_ids, limit)
              falkordb_only(driver)
              fuzzy_query = fulltext_query(query, group_ids, driver)
              if fuzzy_query == '':
                  return []
              if group_ids is not None:
                  clauses.append('e.group_id IN $group_ids')
                  params['group_ids'] = group_ids
              cypher = (
                  get_nodes_query('episode_content', '$query', limit=limit, provider=driver.provider)
                  + '\\nYIELD node AS e, score'
                  + '\\nWHERE ' + ' AND '.join(clauses)
                  + '\\nRETURN\\n'
                  + episode_return
                  + '\\nORDER BY score DESC\\nLIMIT $limit'
              )
              records, _, _ = await driver.execute_query(
                  cypher,
                  query=fuzzy_query,
                  limit=limit,
                  routing_='r',
                  **params,
              )
              return [get_episodic_node_from_record(record) for record in records]
          episode_fulltext_search._gralkor_original = original
          return episode_fulltext_search

      def on_falkordb(driver):
          return not driver.search_interface and driver.provider == GraphProvider.FALKORDB

      def names_records(search_filter, source_node_uuid, target_node_uuid):
          return (
              source_node_uuid is not None
              or target_node_uuid is not None
              or getattr(search_filter, 'edge_uuids', None) is not None
              or getattr(search_filter, 'edge_source_node_uuids', None) is not None
              or getattr(search_filter, 'edge_target_node_uuids', None) is not None
          )

      def answered(records, k, limit, min_score):
          if not records:
              return False
          if records[0]['gralkor_reached'] < k:
              return len(records) >= limit
          trusted = (2 - records[0]['gralkor_trusted']) / 2
          if len(records) >= limit:
              return records[-1]['gralkor_score'] >= trusted
          return trusted <= min_score

      def nearest(procedure, label, field, yielded, variable):
          return (
              f"CALL db.idx.vector.{procedure}('{label}', '{field}', $gralkor_k, vecf32($search_vector))"
              + f'\\nYIELD {yielded}, score AS gralkor_distance'
              + f'\\nWITH collect([{yielded}, gralkor_distance]) AS gralkor_candidates, '
              + 'count(gralkor_distance) AS gralkor_reached, '
              + 'percentileDisc(gralkor_distance, $gralkor_trusted_share) AS gralkor_trusted'
              + '\\nUNWIND gralkor_candidates AS gralkor_candidate'
              + f'\\nWITH gralkor_candidate[0] AS {variable}, (2 - gralkor_candidate[1])/2 AS score, '
              + 'gralkor_reached, gralkor_trusted'
          )

      async def looked_up(driver, procedure, cypher, **params):
          try:
              records, _, _ = await driver.execute_query(cypher, routing_='r', **params)
          except ResponseError as error:
              if str(error) == f"never":
                  raise
              return None
          return records

      async def built_index(driver, kind, search_vector):
          index = await vector_index(driver, kind)
          if index is None or not index['built']:
              return None
          mismatch = vector_index_mismatch(driver, kind, index, len(search_vector))
          if mismatch:
              raise RuntimeError(mismatch)
          return index

      def similarity_search(original):
          async def edge_similarity_search(
              driver, search_vector, source_node_uuid, target_node_uuid, search_filter,
              group_ids=None, limit=search_utils.RELEVANT_SCHEMA_LIMIT, min_score=search_utils.DEFAULT_MIN_SCORE,
          ):
              arguments = (
                  driver, search_vector, source_node_uuid, target_node_uuid, search_filter,
                  group_ids, limit, min_score,
              )
              if not on_falkordb(driver) or names_records(search_filter, source_node_uuid, target_node_uuid):
                  return await own_fact_query(*arguments)
              if await built_index(driver, 'fact', search_vector) is None:
                  return await own_fact_query(*arguments)
              k = nearest_count(limit)
              fact_clauses, params = writer_clauses('e', search_filter)
              own_queries, own_params = own_edge_constructor(search_filter, driver.provider)
              entity_clauses = ['n:Entity', 'm:Entity'] + label_disjunction(list(own_queries), search_filter, driver.provider)
              params.update(own_params)
              if group_ids is not None:
                  fact_clauses.append('e.group_id IN $group_ids')
                  params['group_ids'] = group_ids
              cypher = (
                  nearest('queryRelationships', 'RELATES_TO', 'fact_embedding', 'relationship', 'e')
                  + '\\nWHERE ' + ' AND '.join(['score > $min_score'] + fact_clauses)
                  + '\\nWITH e, score, gralkor_reached, gralkor_trusted, startNode(e) AS n, endNode(e) AS m'
                  + '\\nWHERE ' + ' AND '.join(entity_clauses)
                  + '\\nRETURN\\n'
                  + search_utils.get_entity_edge_return_query(driver.provider)
                  + ',\\nscore AS gralkor_score, gralkor_reached, gralkor_trusted'
                  + '\\nORDER BY score DESC\\nLIMIT $limit'
              )
              records = await looked_up(
                  driver,
                  'queryRelationships',
                  cypher,
                  search_vector=search_vector,
                  gralkor_k=k,
                  gralkor_trusted_share=NEAREST_TRUSTED_SHARE,
                  limit=limit,
                  min_score=min_score,
                  **params,
              )
              if answered(records, k, limit, min_score):
                  return [get_entity_edge_from_record(record, driver.provider) for record in records]
              return await own_fact_query(*arguments)

          async def own_fact_query(
              driver, search_vector, source_node_uuid, target_node_uuid, search_filter,
              group_ids, limit, min_score,
          ):
              if getattr(search_filter, 'since', None) is None:
                  return await original(
                      driver, search_vector, source_node_uuid, target_node_uuid, search_filter,
                      group_ids, limit, min_score,
                  )
              falkordb_only(driver)
              fact_clauses, params = writer_clauses('e', search_filter)
              own_queries, own_params = own_edge_constructor(search_filter, driver.provider)
              entity_clauses = ['n:Entity', 'm:Entity'] + label_disjunction(list(own_queries), search_filter, driver.provider)
              params.update(own_params)
              if group_ids is not None:
                  fact_clauses.append('e.group_id IN $group_ids')
                  params['group_ids'] = group_ids
                  if source_node_uuid is not None:
                      entity_clauses.append('n.uuid = $source_uuid')
                      params['source_uuid'] = source_node_uuid
                  if target_node_uuid is not None:
                      entity_clauses.append('m.uuid = $target_uuid')
                      params['target_uuid'] = target_node_uuid
              cypher = (
                  'MATCH ()-[e:RELATES_TO]->()'
                  + '\\nWHERE ' + ' AND '.join(fact_clauses)
                  + '\\nWITH e, startNode(e) AS n, endNode(e) AS m'
                  + '\\nWHERE ' + ' AND '.join(entity_clauses)
                  + '\\nWITH DISTINCT e, n, m, '
                  + get_vector_cosine_func_query('e.fact_embedding', '$search_vector', driver.provider)
                  + ' AS score'
                  + '\\nWHERE score > $min_score'
                  + '\\nRETURN\\n'
                  + search_utils.get_entity_edge_return_query(driver.provider)
                  + '\\nORDER BY score DESC\\nLIMIT $limit'
              )
              records, _, _ = await driver.execute_query(
                  cypher,
                  search_vector=search_vector,
                  limit=limit,
                  min_score=min_score,
                  routing_='r',
                  **params,
              )
              return [get_entity_edge_from_record(record, driver.provider) for record in records]
          edge_similarity_search._gralkor_original = original
          return edge_similarity_search

      def entity_similarity_search(original):
          async def node_similarity_search(
              driver, search_vector, search_filter, group_ids=None,
              limit=search_utils.RELEVANT_SCHEMA_LIMIT, min_score=search_utils.DEFAULT_MIN_SCORE,
          ):
              arguments = (driver, search_vector, search_filter, group_ids, limit, min_score)
              if not on_falkordb(driver):
                  return await original(*arguments)
              if await built_index(driver, 'entity', search_vector) is None:
                  return await original(*arguments)
              k = nearest_count(limit)
              clauses, params = search_utils.node_search_filter_query_constructor(search_filter, driver.provider)
              clauses = ['score > $min_score'] + list(clauses)
              if group_ids is not None:
                  clauses.append('n.group_id IN $group_ids')
                  params['group_ids'] = group_ids
              cypher = (
                  nearest('queryNodes', 'Entity', 'name_embedding', 'node', 'n')
                  + '\\nWHERE ' + ' AND '.join(clauses)
                  + '\\nRETURN\\n'
                  + search_utils.get_entity_node_return_query(driver.provider)
                  + ',\\nscore AS gralkor_score, gralkor_reached, gralkor_trusted'
                  + '\\nORDER BY score DESC\\nLIMIT $limit'
              )
              records = await looked_up(
                  driver,
                  'queryNodes',
                  cypher,
                  search_vector=search_vector,
                  gralkor_k=k,
                  gralkor_trusted_share=NEAREST_TRUSTED_SHARE,
                  limit=limit,
                  min_score=min_score,
                  **params,
              )
              if answered(records, k, limit, min_score):
                  return [get_entity_node_from_record(record, driver.provider) for record in records]
              return await original(*arguments)
          node_similarity_search._gralkor_original = original
          return node_similarity_search

      def by_uuid_index(driver):
          return not driver.graph_operations_interface and driver.provider == GraphProvider.FALKORDB

      def fact_fetch(original):
          own = vars(edges_module.EntityEdge)['get_by_uuids'].__func__
          async def get_by_uuids(cls, driver, uuids):
              if not by_uuid_index(driver) or len(uuids) == 0:
                  return await own(cls, driver, uuids)
              records, _, _ = await driver.execute_query(
                  'MATCH ()-[e:RELATES_TO]->()'
                  + '\\nWHERE e.uuid IN $uuids'
                  + '\\nWITH e, startNode(e) AS n, endNode(e) AS m'
                  + '\\nWHERE n:Entity AND m:Entity'
                  + '\\nRETURN\\n'
                  + entity_edge_return(driver.provider),
                  uuids=uuids,
                  routing_='r',
              )
              return [entity_edge_from_record(record, driver.provider) for record in records]
          get_by_uuids._gralkor_original = original
          return classmethod(get_by_uuids)

      def fact_embedding(original):
          async def load_fact_embedding(self, driver):
              if not by_uuid_index(driver):
                  return await original(self, driver)
              records, _, _ = await driver.execute_query(
                  'MATCH ()-[e:RELATES_TO {uuid: $uuid}]->()'
                  + '\\nWITH e, startNode(e) AS n, endNode(e) AS m'
                  + '\\nWHERE n:Entity AND m:Entity'
                  + '\\nRETURN e.fact_embedding AS fact_embedding',
                  uuid=self.uuid,
                  routing_='r',
              )
              if len(records) == 0:
                  raise EdgeNotFoundError(self.uuid)
              self.fact_embedding = records[0]['fact_embedding']
          load_fact_embedding._gralkor_original = original
          return load_fact_embedding

      def relationship_delete(original):
          own = vars(edges_module.Edge)['delete_by_uuids'].__func__
          async def delete_by_uuids(cls, driver, uuids):
              if not by_uuid_index(driver):
                  return await own(cls, driver, uuids)
              for relationship in ('MENTIONS', 'RELATES_TO', 'HAS_MEMBER'):
                  await driver.execute_query(
                      'MATCH ()-[e:' + relationship + ']->() WHERE e.uuid IN $uuids DELETE e',
                      uuids=uuids,
                  )
          delete_by_uuids._gralkor_original = original
          return classmethod(delete_by_uuids)

      def columns(kind):
          replaced, replacement = column_replacements[kind]
          def wrap_columns(original):
              def return_columns(provider):
                  query = original(provider)
                  return query.replace(replaced, replacement) if provider == GraphProvider.FALKORDB else query
              return_columns._gralkor_original = original
              return return_columns
          return wrap_columns

      def timed_query(original):
          async def query(self, q, params=None, timeout=None):
              return await original(self, q, params, read_timeout.get() if timeout is None else timeout)
          query._gralkor_original = original
          return query

      wrap = {
          'node': node_constructor,
          'edge': edge_constructor,
          'episode': episode_search,
          'similarity': similarity_search,
          'entity_similarity': entity_similarity_search,
          'fact_fetch': fact_fetch,
          'fact_embedding': fact_embedding,
          'relationship_delete': relationship_delete,
          'edge_columns': columns('edge_columns'),
          'node_columns': columns('node_columns'),
          'query': timed_query,
      }
      restorable = [
          (owner, name, vars(owner)[name] if inspect.isclass(owner) else function)
          for owner, name, function, _kind in originals
      ]
      wrapped = [(owner, name, wrap[kind](function)) for owner, name, function, kind in originals]
      for owner, name, function in wrapped:
          setattr(owner, name, function)
      search_utils._gralkor_search_filter_originals = restorable
      search_utils._gralkor_read_timeout = read_timeout
      search_utils._gralkor_nearest_count = nearest_count
      search_utils._gralkor_trusted_count = trusted_count
      search_utils._gralkor_search_filters = WriterSearchFilters
      return WriterSearchFilters
  """

  @index_building_without_stopwords """
  def install_index_building_without_stopwords():
      import re
      import graphiti_core.graph_queries as graph_queries
      import graphiti_core.driver.falkordb_driver as falkordb_driver
      import graphiti_core.driver.falkordb.operations.graph_ops as falkor_graph_ops
      from graphiti_core.driver.driver import GraphProvider
      FalkorDriver = falkordb_driver.FalkorDriver
      if hasattr(FalkorDriver.build_indices_and_constraints, '_gralkor_original'):
          return

      original_fulltext_indices = graph_queries.get_fulltext_indices
      original_build = FalkorDriver.build_indices_and_constraints

      def get_fulltext_indices(provider):
          queries = original_fulltext_indices(provider)
          if provider != GraphProvider.FALKORDB:
              return queries
          return [
              re.sub(r'\\s*OPTIONS\\s*\\{.*\\}\\s*$', '', query, flags=re.S)
              + ' OPTIONS {stopwords: []}'
              for query in queries
          ]

      async def drop_index(driver, query):
          try:
              await driver.execute_query(query)
          except Exception as error:
              if 'no such index' not in str(error):
                  raise

      async def replace_stopword_indexes(driver, replaced):
          result = await driver.execute_query(
              'CALL db.indexes() YIELD label, types, stopwords, entitytype '
              'RETURN label, types, stopwords, entitytype'
          )
          if not result:
              return
          records, _, _ = result
          for record in records:
              if record['entitytype'] != 'NODE' or not record['stopwords']:
                  continue
              label = record['label']
              types = record['types']
              unsupported = sorted(
                  field for field, kinds in types.items() if set(kinds) - {'RANGE', 'FULLTEXT'}
              )
              if unsupported:
                  raise RuntimeError(
                      f'cannot rebuild the {label} indexes without stopwords: '
                      f'{", ".join(unsupported)} is neither a range nor a full-text index'
                  )
              range_fields = [field for field, kinds in types.items() if 'RANGE' in kinds]
              fulltext_fields = [field for field, kinds in types.items() if 'FULLTEXT' in kinds]
              for field in fulltext_fields:
                  await drop_index(driver, f'DROP FULLTEXT INDEX FOR (n:{label}) ON (n.{field})')
              for field in range_fields:
                  await drop_index(driver, f'DROP INDEX FOR (n:{label}) ON (n.{field})')
              if range_fields:
                  fields = ', '.join(f'n.{field}' for field in range_fields)
                  await driver.execute_query(f'CREATE INDEX FOR (n:{label}) ON ({fields})')
              if fulltext_fields:
                  fields = ', '.join(f'n.{field}' for field in fulltext_fields)
                  await driver.execute_query(
                      f'CREATE FULLTEXT INDEX FOR (n:{label}) ON ({fields}) OPTIONS {{stopwords: []}}'
                  )
              replaced.append(label)

      async def build_indices_and_constraints(self, delete_existing=False):
          self._gralkor_replaced_stopword_indexes = []
          await replace_stopword_indexes(self, self._gralkor_replaced_stopword_indexes)
          await original_build(self, delete_existing)

      get_fulltext_indices._gralkor_original = original_fulltext_indices
      build_indices_and_constraints._gralkor_original = original_build
      for module in (graph_queries, falkordb_driver, falkor_graph_ops):
          module.get_fulltext_indices = get_fulltext_indices
      FalkorDriver.build_indices_and_constraints = build_indices_and_constraints
  """

  @fact_rendering """
  async def read_follow_up(driver, edges, episodes=()):
      import asyncio
      from graphiti_core.driver.driver import GraphProvider
      from graphiti_core.nodes import EpisodicNode

      records_writers = getattr(driver, 'provider', None) == GraphProvider.FALKORDB
      source_ids = list(dict.fromkeys(
          episode_id for edge in edges for episode_id in (getattr(edge, "episodes", None) or [])
      ))
      endpoint_ids = list(dict.fromkeys(
          endpoint_id
          for edge in edges
          for endpoint_id in (getattr(edge, "source_node_uuid", None), getattr(edge, "target_node_uuid", None))
          if endpoint_id
      ))
      recorded_ids = list(dict.fromkeys(source_ids + [episode.uuid for episode in episodes]))

      async def sources():
          return await EpisodicNode.get_by_uuids(driver, source_ids) if source_ids else []

      async def recorded():
          if not records_writers or not recorded_ids:
              return {}
          records, _, _ = await driver.execute_query(
              'MATCH (e:Episodic) WHERE e.uuid IN $uuids '
              'RETURN e.uuid AS uuid, e._gralkor_writer AS writer, e._gralkor_writers AS writers, '
              'coalesce(e._gralkor_extraction_complete, false) AS complete',
              uuids=recorded_ids,
          )
          return {record['uuid']: record for record in records}

      async def names():
          if not endpoint_ids:
              return {}
          records, _, _ = await driver.execute_query(
              'MATCH (n:Entity) WHERE n.uuid IN $uuids RETURN n.uuid AS uuid, n.name AS name',
              uuids=endpoint_ids,
          )
          return {record['uuid']: record['name'] for record in records}

      reads = [asyncio.ensure_future(read()) for read in (sources, recorded, names)]
      try:
          sourced, recorded_by_uuid, endpoint_names = await asyncio.gather(*reads)
      except BaseException:
          for read in reads:
              read.cancel()
          await asyncio.gather(*reads, return_exceptions=True)
          raise
      if records_writers:
          for episode in list(sourced) + list(episodes):
              record = recorded_by_uuid.get(episode.uuid, {})
              if record.get('writer') == 'direct':
                  episode.__dict__['_gralkor_writer'] = 'direct'
              else:
                  episode.__dict__.pop('_gralkor_writer', None)
              episode.__dict__['_gralkor_writers'] = list(record.get('writers') or [])
      return sourced, recorded_by_uuid, endpoint_names

  def render_facts(edges, episodes, endpoint_names, writers=(), excluded_writers=()):
      def named(writer, selected):
          return any(
              writer.startswith(selector[:-1]) if selector.endswith(':*') else writer == selector
              for selector in selected
          )

      def admitted(episode):
          produced = getattr(episode, '_gralkor_writers', None) or ['unknown']
          return (
              (not writers or any(named(writer, writers) for writer in produced))
              and (not excluded_writers or any(not named(writer, excluded_writers) for writer in produced))
          )

      episodes_by_id = {episode.uuid: episode for episode in episodes}
      source_kinds = {
          "message": "conversation",
          "text": "document",
          "json": "structured_record",
      }

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
              if episode_id in episodes_by_id and admitted(episodes_by_id[episode_id])
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

    raw =
      Gralkor.Python.run_coroutine(
        """
        from graphiti_core.search.search_filters import SearchFilters
        import graphiti_core.search.search_utils as search_utils

        #{@fact_rendering}
        q = query.decode('utf-8') if isinstance(query, (bytes, bytearray)) else query
        types = (
          [t.decode('utf-8') if isinstance(t, (bytes, bytearray)) else t for t in edge_types]
          if edge_types else None
        )
        async def search_with_sources():
          search_utils._gralkor_read_timeout.set(read_timeout_ms)
          filters = SearchFilters(edge_types=types)
          edges = await g.search(q, num_results=max_results, search_filter=filters)
          episodes, _recorded, endpoint_names = await read_follow_up(getattr(g, 'driver', None), edges)
          return render_facts(edges, episodes, endpoint_names)

        search_with_sources()
        """,
        %{
          "g" => instance,
          "query" => query,
          "max_results" => max_results,
          "edge_types" => edge_types,
          "read_timeout_ms" => read_timeout_ms(server)
        }
      )

    {:ok, raw |> Pythonx.decode() |> Enum.map(&atomize_keys/1)}
  rescue
    e in Pythonx.Error -> python_failure(e, :search)
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
  driver is bound to that group's database, and passes no `group_ids`.

  One `SearchFilters(node_labels: …, edge_types: …)` applies to the whole
  search. Graphiti applies `node_labels` to nodes directly and to edges through
  both endpoints; `edge_types` restricts edges only; neither restricts episodes.
  A query longer than FalkorDB's full-text limit is cut to its earliest
  supported terms. A Reflection episode without its durable
  extraction-completion marker is excluded before the episode limit applies.

  Returns `{:ok, %{facts: [fact], nodes: [node], episodes: [episode]}}`: facts
  rendered as `search/5` renders them, nodes as `%{name:, summary:,
  attributes:}`, and episodes as `%{content:, source_description:,
  source_kind:}` plus `valid_at:` and `created_at:` when Graphiti records them and
  `writer: :direct` for durable direct writes.

  ## Options

    * `:node_labels` — optional `[String.t()]` entity-type labels.
    * `:edge_types` — optional `[String.t()]` relationship names.
    * `:writers` — optional `[String.t()]` writer names (`lens:NAME`,
      `reflection:NAME`, `direct`, `unknown`, `lens:*`, `reflection:*`). Edges,
      nodes, and episodes are admitted only when a writer recorded in their own
      `_gralkor_writers` is included; fact sources keep only included writers'
      episodes.
    * `:excluded_writers` — optional `[String.t()]` writer names. Episodes an
      excluded writer wrote, and edges and nodes only excluded writers
      produced, are rejected; fact sources omit excluded writers' episodes.
    * `:since` — optional `DateTime`. Only edges, nodes, and episodes whose own
      `created_at` is at or after it are admitted.

  Each is a per-row check the installed `WriterSearchFilters` adds to
  graphiti's node, edge, and FalkorDB episode full-text queries, before their
  limits, and only the requested writer names and time are passed to them.
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

    raw =
      Gralkor.Python.run_coroutine(
        """
        from graphiti_core.driver.falkordb import STOPWORDS
        from graphiti_core.driver.falkordb.fulltext import (
          MAX_QUERY_LENGTH,
          sanitize_falkor_fulltext_query,
        )
        from graphiti_core.search.search_config_recipes import COMBINED_HYBRID_SEARCH_RRF
        from graphiti_core.search.search_filters import SearchFilters

        import graphiti_core.search.search_utils as search_utils

        #{@fact_rendering}
        WriterSearchFilters = search_utils._gralkor_search_filters
        if WriterSearchFilters is None:
          raise RuntimeError('Gralkor search filters are not installed; start Gralkor.GraphitiPool first')

        def text(value):
          return value.decode('utf-8') if isinstance(value, (bytes, bytearray)) else value

        q = text(query)
        labels = [text(label) for label in node_labels] if node_labels else None
        types = [text(edge_type) for edge_type in edge_types] if edge_types else None
        included_writers = [text(writer) for writer in writers] if writers else []
        rejected_writers = [text(writer) for writer in excluded_writers] if excluded_writers else []
        earliest = text(since) if since is not None else None
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

        def completed(episode, recorded):
          if episode.uuid in recorded:
            return bool(recorded[episode.uuid]['complete'])
          return episode.uuid in getattr(g.driver, '_gralkor_completed_episode_uuids', set())

        def episode_result(episode):
          result = {
            "content": episode.content,
            "source_description": episode.source_description,
          }
          if direct_episode(episode):
            result["_gralkor_writer"] = "direct"
          for moment in ('valid_at', 'created_at'):
            if getattr(episode, moment, None) is not None:
              result[moment] = str(getattr(episode, moment))
          source = getattr(episode, 'source', None)
          if source is not None:
            result['source_kind'] = {'message': 'conversation', 'text': 'document', 'json': 'structured_record'}.get(source.value)
          return result

        async def search_memory():
          search_utils._gralkor_read_timeout.set(read_timeout_ms)
          if included_writers or rejected_writers or earliest is not None:
            search_filter = WriterSearchFilters(
              node_labels=labels,
              edge_types=types,
              writers=included_writers or None,
              excluded_writers=rejected_writers or None,
              since=earliest,
            )
          else:
            search_filter = SearchFilters(node_labels=labels, edge_types=types)
          results = await g.search_(q, config=config, search_filter=search_filter)
          edges = list(results.edges)[:fact_limit]
          episodes = list(results.episodes)
          sources, recorded, endpoint_names = await read_follow_up(getattr(g, 'driver', None), edges, episodes)
          facts = render_facts(edges, sources, endpoint_names, included_writers, rejected_writers)
          nodes = [
            {
              "name": n.name,
              "summary": n.summary,
              "attributes": {k: str(v) for k, v in (n.attributes or {}).items()},
            }
            for n in list(results.nodes)[:node_limit]
          ]
          episodes = [
            e for e in episodes if not reflection_episode(e) or completed(e, recorded)
          ][:episode_limit]
          return {
            "facts": facts,
            "nodes": nodes,
            "episodes": [episode_result(e) for e in episodes],
          }

        search_memory()
        """,
        %{
          "g" => instance,
          "query" => query,
          "fact_limit" => limits.facts,
          "node_limit" => limits.nodes,
          "episode_limit" => limits.episodes,
          "node_labels" => Keyword.get(opts, :node_labels),
          "edge_types" => Keyword.get(opts, :edge_types),
          "writers" => Keyword.get(opts, :writers),
          "excluded_writers" => Keyword.get(opts, :excluded_writers),
          "since" => since_text(Keyword.get(opts, :since)),
          "read_timeout_ms" => read_timeout_ms(server)
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
    e in Pythonx.Error -> python_failure(e, :search_memory)
  end

  defp since_text(nil), do: nil
  defp since_text(%DateTime{} = since), do: DateTime.to_iso8601(since)

  defp episode_map(%{} = m) do
    episode = %{
      content: Map.get(m, "content"),
      source_description: Map.get(m, "source_description")
    }

    episode =
      if Map.has_key?(m, "source_kind"),
        do: Map.put(episode, :source_kind, m["source_kind"]),
        else: episode

    episode =
      Enum.reduce(["valid_at", "created_at"], episode, fn moment, episode ->
        if Map.has_key?(m, moment),
          do: Map.put(episode, String.to_existing_atom(moment), m[moment]),
          else: episode
      end)

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
        future =
          Gralkor.Python.await_coroutine(
            """
            import asyncio
            from contextvars import ContextVar
            from datetime import datetime, timezone
            from uuid import uuid4
            from graphiti_core.driver.driver import GraphProvider
            from graphiti_core.errors import NodeNotFoundError
            import graphiti_core.graphiti as graphiti_module
            from graphiti_core.nodes import EpisodeType, EpisodicNode

            #{@writer_recording}
            c = content.decode('utf-8') if isinstance(content, (bytes, bytearray)) else content
            s = source.decode('utf-8') if isinstance(source, (bytes, bytearray)) else source
            n = name.decode('utf-8') if isinstance(name, (bytes, bytearray)) else name
            gid = group.decode('utf-8') if isinstance(group, (bytes, bytearray)) else group
            sk = source_kind.decode('utf-8') if isinstance(source_kind, (bytes, bytearray)) else source_kind
            instructions = extraction_instructions.decode('utf-8') if isinstance(extraction_instructions, (bytes, bytearray)) else extraction_instructions
            writer = episode_writer(s, 'direct' if direct_writer else None)
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
                            and claim.get('episode_source_description') == s
                        )
                    )
                    if not episode_equal:
                        return 'conflict'
                    equal = (
                        claim['group_id'] == gid
                        and claim['content'] == c
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
                            written = await g.add_episode(**kwargs)
                            await record_extraction_complete()
                            await record_writers(getattr(g, 'driver', None), writer, written)
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
                    written = await g.add_episode(**kwargs)
                    await record_writers(getattr(g, 'driver', None), writer, written)
                    return 'created'
                finally:
                    if token is not None:
                        guard.reset(token)
            add_episode()
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

        {raw, _} =
          Pythonx.eval(
            """
            import sys
            #{@upstream_failure_classification}
            try:
                result = future.result()
            except BaseException as e:
                print(f"[gralkor] add_episode failed: {type(e).__name__}: {(str(e).splitlines() or [''])[0]}", file=sys.stderr)
                upstream = upstream_failure(e)
                if upstream is None:
                    raise
                result = upstream
            result
            """,
            %{"future" => future}
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
    e in Pythonx.Error -> python_failure(e, :add_episode)
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

    future =
      Gralkor.Python.await_coroutine(
        """
        uid = episode_uuid.decode('utf-8') if isinstance(episode_uuid, (bytes, bytearray)) else episode_uuid
        g.remove_episode(uid)
        """,
        %{"g" => instance, "episode_uuid" => episode_uuid}
      )

    Pythonx.eval(
      """
      import sys
      try:
          future.result()
      except BaseException as e:
          print(f"[gralkor] remove_episode failed: {type(e).__name__}: {(str(e).splitlines() or [''])[0]}", file=sys.stderr)
          raise
      None
      """,
      %{"future" => future}
    )

    :ok
  rescue
    e in Pythonx.Error -> python_failure(e, :remove_episode)
  end

  @doc """
  Rebuild indices and constraints across the whole graph.

  Every group is its own FalkorDB database, so "the whole graph" is every
  group this pool holds an instance for — rebuilding one group's database
  would leave every other group untouched. A group whose instance has not been
  created yet needs no rebuild: `initialise_instance/1` builds its indices the
  moment it is. Each rebuild also records writers on every episode, fact, and
  entity that lacks them.
  """
  @spec build_indices(GenServer.server()) :: {:ok, %{status: String.t()}} | {:error, term()}
  def build_indices(server \\ __MODULE__) do
    server
    |> table_for()
    |> :ets.tab2list()
    |> Enum.flat_map(fn {_group_id, instance} ->
      case initialise_instance(instance) do
        :ok -> []
        {:error, {:vector_indexes, message}} -> [message]
      end
    end)
    |> case do
      [] -> {:ok, %{status: "built"}}
      mismatched -> {:error, {:vector_indexes, Enum.join(mismatched, "; ")}}
    end
  rescue
    e in Pythonx.Error -> python_failure(e, :build_indices)
  end

  @doc "Build communities for `group_id`."
  @spec build_communities(GenServer.server(), String.t()) ::
          {:ok, %{communities: non_neg_integer(), edges: non_neg_integer()}} | {:error, term()}
  def build_communities(server \\ __MODULE__, group_id) when is_binary(group_id) do
    instance = __MODULE__.for(server, group_id)

    raw =
      Gralkor.Python.run_coroutine(
        """
        async def build_communities():
          nodes, edges = await g.build_communities()
          return {"communities": len(nodes or []), "edges": len(edges or [])}
        build_communities()
        """,
        %{"g" => instance}
      )

    decoded = Pythonx.decode(raw)
    {:ok, %{communities: decoded["communities"], edges: decoded["edges"]}}
  rescue
    e in Pythonx.Error -> python_failure(e, :build_communities)
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

  defp install_index_building_without_stopwords! do
    Pythonx.eval(
      """
      #{@index_building_without_stopwords}
      install_index_building_without_stopwords()
      None
      """,
      %{}
    )

    :ok
  end

  # A socket read timeout and an expired bridge deadline both surface here. A
  # deadlocked FalkorDB stays locked until it restarts, so retries also time out;
  # the log line is what makes that visible.
  @spec python_failure(Pythonx.Error.t(), atom()) :: {:error, :timeout | {:python, String.t()}}
  defp python_failure(error, stage) do
    summary = summarise_python_error(error)

    if Regex.match?(~r/^(\w+\.)*TimeoutError\b/, summary) do
      Logger.error("[gralkor] graph operation timed out — stage:#{stage} reason:#{summary}")
      {:error, :timeout}
    else
      {:error, {:python, summary}}
    end
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

  @index_building_retry_delays_ms [1_000, 2_000, 4_000]

  @doc false
  @spec index_building_retry_delays_ms() :: [pos_integer()]
  def index_building_retry_delays_ms, do: @index_building_retry_delays_ms

  @doc false
  @spec initialise_instance(any()) :: :ok | {:error, {:vector_indexes, String.t()}}
  def initialise_instance(instance) do
    initialise_instance(instance, @index_building_retry_delays_ms, %{
      created: [],
      unanswered: [],
      dimension: nil
    })
  end

  # FalkorDB's clients send each query once, so this is the layer that tries a
  # failed initialisation again. Each step of a try does only what the graph
  # still lacks. An index found after its creation went unanswered counts as
  # created.
  defp initialise_instance(instance, delays, so_far) do
    %{
      "replaced" => replaced,
      "tagged" => %{"episodes" => episodes, "facts" => facts, "entities" => entities},
      "graph" => graph,
      "vector_indexes" => %{
        "created" => created,
        "found" => found,
        "unanswered" => unanswered,
        "dimension" => dimension,
        "mismatched" => mismatched
      },
      "failed" => failed
    } =
      """
      #{@writer_recording}
      #{@vector_indexes}
      import redis.exceptions
      async def initialise():
          driver = getattr(g, 'driver', None)
          tagged = {'episodes': 0, 'facts': 0, 'entities': 0}
          vector_indexes = {
              'created': [], 'found': [], 'unanswered': None, 'dimension': None, 'mismatched': [],
          }
          failed = None
          try:
              await g.build_indices_and_constraints()
              await backfill_writers(driver, tagged)
              await create_vector_indexes(g, vector_indexes)
          except redis.exceptions.RedisError as error:
              failed = (
                  f"{type(error).__module__}.{type(error).__qualname__}: "
                  f"{(str(error).splitlines() or [''])[0]}"
              )
          return {
              'replaced': list(getattr(driver, '_gralkor_replaced_stopword_indexes', None) or []),
              'tagged': tagged,
              'graph': str(getattr(driver, '_database', None)),
              'vector_indexes': vector_indexes,
              'failed': failed,
          }
      initialise()
      """
      |> Gralkor.Python.run_coroutine(%{"g" => instance})
      |> Pythonx.decode()

    if replaced != [] do
      Logger.warning(
        "[gralkor] full-text indexes rebuilt without stopwords (FalkorDB #3348) — labels: " <>
          Enum.join(replaced, ", ")
      )
    end

    if episodes + facts + entities > 0 do
      Logger.info(
        "[gralkor] recorded writers for memory written before writers were recorded — " <>
          "graph: #{graph} episodes: #{episodes} facts: #{facts} entities: #{entities}"
      )
    end

    so_far = %{
      created: so_far.created ++ Enum.filter(found, &(&1 in so_far.unanswered)) ++ created,
      unanswered: (so_far.unanswered -- found) ++ List.wrap(unanswered),
      dimension: dimension || so_far.dimension
    }

    try_number = length(@index_building_retry_delays_ms) - length(delays) + 1

    case {failed, mismatched, delays} do
      {failure, [], [delay | later_delays]} when is_binary(failure) ->
        Application.get_env(:jido_gralkor, :index_building_retry_sleep, &Process.sleep/1).(delay)
        initialise_instance(instance, later_delays, so_far)

      _ ->
        if failed == nil and mismatched == [] and try_number > 1 do
          Logger.info("[gralkor] index building succeeded on try #{try_number} — graph: #{graph}")
        end

        if so_far.created != [] do
          Logger.info(
            "[gralkor] vector indexes created — graph: #{graph} indexes: " <>
              "#{Enum.join(so_far.created, ", ")} dimension: #{so_far.dimension}; FalkorDB " <>
              "builds them in the background and fact and entity similarity searches compare " <>
              "every fact or entity until each is built"
          )
        end

        failed_building =
          for failure <- List.wrap(failed) do
            "graph #{graph}: building the indexes failed (tries: #{try_number}, last failure: " <>
              "#{failure}); the graph lacks what no try built until its indexes are built again"
          end

        case mismatched ++ failed_building do
          [] -> :ok
          problems -> {:error, {:vector_indexes, Enum.join(problems, "; ")}}
        end
    end
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

    raw =
      Gralkor.Python.run_coroutine(
        """
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

        get_episode()
        """,
        %{"g" => instance, "episode_uuid" => episode_uuid}
      )

    case Pythonx.decode(raw) do
      nil -> {:error, :not_found}
      episode -> {:ok, episode}
    end
  rescue
    e in Pythonx.Error -> python_failure(e, :get_episode)
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
    install_index_building_without_stopwords!()

    socket_timeout = falkordb_socket_timeout(falkordb_spec, opts)
    max_connections = falkordb_max_connections(falkordb_spec, opts)
    deadline_ms = graph_operation_deadline(opts)
    construct_falkor_db = Keyword.get(opts, :construct_falkor_db, &default_construct_falkor_db/3)

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

    install_loop_fn =
      Keyword.get(opts, :install_loop_fn, fn ->
        Gralkor.Python.install_async_runtime(deadline_ms)
      end)

    :ets.new(table, [:set, :public, :named_table, read_concurrency: true])
    register_table(self(), table, read_timeout_below(socket_timeout))

    :ok = install_loop_fn.()

    shared = construct_shared_clients.(shared_client_spec(inference))

    case falkordb_spec do
      {:embedded, data_dir} ->
        File.mkdir_p!(data_dir)
        File.rm(Path.join(data_dir, "gralkor.db.settings"))

      {:remote, _opts} ->
        :ok
    end

    falkor_db =
      construct_falkor_db(construct_falkor_db, falkordb_spec, socket_timeout, max_connections)

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
    unregister_table(self(), state.table)
    :ets.delete(state.table)
    :ok
  end

  defp episode_write_admission({:embedded, _data_dir}) do
    %{owner: nil, monitor: nil, waiting: :queue.new()}
  end

  defp episode_write_admission({:remote, _options}), do: :unbounded

  defp falkordb_socket_timeout({:embedded, _data_dir}, opts) do
    opts
    |> Keyword.get_lazy(
      :embedded_falkordb_socket_timeout_ms,
      &Config.embedded_falkordb_socket_timeout_ms/0
    )
    |> Config.validate_embedded_falkordb_socket_timeout_ms!()
    |> Kernel./(1_000)
  end

  defp falkordb_socket_timeout({:remote, _options}, opts) do
    opts
    |> Keyword.get_lazy(
      :remote_falkordb_socket_timeout_ms,
      &Config.remote_falkordb_socket_timeout_ms/0
    )
    |> Config.validate_remote_falkordb_socket_timeout_ms!()
    |> Kernel./(1_000)
  end

  defp falkordb_max_connections({:embedded, _data_dir}, _opts), do: nil

  defp falkordb_max_connections({:remote, _options}, opts) do
    opts
    |> Keyword.get_lazy(
      :remote_falkordb_max_connections,
      &Config.remote_falkordb_max_connections/0
    )
    |> Config.validate_remote_falkordb_max_connections!()
  end

  defp graph_operation_deadline(opts) do
    opts
    |> Keyword.get_lazy(:graph_operation_deadline_ms, &Config.graph_operation_deadline_ms/0)
    |> Config.validate_graph_operation_deadline_ms!()
  end

  defp construct_falkor_db(constructor, spec, socket_timeout, max_connections) do
    case :erlang.fun_info(constructor, :arity) do
      {:arity, 1} -> constructor.(spec)
      {:arity, 2} -> constructor.(spec, socket_timeout)
      {:arity, 3} -> constructor.(spec, socket_timeout, max_connections)
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
        Enum.map(fields, fn %{name: fname, type: ftype, required: required, doc: doc} = field ->
          entry = %{
            "name" => Atom.to_string(fname),
            "type" => Atom.to_string(ftype),
            "required" => required,
            "doc" => doc
          }

          case Map.get(field, :max_length) do
            nil -> entry
            max_length -> Map.put(entry, "max_length", max_length)
          end
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
    from typing import Annotated, Optional
    from pydantic import BaseModel, Field

    class AttributeLengthCap:
        __slots__ = ("max_length",)

        def __init__(self, max_length):
            self.max_length = max_length

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
            max_length = get(f, "max_length")
            if required:
                annotations[fname] = py_type
                defaults[fname] = Field(..., description=doc) if doc else Field(...)
            else:
                annotations[fname] = Optional[py_type]
                defaults[fname] = Field(default=None, description=doc) if doc else Field(default=None)
            if max_length is not None:
                annotations[fname] = Annotated[annotations[fname], AttributeLengthCap(int(max_length))]
        namespace = {"__annotations__": annotations, **defaults}
        if description:
            namespace["__doc__"] = description
        cls = type(name, (BaseModel,), namespace)
        classes[name] = cls
    classes
    """
  end

  # ── Defaults: real Pythonx-backed construction ──────────────

  defp default_construct_falkor_db({:embedded, data_dir}, socket_timeout, nil) do
    db_path = Path.join(data_dir, "gralkor.db")

    {db, _} =
      Pythonx.eval(
        """
        from redis.asyncio.retry import Retry
        from redis.backoff import NoBackoff
        from redislite.async_falkordb_client import AsyncFalkorDB
        AsyncFalkorDB(
          db_path.decode('utf-8') if isinstance(db_path, (bytes, bytearray)) else db_path,
          socket_timeout=socket_timeout,
          retry=Retry(NoBackoff(), 0),
        )
        """,
        %{"db_path" => db_path, "socket_timeout" => socket_timeout}
      )

    db
  end

  defp default_construct_falkor_db({:remote, kw}, socket_timeout, max_connections) do
    host = Keyword.fetch!(kw, :host)
    port = Keyword.fetch!(kw, :port)
    username = Keyword.get(kw, :username)
    password = Keyword.get(kw, :password)
    ssl = Keyword.get(kw, :ssl, false)

    {db, _} =
      Pythonx.eval(
        """
        import asyncio
        import redis.exceptions
        from redis.asyncio.connection import BlockingConnectionPool
        from redis.asyncio.retry import Retry
        from redis.backoff import NoBackoff
        from falkordb.asyncio import FalkorDB

        # Waits up to the socket timeout for a free connection instead of
        # failing at once with MaxConnectionsError, and reports a wait that
        # runs out as a timeout.
        class _WaitingConnectionPool(BlockingConnectionPool):
            async def get_connection(self, *args, **kwargs):
                try:
                    return await super().get_connection(*args, **kwargs)
                except redis.exceptions.ConnectionError as err:
                    if isinstance(err.__cause__, asyncio.TimeoutError):
                        raise redis.exceptions.TimeoutError(
                            f"no FalkorDB connection was free within {self.timeout}s "
                            f"(max_connections={self.max_connections})"
                        ) from err
                    raise

        h = host.decode('utf-8') if isinstance(host, (bytes, bytearray)) else host
        u = username.decode('utf-8') if isinstance(username, (bytes, bytearray)) else username
        p = password.decode('utf-8') if isinstance(password, (bytes, bytearray)) else password
        database = FalkorDB(
            host=h,
            port=port,
            username=u,
            password=p,
            ssl=ssl,
            socket_timeout=socket_timeout,
            socket_connect_timeout=socket_timeout,
            max_connections=max_connections,
        )

        # FalkorDB(...) probes the server through a separate synchronous
        # client, so its own asynchronous pool has opened no connection yet.
        # Replace it with a waiting pool holding the same connection settings.
        built = database.connection.connection_pool
        database.connection.connection_pool = _WaitingConnectionPool(
            connection_class=built.connection_class,
            max_connections=max_connections,
            timeout=socket_timeout,
            **{**built.connection_kwargs, 'retry': Retry(NoBackoff(), 0)},
        )
        database
        """,
        %{
          "host" => host,
          "port" => port,
          "username" => username,
          "password" => password,
          "ssl" => ssl,
          "socket_timeout" => socket_timeout,
          "max_connections" => max_connections
        }
      )

    db
  end

  defp default_close_falkor_db(falkor_db, {:embedded, _data_dir}) do
    Gralkor.Python.run_coroutine(
      """
      async def close_embedded(database):
          client = database.client
          await client._client.aclose()
          sync_client = client._sync_client
          sync_client._async_managed = False
          sync_client._cleanup()
          client._async_managed = True
      close_embedded(database)
      """,
      %{"database" => falkor_db}
    )

    :ok
  end

  defp default_close_falkor_db(falkor_db, {:remote, _options}) do
    Gralkor.Python.run_coroutine(
      """
      database.aclose()
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
      case state.initialise_instance.(instance) do
        {:error, {:vector_indexes, message}} ->
          Logger.warning("[gralkor] build_indices_and_constraints failed (non-fatal): #{message}")

        _ ->
          :ok
      end
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
    Gralkor.Python.run_coroutine(
      """
      g.search('warmup', num_results=1)
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

  defp register_table(pid, table, read_timeout_ms) do
    ensure_registry()
    :ets.insert(@registry, [{pid, table}, {{:read_timeout_ms, table}, read_timeout_ms}])
  end

  defp unregister_table(pid, table) do
    ensure_registry()
    :ets.delete(@registry, pid)
    :ets.delete(@registry, {:read_timeout_ms, table})
  end

  defp read_timeout_below(socket_timeout_seconds), do: max(trunc(socket_timeout_seconds * 900), 1)

  defp read_timeout_ms(server) do
    table = table_for(server)
    [{_, read_timeout_ms}] = :ets.lookup(ensure_registry(), {:read_timeout_ms, table})
    read_timeout_ms
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
