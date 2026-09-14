defmodule Gralkor.PersonalGraphMigrationFunctionalTest do
  use ExUnit.Case, async: false

  alias Gralkor.PersonalGraphMigration

  @moduletag :functional
  @moduletag timeout: 120_000

  setup_all do
    directory = Path.join(System.tmp_dir!(), "personal-migration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    {server, globals} =
      Pythonx.eval(
        """
        from redislite import Redis
        from falkordb import FalkorDB
        server = Redis(dbfilename=path.decode(), serverconfig={'port': 0})
        database = FalkorDB(unix_socket_path=server.socket_file)
        server
        """,
        %{"path" => Path.join(directory, "fixture.rdb")}
      )

    {socket, _} = Pythonx.eval("server.socket_file", %{"server" => server})

    on_exit(fn ->
      Pythonx.eval("server.shutdown(save=False, now=True, force=True)", %{"server" => server})
      File.rm_rf!(directory)
    end)

    %{connection: [unix_socket_path: Pythonx.decode(socket)], database: globals["database"], directory: directory}
  end

  setup context do
    Pythonx.eval("[database.select_graph(name).delete() for name in database.list_graphs()]", %{
      "database" => context.database
    })

    :ok
  end

  describe "when an application inventories explicitly identified historical private graphs" do
    test "then the manifest preserves each operator identifier byte for byte in its old and new logical names", context do
      identifiers = ["owner", "dashboard:ABC-123", "a/b", "a_b", "CaseSensitive"]

      assert {:ok, manifest} = PersonalGraphMigration.plan(context.connection, identifiers, %{})

      assert Enum.map(manifest["graphs"], &{&1["source_logical"], &1["target_logical"]}) ==
               Enum.map(identifiers, &{"operator/" <> &1, "personal/" <> &1})
    end

    test "and the manifest inventories all node and relationship properties, UUIDs, endpoints, indexes, constraints, and configuration references", context do
      seed_history(context.database, "owner")
      references = %{"destinations" => ["global"], "lenses" => ["observations"], "active_configuration" => "revision-unchanged"}

      assert {:ok, manifest} = PersonalGraphMigration.plan(context.connection, ["owner"], references)
      assert manifest["configuration_references"] == references
      inventory = hd(manifest["graphs"])["source_inventory"]
      assert Enum.map(inventory["nodes"], & &1["properties"]["uuid"]) |> Enum.sort() ==
               Enum.sort(["episode", "entity-a", "entity-b", "community", "complete", "incomplete", "complete", "incomplete"])
      assert Enum.any?(inventory["relationships"], &(&1["properties"]["episodes"] == ["episode"]))
      assert Enum.all?(inventory["relationships"], &(is_integer(&1["source"]) and is_integer(&1["target"])))
      assert Enum.any?(inventory["indexes"], &(&1["label"] == "Episodic"))
      assert Enum.any?(inventory["constraints"], &(&1["label"] == "_GralkorEpisodeClaim" and &1["properties"] == ["uuid"]))
      assert "_gralkor_lens" in inventory["property_keys"]
    end
  end

  defp seed_history(database, identity) do
    Pythonx.eval(
      """
      import time
      gid = 'g_' + ('operator/' + identity.decode()).encode().hex()
      graph = database.select_graph(gid)
      graph.query('''
        CREATE (episode:Episodic {uuid: 'episode', group_id: $gid, name: 'historical memory', content: 'remember amber orchard', source: 'text', source_description: 'captured [lens: operator]', created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z', entity_edges: ['fact']}),
               (a:Entity {uuid: 'entity-a', group_id: $gid, name: 'amber', summary: 'historical entity', created_at: '2026-01-01T00:00:00Z', _gralkor_lens: 'observations'}),
               (b:Entity {uuid: 'entity-b', group_id: $gid, name: 'orchard', summary: 'historical entity', created_at: '2026-01-01T00:00:00Z'}),
               (community:Community {uuid: 'community', group_id: $gid, name: 'garden', summary: 'community', created_at: '2026-01-01T00:00:00Z'}),
               (complete:Episodic {uuid: 'complete', group_id: $gid, name: 'completed reflection', content: '{"id":"complete","payload":{"summary":"immutable amber"}}', source: 'text', source_description: 'reflection:erl', created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z', entity_edges: [], _gralkor_extraction_complete: true}),
               (incomplete:Episodic {uuid: 'incomplete', group_id: $gid, name: 'incomplete reflection', content: '{"id":"incomplete","payload":{"summary":"immutable orchard"}}', source: 'text', source_description: 'reflection:erl', created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z', entity_edges: []}),
               (finished_claim:_GralkorEpisodeClaim {uuid: 'complete', group_id: $gid, generation: 7, _gralkor_fenced_generation: 7, content: complete.content, source: complete.source, source_description: complete.source_description}),
               (unfinished_claim:_GralkorEpisodeClaim {uuid: 'incomplete', group_id: $gid, generation: 3, _gralkor_fenced_generation: 2, owner: 'stopped-worker', lease_until_ms: 1, content: incomplete.content, source: incomplete.source, source_description: incomplete.source_description}),
               (a)-[fact:RELATES_TO {uuid: 'fact', group_id: $gid, name: 'GROWS', fact: 'amber grows in orchard', episodes: ['episode'], created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z'}]->(b),
               (episode)-[:MENTIONS {uuid: 'mention', group_id: $gid}]->(a),
               (community)-[:HAS_MEMBER {uuid: 'membership', group_id: $gid}]->(a)
        SET a.name_embedding = vecf32([0.1, 0.2, 0.3]), fact.fact_embedding = vecf32([0.3, 0.2, 0.1])
      ''', {'gid': gid})
      graph.create_node_fulltext_index('Episodic', 'content', 'group_id', 'source', 'source_description')
      graph.create_node_vector_index('Entity', 'name_embedding', dim=3, similarity_function='cosine')
      graph.create_node_range_index('_GralkorEpisodeClaim', 'uuid')
      graph.create_node_unique_constraint('_GralkorEpisodeClaim', 'uuid')
      for _ in range(1000):
          if all(row['status'] == 'OPERATIONAL' for row in graph.list_constraints()):
              break
          time.sleep(0.01)
      """,
      %{"database" => database, "identity" => identity}
    )
  end
end
