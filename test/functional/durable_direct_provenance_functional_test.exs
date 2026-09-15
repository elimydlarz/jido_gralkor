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
