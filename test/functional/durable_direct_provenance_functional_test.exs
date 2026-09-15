defmodule Gralkor.DurableDirectProvenanceFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional
  @moduletag timeout: 120_000

  setup do
    directory = Path.join(System.tmp_dir!(), "direct-provenance-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    {server, globals} = Pythonx.eval("""
    from redislite import Redis
    from falkordb import FalkorDB
    server = Redis(dbfilename=path.decode(), serverconfig={'port': '0'})
    server.config_set('loglevel', 'warning')
    server.config_set('save', '')
    database = FalkorDB(unix_socket_path=server.socket_file)
    server
    """, %{"path" => Path.join(directory, "fixture.rdb")})
    {socket, _} = Pythonx.eval("server.socket_file", %{"server" => server})
    on_exit(fn ->
      Pythonx.eval("server.shutdown(save=False, now=True, force=True)", %{"server" => server})
      File.rm_rf!(directory)
    end)
    context = %{database: globals["database"], connection: [unix_socket_path: Pythonx.decode(socket)]}
    start_public_runtime(context)
    context
  end

  describe "when direct memory is stored in a real graph" do
    test "then ordinary direct writes retain durable writer metadata through public episode and fact search", context do
      assert_direct_round_trip(context, false)
    end

    test "and deterministic direct writes retain durable writer metadata through public episode and fact search", context do
      assert_direct_round_trip(context, true)
    end

    test "and historical marker-like text without durable metadata stays unchanged and unclassified", context do
      description = "reflection:old prose [gralkor: direct]"
      assert :ok = Gralkor.GraphitiPool.add_episode("personal/owner", "amber orchard", description, nil)
      {result, _} = Pythonx.eval("""
      graph = database.select_graph('g_' + b'personal/owner'.hex())
      graph.create_node_fulltext_index('Episodic', 'content', 'group_id', 'source', 'source_description')
      graph.query('MATCH (e:Episodic) RETURN e._gralkor_writer').result_set
      """, %{"database" => context.database})
      assert Pythonx.decode(result) == [[nil]]
      assert {:ok, [%{episode: episode}]} = public_search(:episodes)
      assert episode.source_description == description
      refute Map.has_key?(episode, :writer)
      refute Map.has_key?(episode, :lens)
      refute Map.has_key?(episode, :reflection)
    end
  end

  defp assert_direct_round_trip(context, deterministic) do
    description = "reflection:manual [lens: observations]"
    if deterministic do
      assert :ok = Gralkor.GraphitiPool.add_episode("personal/owner", "amber orchard", description, nil, uuid: "stable-direct", writer: :direct)
    else
      assert :ok = Gralkor.Client.Native.memory_add("personal/owner", "amber orchard", description)
    end

    {result, _} = Pythonx.eval("""
    graph = database.select_graph('g_' + b'personal/owner'.hex())
    graph.query('MATCH (e:Episodic) RETURN e.uuid, e._gralkor_writer').result_set
    """, %{"database" => context.database})
    assert [[uuid, "direct"]] = Pythonx.decode(result)
    assert {:ok, %{"_gralkor_writer" => "direct"}} = Gralkor.GraphitiPool.get_episode("personal/owner", uuid)

    # A controlled extracted fact points to the episode actually written above.
    # Search and source hydration still use the real graph and public client.
    Pythonx.eval("""
    graph = database.select_graph('g_' + b'personal/owner'.hex())
    graph.create_node_fulltext_index('Episodic', 'content', 'group_id', 'source', 'source_description')
    graph.query('''
      MATCH (e:Episodic {uuid: $uuid})
      CREATE (a:Entity {uuid: 'amber', name: 'amber', group_id: e.group_id, summary: '', created_at: e.created_at}),
             (b:Entity {uuid: 'orchard', name: 'orchard', group_id: e.group_id, summary: '', created_at: e.created_at}),
             (a)-[f:RELATES_TO {uuid: 'fact', name: 'GROWS', fact: 'amber grows in orchard', episodes: [e.uuid], group_id: e.group_id, created_at: e.created_at, valid_at: e.valid_at}]->(b)
      SET f.fact_embedding = vecf32([0.3, 0.2, 0.1])
    ''', {'uuid': uuid.decode()})
    """, %{"database" => context.database, "uuid" => uuid})

    assert {:ok, [%{episode: episode}]} = public_search(:episodes)
    assert episode.writer == :direct
    assert episode.source_description == description
    refute Map.has_key?(episode, :lens)
    refute Map.has_key?(episode, :reflection)
    assert {:ok, [%{fact: %{sources: [source]}}]} = public_search(:facts)
    assert source.writer == :direct
    assert source.source_description == description
    assert source.id == uuid
    refute Map.has_key?(source, :lens)
    refute Map.has_key?(source, :reflection)
  end

  defp public_search(type) do
    Gralkor.Client.search(self(), %Gralkor.Search{operator_id: "owner", query: "amber", destinations: ["personal"], result_type: type})
  end

  defp start_public_runtime(context) do
    {telemetry, _} = Pythonx.eval("import os\nos.environ.get('GRAPHITI_TELEMETRY_ENABLED')", %{})

    on_exit(fn ->
      Pythonx.eval(
        "import os\nos.environ.pop('GRAPHITI_TELEMETRY_ENABLED', None) if previous is None else os.environ.__setitem__('GRAPHITI_TELEMETRY_ENABLED', previous)",
        %{"previous" => telemetry}
      )
    end)

    keys = [:client, :destination_storage, :lens_storage]
    previous = Map.new(keys, &{&1, Application.get_env(:jido_gralkor, &1)})
    Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)
    Application.put_env(:jido_gralkor, :destination_storage, Gralkor.Destination.Storage.Graphiti)
    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.Graphiti)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:jido_gralkor, key),
          else: Application.put_env(:jido_gralkor, key, value)
      end)
    end)

    shared_clients = fn _, _ ->
      {_, globals} =
        Pythonx.eval(
          """
          import os
          os.environ['GRAPHITI_TELEMETRY_ENABLED'] = 'false'
          from graphiti_core.llm_client import OpenAIClient, LLMConfig
          from graphiti_core.embedder.openai import OpenAIEmbedder, OpenAIEmbedderConfig
          from graphiti_core.cross_encoder.openai_reranker_client import OpenAIRerankerClient
          config = LLMConfig(api_key='isolated-fixture', base_url='http://127.0.0.1:1')
          llm = OpenAIClient(config=config)
          embedder = OpenAIEmbedder(config=OpenAIEmbedderConfig(api_key='isolated-fixture', base_url='http://127.0.0.1:1', embedding_dim=3))
          cross_encoder = OpenAIRerankerClient(config=config)
          async def generate_response(*args, **kwargs):
              model = kwargs.get('response_model')
              name = model.__name__ if model is not None else ''
              if name == 'ExtractedEntities': return {'extracted_entities': []}
              if name == 'ExtractedEdges': return {'edges': []}
              raise AssertionError('unexpected external inference: ' + name)
          async def create(*args, **kwargs): return [0.1, 0.2, 0.3]
          async def create_batch(values): return [[0.1, 0.2, 0.3] for _ in values]
          async def rank(query, passages): return [(passage, 1.0) for passage in passages]
          llm.generate_response = generate_response
          embedder.create = create
          embedder.create_batch = create_batch
          cross_encoder.rank = rank
          """,
          %{}
        )

      %{
        llm_client: globals["llm"],
        embedder: globals["embedder"],
        cross_encoder: globals["cross_encoder"]
      }
    end

    start_supervised!(
      {Gralkor.GraphitiPool,
       falkordb_spec: {:remote, []},
       warmup: false,
       construct_shared_clients: shared_clients,
       initialise_instance: fn _ -> :ok end,
       construct_falkor_db: fn _ ->
         {database, _} =
           Pythonx.eval(
             "from falkordb.asyncio import FalkorDB\nFalkorDB(unix_socket_path=socket.decode())",
             %{"socket" => context.connection[:unix_socket_path]}
           )

         database
       end}
    )

    start_supervised!(
      {JidoGralkor.Runtime,
       owner: self(),
       configuration: %{
         destinations: [],
         lenses: [],
         reflections: [
           %{
             name: "review",
             chain_of_thought: %{
               steps: [%{label: "review", directions: "Review", output: %{"summary" => "string"}}]
             },
             outputs: [%{kind: :destination, destination: "personal"}]
           }
         ]
       }}
    )
  end

end
