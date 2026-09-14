defmodule Gralkor.PersonalGraphMigrationFunctionalTest do
  use ExUnit.Case, async: false

  alias Gralkor.PersonalGraphMigration

  @quiescence %{
    admission_stopped: true,
    capture_buffers: 0,
    asynchronous_additions: 0,
    reflection_workers: 0,
    queued_deliveries: 0,
    schedulers: 0,
    consuming_runtimes: 0,
    failed_work: 0
  }

  @moduletag :functional
  @moduletag timeout: 120_000

  setup_all do
    directory =
      Path.join(System.tmp_dir!(), "personal-migration-#{System.unique_integer([:positive])}")

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

    %{
      connection: [unix_socket_path: Pythonx.decode(socket)],
      database: globals["database"],
      directory: directory
    }
  end

  setup context do
    Pythonx.eval("[database.select_graph(name).delete() for name in database.list_graphs()]", %{
      "database" => context.database
    })

    :ok
  end

  describe "when an application requests a private graph migration > if no explicit graph endpoint is supplied" do
    test "then migration rejects the connection before opening a default store" do
      assert {:error, message} = PersonalGraphMigration.plan([port: -1], ["owner"], %{})
      assert message =~ "explicit graph endpoint"
    end
  end

  describe "when an application migrates a consistent backup restored into a separate FalkorDB server" do
    test "then restored graph content and operational schema remain intact through migration and public recall", context do
      %{restored: restored, before: before, evidence: evidence} = restore_history(context)
      assert evidence["source_pid"] != evidence["restored_pid"]
      assert evidence["source_run_id"] != evidence["restored_run_id"]
      assert evidence["source_stopped"]
      assert evidence["source_rdb_sha256"] == evidence["restored_rdb_sha256"]
      assert evidence["rdb_size"] > 0
      assert evidence["rdb_loaded"]
      assert {:ok, ^before} = PersonalGraphMigration.plan(restored.connection, ["owner", "a/b", "a_b"], %{})

      journal = Path.join(context.directory, "restored-migration.json")
      assert {:ok, _} = PersonalGraphMigration.prepare(restored.connection, ["owner", "a/b", "a_b"], %{}, journal)
      assert {:ok, manifest} = PersonalGraphMigration.apply(restored.connection, journal, @quiescence)
      for graph <- manifest["graphs"] do
        expected = Enum.reduce(["nodes", "relationships"], graph["source_inventory"], fn kind, inventory ->
          Map.update!(inventory, kind, fn records ->
            Enum.map(records, fn record -> put_in(record, ["properties", "group_id"], graph["target_physical"]) end)
          end)
        end)
        assert graph["target_inventory"] == expected
        assert Enum.all?(expected["indexes"] ++ expected["constraints"], &(&1["status"] == "OPERATIONAL"))
      end

      start_public_runtime(restored)
      for {identity, content} <- [{"owner", "remember amber orchard"}, {"a/b", "amber slash"}, {"a_b", "amber underscore"}] do
        assert {:ok, results} = Gralkor.Client.search(self(), %Gralkor.Search{operator_id: identity, query: "amber", destinations: ["personal"]})
        assert Enum.filter(results, &Map.has_key?(&1.episode, :content)) == [%{destination: "personal", episode: %{content: content, source_description: "captured", source_kind: "document", lens: "operator"}}]
      end
      assert {:ok, [%{artefact: %Gralkor.Artefact{id: "complete", payload: %{"summary" => "immutable amber"}}}]} = Gralkor.Client.search(self(), %Gralkor.Search{operator_id: "owner", query: "amber", destinations: ["personal"], result_type: :artefacts, artefact_id: "complete"})
      assert {:ok, []} = Gralkor.Client.search(self(), %Gralkor.Search{operator_id: "owner", query: "orchard", destinations: ["personal"], result_type: :artefacts, artefact_id: "incomplete"})
      IO.puts("Restored migration fixture: " <> Jason.encode!(Map.put(evidence, "versions", manifest["versions"])))
    end
  end

  describe "when the migration command receives an unsupported operation" do
    test "then it reports usage without connecting to a graph" do
      assert_raise Mix.Error, ~r/operation|usage|Usage/, fn ->
        Mix.Tasks.Gralkor.MigratePersonal.run(["unknown", "/missing-migration-request.json"])
      end
    end
  end

  describe "when the migration command receives explicit JSON requests for a private graph" do
    test "then plan, prepare, advance, apply, and rollback return their durable graph phases",
         context do
      seed_history(context.database, "owner")
      original_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(original_shell) end)
      journal = Path.join(context.directory, "#{System.unique_integer([:positive])}.json")
      request_path = journal <> ".request"

      File.write!(
        request_path,
        Jason.encode!(%{
          connection: Map.new(context.connection),
          operator_ids: ["owner"],
          configuration_references: %{},
          journal_path: journal,
          quiescence: @quiescence
        })
      )

      for {operation, phase, graph_phase} <- [
            {"plan", "planned", "planned"},
            {"prepare", "planned", "planned"},
            {"advance", "planned", "copied"},
            {"apply", "verified", "verified"},
            {"rollback", "rolled_back", "rolled_back"}
          ] do
        Mix.Tasks.Gralkor.MigratePersonal.run([operation, request_path])
        assert_receive {:mix_shell, :info, [json]}
        manifest = Jason.decode!(json)
        assert manifest["phase"] == phase
        assert hd(manifest["graphs"])["phase"] == graph_phase
      end
    end
  end

  describe "when an application prepares a private graph migration > if a source node or relationship carries an incompatible stored group identity" do
    test "then preparation refuses while records without a group identity remain preservable",
         context do
      seed_history(context.database, "owner")
      query(context.database, "operator/owner", "CREATE (:Historical {uuid: 'unscoped'})")
      journal = Path.join(context.directory, "#{System.unique_integer([:positive])}.json")

      for match <- ["MATCH (item:Entity {uuid: 'entity-a'})", "MATCH ()-[item:RELATES_TO]->()"] do
        query(context.database, "operator/owner", match <> " SET item.group_id = 'foreign'")

        assert {:error, message} =
                 PersonalGraphMigration.prepare(context.connection, ["owner"], %{}, journal)

        assert message =~ "incompatible stored group identity"
        refute File.exists?(journal)

        query(
          context.database,
          "operator/owner",
          match <>
            " SET item.group_id = '" <> Gralkor.Client.sanitize_group_id("operator/owner") <> "'"
        )
      end

      assert {:ok, _} =
               PersonalGraphMigration.prepare(context.connection, ["owner"], %{}, journal)

      assert {:ok, manifest} =
               PersonalGraphMigration.apply(context.connection, journal, @quiescence)

      unscoped =
        Enum.find(
          hd(manifest["graphs"])["target_inventory"]["nodes"],
          &(&1["properties"]["uuid"] == "unscoped")
        )

      refute Map.has_key?(unscoped["properties"], "group_id")
    end
  end

  describe "when an application requests a private graph migration > if operator identities are empty, blank, duplicated, non-textual, or already resolved graph names" do
    test "then migration rejects the identities before connecting to a graph" do
      for identities <- [
            [],
            [""],
            [" "],
            [42],
            [nil],
            ["owner", "owner"],
            ["operator/owner"],
            ["personal/owner"]
          ] do
        assert {:error, message} =
                 PersonalGraphMigration.plan(
                   [unix_socket_path: "/does-not-exist"],
                   identities,
                   %{}
                 )

        assert message =~ "operator identities"
      end
    end
  end

  describe "when an application requests a private graph migration > if the persisted manifest fails its integrity check" do
    test "then migration refuses before changing any graph", context do
      journal = prepare_history(context)
      tamper_manifest(journal, "manifest['configuration_references']['changed'] = True", false)
      assert {:ok, before} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})

      assert {:error, message} =
               PersonalGraphMigration.apply(context.connection, journal, @quiescence)

      assert message =~ "manifest integrity"
      assert {:ok, ^before} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})
    end
  end

  describe "when an application requests a private graph migration > if a manifest has inconsistent identity mappings or migration phases" do
    test "then migration refuses before changing any graph", context do
      journal = prepare_history(context)

      assert {:ok, _result} =
               PersonalGraphMigration.apply(context.connection, journal, @quiescence)

      valid_manifest = File.read!(journal)
      assert {:ok, before} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})

      for alteration <- [
            "entry = manifest['graphs'][0]; entry['target_physical'] = entry['source_physical']; entry['target_logical'] = entry['source_logical']; entry['target_inventory'] = entry['source_inventory']",
            "manifest['phase'] = 'unknown'",
            "manifest['graphs'][0]['phase'] = 'planned'"
          ] do
        File.write!(journal, valid_manifest)
        tamper_manifest(journal, alteration, true)

        assert {:error, message} =
                 PersonalGraphMigration.rollback(context.connection, journal, @quiescence)

        assert message =~ "manifest"
        assert {:ok, ^before} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})
      end
    end
  end

  describe "when an application inventories explicitly identified historical private graphs" do
    test "then the manifest preserves each operator identifier byte for byte in its old and new logical names",
         context do
      identifiers = ["owner", "dashboard:ABC-123", "a/b", "a_b", "CaseSensitive"]

      assert {:ok, manifest} = PersonalGraphMigration.plan(context.connection, identifiers, %{})

      assert Enum.map(manifest["graphs"], &{&1["source_logical"], &1["target_logical"]}) ==
               Enum.map(identifiers, &{"operator/" <> &1, "personal/" <> &1})
    end

    test "and the manifest records both graph names using the existing injective physical encoding",
         context do
      assert {:ok, manifest} =
               PersonalGraphMigration.plan(context.connection, ["owner", "a/b", "a_b"], %{})

      for graph <- manifest["graphs"] do
        assert graph["source_physical"] ==
                 Gralkor.Client.sanitize_group_id(graph["source_logical"])

        assert graph["target_physical"] ==
                 Gralkor.Client.sanitize_group_id(graph["target_logical"])
      end

      assert manifest["graphs"] |> Enum.map(& &1["target_physical"]) |> Enum.uniq() |> length() ==
               3
    end

    test "and the manifest reports source and target existence without creating either graph",
         context do
      seed_history(context.database, "owner")
      {before, _} = Pythonx.eval("database.list_graphs()", %{"database" => context.database})

      assert {:ok, manifest} =
               PersonalGraphMigration.plan(context.connection, ["owner", "missing"], %{})

      assert Enum.map(manifest["graphs"], &{&1["source_exists"], &1["target_exists"]}) == [
               {true, false},
               {false, false}
             ]

      {afterward, _} = Pythonx.eval("database.list_graphs()", %{"database" => context.database})
      assert Pythonx.decode(before) == Pythonx.decode(afterward)
    end

    test "and the manifest reports the installed Graphiti and connected FalkorDB versions",
         context do
      assert {:ok, manifest} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})
      assert manifest["versions"]["graphiti"] == "0.29.3"

      assert Enum.any?(
               manifest["versions"]["modules"],
               &(&1["name"] == "graph" and is_integer(&1["ver"]))
             )

      assert manifest["versions"]["server"] =~ ~r/^\d+\.\d+/
      IO.puts("Migration fixture versions: " <> Jason.encode!(manifest["versions"]))
    end

    test "and the manifest inventories all node and relationship properties, UUIDs, endpoints, indexes, constraints, and configuration references",
         context do
      seed_history(context.database, "owner")

      references = %{
        "destinations" => ["global"],
        "lenses" => ["observations"],
        "active_configuration" => "revision-unchanged"
      }

      assert {:ok, manifest} =
               PersonalGraphMigration.plan(context.connection, ["owner"], references)

      assert manifest["configuration_references"] == references
      inventory = hd(manifest["graphs"])["source_inventory"]

      assert inventory["node_uuids"]["Episodic"] == %{
               "count" => 3,
               "values" => ["complete", "episode", "incomplete"]
             }

      assert inventory["relationship_uuids"]["RELATES_TO"] == %{
               "count" => 1,
               "values" => ["fact"]
             }

      assert Enum.map(inventory["nodes"], & &1["properties"]["uuid"]) |> Enum.sort() ==
               Enum.sort([
                 "episode",
                 "entity-a",
                 "entity-b",
                 "community",
                 "complete",
                 "incomplete",
                 "complete",
                 "incomplete"
               ])

      assert Enum.any?(inventory["relationships"], &(&1["properties"]["episodes"] == ["episode"]))

      assert Enum.all?(
               inventory["relationships"],
               &(is_integer(&1["source"]) and is_integer(&1["target"]))
             )

      assert Enum.any?(inventory["indexes"], &(&1["label"] == "Episodic"))

      assert Enum.any?(
               inventory["constraints"],
               &(&1["label"] == "_GralkorEpisodeClaim" and &1["properties"] == ["uuid"])
             )

      assert "_gralkor_lens" in inventory["property_keys"]
    end
  end

  describe "when an application prepares a private graph migration > if any writer remains admitted, buffered, active, or failed during cutover" do
    test "then migration refuses before copying any graph", context do
      journal = prepare_history(context)

      Enum.each(@quiescence, fn {kind, value} ->
        pending = Map.put(@quiescence, kind, if(value == true, do: false, else: 1))

        assert {:error, message} =
                 PersonalGraphMigration.apply(context.connection, journal, pending)

        assert message =~ "quiescence"
      end)

      assert {:ok, manifest} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})
      refute hd(manifest["graphs"])["target_exists"]
    end
  end

  describe "when an application prepares a private graph migration > if a consumer Destination conflicts with the new private namespace" do
    test "then migration refuses before changing any graph", context do
      seed_history(context.database, "owner")

      for name <- ["personal", "personal/shared"] do
        journal = Path.join(context.directory, "#{System.unique_integer([:positive])}.json")

        assert {:error, message} =
                 PersonalGraphMigration.prepare(
                   context.connection,
                   ["owner"],
                   %{"destinations" => [name]},
                   journal
                 )

        assert message =~ "Destination namespace conflict"
        refute File.exists?(journal)
      end

      assert {:ok, manifest} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})
      refute hd(manifest["graphs"])["target_exists"]
    end
  end

  describe "when an application prepares a private graph migration > if a consumer Lens already owns the packaged personal-chat name" do
    test "then migration refuses before changing any graph", context do
      seed_history(context.database, "owner")
      journal = Path.join(context.directory, "#{System.unique_integer([:positive])}.json")

      assert {:error, message} =
               PersonalGraphMigration.prepare(
                 context.connection,
                 ["owner"],
                 %{"lenses" => ["personal-chat"]},
                 journal
               )

      assert message =~ "Lens namespace conflict"
      refute File.exists?(journal)
    end
  end

  describe "when an application prepares a private graph migration > if an explicitly identified source graph is missing" do
    test "then migration refuses without guessing a former lossy graph name", context do
      Pythonx.eval(
        "database.select_graph('operator_owner').query('CREATE (:Historical {uuid: 42})')",
        %{"database" => context.database}
      )

      journal = Path.join(context.directory, "#{System.unique_integer([:positive])}.json")

      assert {:error, message} =
               PersonalGraphMigration.prepare(context.connection, ["owner"], %{}, journal)

      assert message =~ "source graph missing"
      refute File.exists?(journal)
      {graphs, _} = Pythonx.eval("database.list_graphs()", %{"database" => context.database})
      assert Pythonx.decode(graphs) == ["operator_owner"]
    end
  end

  describe "when an application prepares a private graph migration > if an unrelated graph already occupies a target name" do
    test "then migration refuses before changing any graph", context do
      seed_history(context.database, "owner")

      Pythonx.eval(
        "database.select_graph('g_' + b'personal/owner'.hex()).query('CREATE (:Unrelated {uuid: 42})')",
        %{"database" => context.database}
      )

      assert {:ok, before} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})
      journal = Path.join(context.directory, "#{System.unique_integer([:positive])}.json")

      assert {:error, message} =
               PersonalGraphMigration.prepare(context.connection, ["owner"], %{}, journal)

      assert message =~ "target graph already exists"
      assert {:ok, ^before} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})
    end
  end

  describe "when an application prepares a private graph migration > if an episode claim still has an active lease" do
    test "then migration refuses before copying its graph", context do
      seed_history(context.database, "owner")

      query(
        context.database,
        "operator/owner",
        "MATCH (claim:_GralkorEpisodeClaim {uuid: 'incomplete'}) SET claim.owner = 'active-worker', claim.lease_until_ms = timestamp() + 60000"
      )

      journal = Path.join(context.directory, "#{System.unique_integer([:positive])}.json")

      assert {:ok, _manifest} =
               PersonalGraphMigration.prepare(context.connection, ["owner"], %{}, journal)

      assert {:error, message} =
               PersonalGraphMigration.apply(context.connection, journal, @quiescence)

      assert message =~ "active episode claim"
      assert {:ok, current} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})
      refute hd(current["graphs"])["target_exists"]
    end
  end

  describe "when an application migrates quiescent historical private graphs" do
    test "then every node and relationship group identity changes to its matching personal graph identity",
         context do
      seed_history(context.database, "owner")
      journal = Path.join(context.directory, "#{System.unique_integer([:positive])}.json")

      assert {:ok, _manifest} =
               PersonalGraphMigration.prepare(context.connection, ["owner"], %{}, journal)

      assert {:ok, %{"phase" => "verified"}} =
               PersonalGraphMigration.apply(context.connection, journal, @quiescence)

      assert {:ok, manifest} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})
      graph = hd(manifest["graphs"])

      assert Enum.all?(
               graph["target_inventory"]["nodes"] ++ graph["target_inventory"]["relationships"],
               fn entity ->
                 entity["properties"]["group_id"] == graph["target_physical"]
               end
             )

      assert graph["target_inventory"]["node_count"] == 8
      assert graph["target_inventory"]["relationship_count"] == 3
    end

    test "and episode, entity, community, relationship, and claim UUIDs remain equal", context do
      {source, target} = migrate_history(context)

      assert Enum.map(source["nodes"], & &1["properties"]["uuid"]) ==
               Enum.map(target["nodes"], & &1["properties"]["uuid"])

      assert Enum.map(source["relationships"], & &1["properties"]["uuid"]) ==
               Enum.map(target["relationships"], & &1["properties"]["uuid"])
    end

    test "and relationship endpoints and fact-to-episode references remain equal", context do
      {source, target} = migrate_history(context)

      assert Enum.map(
               source["relationships"],
               &{&1["source"], &1["target"], &1["properties"]["episodes"]}
             ) ==
               Enum.map(
                 target["relationships"],
                 &{&1["source"], &1["target"], &1["properties"]["episodes"]}
               )
    end

    test "and immutable artefact content, embeddings, timestamps, source provenance, and Lens ownership remain equal",
         context do
      {source, target} = migrate_history(context)

      for kind <- ["nodes", "relationships"] do
        assert Enum.map(source[kind], &Map.delete(&1["properties"], "group_id")) ==
                 Enum.map(target[kind], &Map.delete(&1["properties"], "group_id"))
      end
    end

    test "and indexes and constraints remain operational with equal definitions", context do
      {source, target} = migrate_history(context)
      assert source["indexes"] == target["indexes"]
      assert source["constraints"] == target["constraints"]

      assert Enum.all?(
               target["indexes"] ++ target["constraints"],
               &(&1["status"] == "OPERATIONAL")
             )
    end

    test "and completed Reflection extraction markers remain complete", context do
      {_source, target} = migrate_history(context)
      assert episode(target, "complete")["_gralkor_extraction_complete"] == true
    end

    test "and incomplete Reflection extraction markers remain incomplete", context do
      {_source, target} = migrate_history(context)
      refute Map.has_key?(episode(target, "incomplete"), "_gralkor_extraction_complete")
    end

    test "and claim generations and fencing state remain equal under the new group identity",
         context do
      {source, target} = migrate_history(context)

      claims = fn inventory ->
        inventory["nodes"]
        |> Enum.filter(&("_GralkorEpisodeClaim" in &1["labels"]))
        |> Enum.map(&Map.delete(&1["properties"], "group_id"))
      end

      assert claims.(source) == claims.(target)
    end

    test "and the original graphs remain unchanged and restorable", context do
      journal = prepare_history(context)

      original =
        File.read!(journal)
        |> Jason.decode!()
        |> Map.fetch!("graphs")
        |> hd()
        |> Map.fetch!("source_inventory")

      assert {:ok, _result} =
               PersonalGraphMigration.apply(context.connection, journal, @quiescence)

      assert {:ok, current} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})
      assert hd(current["graphs"])["source_inventory"] == original
    end

    test "and two punctuation-sensitive operator identities remain isolated through public historical recall",
         context do
      for {identity, content} <- [{"a/b", "amber slash"}, {"a_b", "amber underscore"}] do
        seed_history(context.database, identity)

        query(
          context.database,
          "operator/" <> identity,
          "MATCH (e:Episodic {uuid: 'episode'}) SET e.content = '" <> content <> "'"
        )
      end

      journal = Path.join(context.directory, "#{System.unique_integer([:positive])}.json")

      assert {:ok, _} =
               PersonalGraphMigration.prepare(context.connection, ["a/b", "a_b"], %{}, journal)

      assert {:ok, _} = PersonalGraphMigration.apply(context.connection, journal, @quiescence)
      start_public_runtime(context)

      for {identity, content} <- [{"a/b", "amber slash"}, {"a_b", "amber underscore"}] do
        assert {:ok, results} =
                 Gralkor.Client.search(self(), %Gralkor.Search{
                   operator_id: identity,
                   query: "amber",
                   destinations: ["personal"]
                 })

        assert Enum.filter(results, &Map.has_key?(&1.episode, :content)) == [
                 %{
                   destination: "personal",
                   episode: %{
                     content: content,
                     source_description: "captured",
                     source_kind: "document",
                     lens: "operator"
                   }
                 }
               ]
      end
    end

    test "and migrated historical episodes remain searchable without an active operator Lens",
         context do
      migrate_history(context)
      start_public_runtime(context)

      assert {:ok, results} =
               Gralkor.Client.search(self(), %Gralkor.Search{
                 operator_id: "owner",
                 query: "orchard",
                 destinations: ["personal"]
               })

      assert Enum.any?(
               results,
               &(&1.episode[:content] == "remember amber orchard" and
                   &1.episode[:lens] == "operator")
             )

      assert_raise ArgumentError, ~r/Lens "operator" was retired/, fn ->
        Gralkor.Client.search(self(), %Gralkor.Search{
          operator_id: "owner",
          query: "orchard",
          lenses: ["operator"]
        })
      end
    end
  end

  describe "when an interrupted private graph migration resumes from its persisted manifest" do
    test "then a copied graph resumes without duplicating nodes or relationships", context do
      journal = prepare_history(context)
      {python, _} = Pythonx.eval("import sys\nsys.prefix + '/bin/python'", %{})

      request =
        Jason.encode!(%{
          action: "advance",
          connection: Map.new(context.connection),
          journal_path: journal,
          quiescence: @quiescence
        })

      for {boundary, expected_phase} <- [
            {"copy_intent", "copying"},
            {"copied", "copied"},
            {"nodes_rewritten", "nodes_rewritten"},
            {"relationships_rewritten", "relationships_rewritten"}
          ] do
        script = """
        import json, os, sys
        from pathlib import Path
        namespace = {}
        path = sys.argv[1]
        exec(compile(Path(path).read_text(), path, 'exec'), namespace)
        request = json.loads(sys.argv[2])
        boundary = sys.argv[3]
        if boundary == 'copy_intent':
            persist = namespace['persist']
            def interrupted_persist(path, manifest, create=False):
                persist(path, manifest, create)
                if manifest['graphs'][0]['phase'] == 'copying':
                    with namespace['FalkorDB'](**request['connection']) as database:
                        entry = manifest['graphs'][0]
                        database.select_graph(entry['source_physical']).copy(entry['target_physical'])
                    os._exit(73)
            namespace['persist'] = interrupted_persist
        namespace['execute'](request)
        os._exit(73)
        """

        assert {"", 73} =
                 System.cmd(
                   Pythonx.decode(python),
                   [
                     "-c",
                     script,
                     Application.app_dir(
                       :jido_gralkor,
                       "priv/python/personal_graph_migration.py"
                     ),
                     request,
                     boundary
                   ], stderr_to_stdout: true)

        assert hd(Jason.decode!(File.read!(journal))["graphs"])["phase"] == expected_phase
      end

      assert {:ok, completed} =
               PersonalGraphMigration.apply(context.connection, journal, @quiescence)

      target = hd(completed["graphs"])["target_inventory"]
      assert target["node_count"] == 8
      assert target["relationship_count"] == 3
    end

    test "and an already verified target returns the same completed migration result", context do
      journal = prepare_history(context)

      assert {:ok, completed} =
               PersonalGraphMigration.apply(context.connection, journal, @quiescence)

      assert {:ok, ^completed} =
               PersonalGraphMigration.apply(context.connection, journal, @quiescence)
    end
  end

  describe "when an interrupted private graph migration resumes from its persisted manifest > if the source changed after its recorded inventory" do
    test "then migration refuses without replacing either graph", context do
      journal = prepare_history(context)

      assert {:ok, _copied} =
               PersonalGraphMigration.advance(context.connection, journal, @quiescence)

      query(
        context.database,
        "operator/owner",
        "MATCH (episode:Episodic {uuid: 'episode'}) SET episode.content = 'changed source'"
      )

      assert {:ok, before} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})

      assert {:error, message} =
               PersonalGraphMigration.apply(context.connection, journal, @quiescence)

      assert message =~ "source changed"
      assert {:ok, ^before} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})
    end
  end

  describe "when an interrupted private graph migration resumes from its persisted manifest > if a recorded target contains conflicting data" do
    test "then migration refuses without replacing the conflicting target", context do
      journal = prepare_history(context)

      assert {:ok, _copied} =
               PersonalGraphMigration.advance(context.connection, journal, @quiescence)

      query(
        context.database,
        "personal/owner",
        "MATCH (episode:Episodic {uuid: 'episode'}) SET episode.content = 'conflicting target'"
      )

      assert {:ok, before} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})

      assert {:error, message} =
               PersonalGraphMigration.apply(context.connection, journal, @quiescence)

      assert message =~ "target"
      assert {:ok, ^before} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})
    end
  end

  describe "when an application rolls back a private graph migration before admitting new writers" do
    test "then public historical recall through the original graph returns the original memory",
         context do
      journal = prepare_history(context)
      assert {:ok, _} = PersonalGraphMigration.apply(context.connection, journal, @quiescence)
      assert {:ok, _} = PersonalGraphMigration.rollback(context.connection, journal, @quiescence)
      start_public_runtime(context)

      assert {:ok, episodes} =
               Gralkor.GraphitiPool.search_episodes("operator/owner", "orchard", 20)

      assert Enum.any?(episodes, &(&1[:content] == "remember amber orchard"))
    end

    test "and only matching migration-owned target graphs are removed", context do
      journal = prepare_history(context)
      query(context.database, "unrelated", "CREATE (:Memory {uuid: 'preserved'})")

      assert {:ok, _result} =
               PersonalGraphMigration.apply(context.connection, journal, @quiescence)

      assert {:ok, %{"phase" => "rolled_back"}} =
               PersonalGraphMigration.rollback(context.connection, journal, @quiescence)

      {graphs, _} = Pythonx.eval("database.list_graphs()", %{"database" => context.database})

      assert Enum.sort(Pythonx.decode(graphs)) ==
               Enum.sort(
                 Enum.map(["operator/owner", "unrelated"], &Gralkor.Client.sanitize_group_id/1)
               )
    end

    test "and a repeated rollback returns the same rolled-back result", context do
      journal = prepare_history(context)

      assert {:ok, _result} =
               PersonalGraphMigration.apply(context.connection, journal, @quiescence)

      assert {:ok, restored} =
               PersonalGraphMigration.rollback(context.connection, journal, @quiescence)

      assert {:ok, ^restored} =
               PersonalGraphMigration.rollback(context.connection, journal, @quiescence)
    end
  end

  describe "when an application rolls back a private graph migration before admitting new writers > if a target changed after verification" do
    test "then rollback refuses without deleting the changed graph", context do
      journal = prepare_history(context)

      assert {:ok, _result} =
               PersonalGraphMigration.apply(context.connection, journal, @quiescence)

      query(
        context.database,
        "personal/owner",
        "MATCH (episode:Episodic {uuid: 'episode'}) SET episode.content = 'newly written memory'"
      )

      assert {:ok, before} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})

      assert {:error, message} =
               PersonalGraphMigration.rollback(context.connection, journal, @quiescence)

      assert message =~ "target contains conflicting data"
      assert {:ok, ^before} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})
    end
  end

  defp episode(inventory, uuid) do
    inventory["nodes"]
    |> Enum.find(&("Episodic" in &1["labels"] and &1["properties"]["uuid"] == uuid))
    |> Map.fetch!("properties")
  end

  defp query(database, logical, cypher) do
    Pythonx.eval("database.select_graph('g_' + logical.hex()).query(cypher.decode())", %{
      "database" => database,
      "logical" => logical,
      "cypher" => cypher
    })
  end

  defp tamper_manifest(path, alteration, resign) do
    Pythonx.eval(
      """
      import hashlib, json
      path = path.decode()
      with open(path) as stream:
          manifest = json.load(stream)
      exec(alteration.decode())
      if resign:
          manifest.pop('integrity', None)
          canonical = json.dumps(manifest, sort_keys=True, ensure_ascii=False, separators=(',', ':'))
          manifest['integrity'] = hashlib.sha256(canonical.encode()).hexdigest()
      with open(path, 'w') as stream:
          json.dump(manifest, stream)
      """,
      %{"path" => path, "alteration" => alteration, "resign" => resign}
    )
  end

  defp migrate_history(context) do
    journal = prepare_history(context)
    assert {:ok, _result} = PersonalGraphMigration.apply(context.connection, journal, @quiescence)
    assert {:ok, manifest} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})
    graph = hd(manifest["graphs"])
    {graph["source_inventory"], graph["target_inventory"]}
  end

  describe "when an application migrates quiescent historical private graphs > when a completed Reflection invocation is replayed" do
    test "then public Reflection delivery returns the original immutable artefact", context do
      replay_migrated_artefact(context, "complete")
    end
  end

  describe "when an application migrates quiescent historical private graphs > when an incomplete Reflection invocation resumes" do
    test "then public Reflection delivery completes under its original artefact identity",
         context do
      replay_migrated_artefact(context, "incomplete")
    end
  end

  defp replay_migrated_artefact(context, state) do
    seed_history(context.database, "owner")
    invocation_id = "historical-" <> state

    artefact =
      Gralkor.Artefact.new(Gralkor.Artefact.id_for("owner", invocation_id, "review"), %{
        "summary" => "immutable amber"
      })

    Pythonx.eval(
      """
      graph = database.select_graph('g_' + b'operator/owner'.hex())
      graph.query('MATCH (item) WHERE item.uuid = $previous SET item.uuid = $uuid, item.content = $content, item.source_description = $description', {'previous': previous.decode(), 'uuid': uuid.decode(), 'content': content.decode(), 'description': 'reflection:review'})
      """,
      %{
        "database" => context.database,
        "previous" => state,
        "uuid" => artefact.id,
        "content" => Jason.encode!(Map.from_struct(artefact))
      }
    )

    journal = Path.join(context.directory, "#{System.unique_integer([:positive])}.json")
    assert {:ok, _} = PersonalGraphMigration.prepare(context.connection, ["owner"], %{}, journal)
    assert {:ok, _} = PersonalGraphMigration.apply(context.connection, journal, @quiescence)
    start_public_runtime(context)
    parent = self()

    assert {:ok, ^invocation_id} =
             Gralkor.Client.reflect(
               self(),
               "review",
               %{
                 id: invocation_id,
                 operator_id: "owner",
                 representations: [],
                 invocation_context: %{}
               },
               &send(parent, {:migration_delivery, &1}),
               inference: fn _ -> {:ok, artefact.payload} end
             )

    assert_receive {:migration_delivery, %{outcome: :delivered, artefact: ^artefact}}, 30_000

    assert {:ok, [%{destination: "personal", artefact: ^artefact}]} =
             Gralkor.Client.search(self(), %Gralkor.Search{
               operator_id: "owner",
               query: "amber",
               destinations: ["personal"],
               result_type: :artefacts,
               artefact_id: artefact.id
             })

    assert {:ok, manifest} = PersonalGraphMigration.plan(context.connection, ["owner"], %{})
    target = hd(manifest["graphs"])["target_inventory"]
    assert episode(target, artefact.id)["_gralkor_extraction_complete"] == true

    assert Enum.count(
             target["nodes"],
             &(Enum.member?(&1["labels"], "Episodic") and &1["properties"]["uuid"] == artefact.id)
           ) == 1
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

  defp prepare_history(context, references \\ %{}) do
    seed_history(context.database, "owner")
    journal = Path.join(context.directory, "#{System.unique_integer([:positive])}.json")

    assert {:ok, _manifest} =
             PersonalGraphMigration.prepare(context.connection, ["owner"], references, journal)

    journal
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
               (finished_claim:_GralkorEpisodeClaim {uuid: 'complete', group_id: $gid, generation: 7, _gralkor_fenced_generation: 7}),
               (unfinished_claim:_GralkorEpisodeClaim {uuid: 'incomplete', group_id: $gid, generation: 3, _gralkor_fenced_generation: 2, owner: 'stopped-worker', lease_until_ms: 1}),
               (a)-[fact:RELATES_TO {uuid: 'fact', group_id: $gid, name: 'GROWS', fact: 'amber grows in orchard', episodes: ['episode'], created_at: '2026-01-01T00:00:00Z', valid_at: '2026-01-01T00:00:00Z'}]->(b),
               (episode)-[:MENTIONS {uuid: 'mention', group_id: $gid}]->(a),
               (community)-[:HAS_MEMBER {uuid: 'membership', group_id: $gid}]->(a)
        SET a.name_embedding = vecf32([0.1, 0.2, 0.3]), fact.fact_embedding = vecf32([0.3, 0.2, 0.1]), finished_claim.content = complete.content, finished_claim.source = complete.source, finished_claim.source_description = complete.source_description, unfinished_claim.content = incomplete.content, unfinished_claim.source = incomplete.source, unfinished_claim.source_description = incomplete.source_description
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
