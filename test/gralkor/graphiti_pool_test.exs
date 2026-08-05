defmodule Gralkor.GraphitiPoolTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gralkor.GraphitiPool

  defp start_pool(opts) do
    table = :"pool_table_#{System.unique_integer([:positive])}"

    defaults = [
      name: nil,
      table: table,
      falkordb_spec: {:embedded, "/tmp/never_used"},
      construct_falkor_db: fn _spec -> :stub_falkor_db end,
      construct_shared_clients: fn _llm, _embedder ->
        %{llm_client: nil, embedder: nil, cross_encoder: nil}
      end,
      construct_instance: fn _db, _shared, group_id -> {:stub_graphiti, group_id} end,
      initialise_instance: fn _instance -> :ok end,
      warmup: false,
      install_loop_fn: fn -> :ok end
    ]

    {:ok, pid} = GraphitiPool.start_link(Keyword.merge(defaults, opts))
    %{pid: pid, table: table}
  end

  defp start_embedded_pool(data_dir, opts \\ []) do
    defaults = [
      name: nil,
      falkordb_spec: {:embedded, data_dir},
      warmup: false,
      construct_falkor_db: fn _spec -> :stub_falkor_db end,
      construct_shared_clients: fn _llm, _embedder ->
        %{llm_client: nil, embedder: nil, cross_encoder: nil}
      end,
      initialise_instance: fn _instance -> :ok end
    ]

    GraphitiPool.start_link(Keyword.merge(defaults, opts))
  end

  describe "add_episode/5, when graphiti's add_episode raises" do
    test "then {:error, {:python, reason}} is returned with reason summarised to the Python error's class and message — not the full multi-line traceback" do
      err = %Pythonx.Error{
        type: nil,
        value: nil,
        traceback: nil,
        lines: [
          "Traceback (most recent call last):\n",
          "  File \"/app/graphiti_core/graphiti.py\", line 412, in add_episode\n    await self.driver.execute_query(query, embedding=[0.123, 0.456, 0.789, 0.012])\n",
          "  File \"/app/redis/asyncio/connection.py\", line 88, in connect\n    raise ConnectionError(msg)\n",
          "redis.exceptions.ConnectionError: Error 104 connecting to falkor.cloud:6379. Connection reset by peer.\n"
        ]
      }

      reason = GraphitiPool.summarise_python_error(err)

      assert reason ==
               "redis.exceptions.ConnectionError: Error 104 connecting to falkor.cloud:6379. Connection reset by peer."

      refute reason =~ "Traceback"
      refute reason =~ "embedding="
      refute reason =~ "\n"
    end

    test "then {:error, {:python, reason}} is the shape returned by the rescue clause" do
      err = %Pythonx.Error{
        type: nil,
        value: nil,
        traceback: nil,
        lines: [
          "Traceback (most recent call last):\n",
          "  File \"x.py\", line 1, in <module>\n",
          "ValueError: bad thing happened\n"
        ]
      }

      reason = GraphitiPool.summarise_python_error(err)
      assert {:error, {:python, ^reason}} = {:error, {:python, reason}}
      assert reason == "ValueError: bad thing happened"
    end

    test "when Pythonx supplies no error lines then the reason falls back to \"Python exception raised (no detail available)\" without crashing" do
      err = %Pythonx.Error{type: nil, value: nil, traceback: nil, lines: []}

      reason = GraphitiPool.summarise_python_error(err)
      assert reason == "Python exception raised (no detail available)"
    end
  end

  describe "remove_episode/3, when graphiti's remove_episode raises" do
    test "then {:error, {:python, reason}} is returned with reason summarised to the Python error's class and message — not the full multi-line traceback" do
      err = %Pythonx.Error{
        type: nil,
        value: nil,
        traceback: nil,
        lines: [
          "Traceback (most recent call last):\n",
          "  File \"/app/graphiti_core/graphiti.py\", line 600, in remove_episode\n    await self.driver.execute_query(delete_query)\n",
          "RuntimeError: episode not found\n"
        ]
      }

      reason = GraphitiPool.summarise_python_error(err)

      assert reason == "RuntimeError: episode not found"
      refute reason =~ "Traceback"
      refute reason =~ "\n"
    end
  end

  describe "search/4 (edge search)" do
    test "then graphiti's g.search is invoked with num_results and the edges are returned as fact maps" do
      # A Pythonx-built fake graphiti whose search coroutine records its kwargs on the
      # instance, so they survive across Pythonx.eval scopes. The pool's construct_instance
      # returns it so GraphitiPool.search drives it.
      {g, _} =
        Pythonx.eval(
          """
          import asyncio

          class _Edge:
              def __init__(self, fact):
                  self.fact = fact
                  self.created_at = None
                  self.valid_at = None
                  self.invalid_at = None
                  self.expired_at = None

          class _FakeGraphiti:
              def __init__(self):
                  self.recorded = {}

              async def search(self, query, num_results=10):
                  self.recorded['query'] = query
                  self.recorded['num_results'] = num_results
                  return [_Edge("X is a thing")]

          _FakeGraphiti()
          """,
          %{}
        )

      construct_instance = fn _db, _shared, _group_id -> g end

      %{pid: pid} =
        start_pool(
          construct_instance: construct_instance,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert {:ok, [%{fact: "X is a thing"}]} =
               GraphitiPool.search(pid, "g1", "how do I deploy a service", 5)

      {rec, _} = Pythonx.eval("g.recorded", %{"g" => g})
      rec = Pythonx.decode(rec)
      assert rec["query"] == "how do I deploy a service"
      assert rec["num_results"] == 5

      GenServer.stop(pid)
    end
  end

  describe "search_nodes/5, when called with node_labels" do
    test "then graphiti's g.search_ is invoked (NODE search) with the node_labels SearchFilter, returning node name/summary/attributes" do
      {g, _} =
        Pythonx.eval(
          """
          import asyncio

          class _Node:
              def __init__(self, name, summary, attributes):
                  self.name = name
                  self.summary = summary
                  self.attributes = attributes

          class _Results:
              def __init__(self, nodes):
                  self.nodes = nodes

          class _FakeGraphiti:
              def __init__(self):
                  self.recorded = {}

              async def search_(self, query, config=None, group_ids=None, search_filter=None):
                  self.recorded['query'] = query
                  self.recorded['limit'] = config.limit if config is not None else None
                  self.recorded['node_labels'] = (
                      list(search_filter.node_labels)
                      if search_filter is not None and search_filter.node_labels
                      else None
                  )
                  return _Results([
                      _Node("resource contention", "rescheduled the vacuum job to 04:00",
                            {"lesson": "reschedule overlapping jobs", "success": True}),
                  ])

          _FakeGraphiti()
          """,
          %{}
        )

      construct_instance = fn _db, _shared, _group_id -> g end

      %{pid: pid} =
        start_pool(
          construct_instance: construct_instance,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert {:ok, [node]} =
               GraphitiPool.search_nodes(pid, "g1", "how do I resolve a scheduling conflict", 5,
                 node_labels: ["Learning"]
               )

      assert node.name == "resource contention"
      assert node.summary == "rescheduled the vacuum job to 04:00"
      assert node.attributes["lesson"] == "reschedule overlapping jobs"

      {rec, _} = Pythonx.eval("g.recorded", %{"g" => g})
      rec = Pythonx.decode(rec)
      assert rec["query"] == "how do I resolve a scheduling conflict"
      assert rec["limit"] == 5
      assert rec["node_labels"] == ["Learning"]

      GenServer.stop(pid)
    end

    test "then when no node_labels are given, g.search_ is invoked with an unfiltered SearchFilters" do
      {g, _} =
        Pythonx.eval(
          """
          class _Results:
              def __init__(self):
                  self.nodes = []

          class _FakeGraphiti:
              def __init__(self):
                  self.recorded = {}

              async def search_(self, query, config=None, group_ids=None, search_filter=None):
                  self.recorded['node_labels'] = (
                      list(search_filter.node_labels)
                      if search_filter is not None and search_filter.node_labels
                      else None
                  )
                  return _Results()

          _FakeGraphiti()
          """,
          %{}
        )

      construct_instance = fn _db, _shared, _group_id -> g end

      %{pid: pid} =
        start_pool(
          construct_instance: construct_instance,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert {:ok, []} = GraphitiPool.search_nodes(pid, "g1", "q", 5)

      {rec, _} = Pythonx.eval("g.recorded", %{"g" => g})
      assert (rec |> Pythonx.decode())["node_labels"] == nil

      GenServer.stop(pid)
    end
  end

  describe "for/1 (group_id), when called against an embedded spec" do
    test "then the Graphiti instance for the sanitized group_id is looked up from a shared ETS cache; on first use it is constructed and inserted, then lives for the lifetime of the GenServer" do
      counter = :counters.new(1, [])
      test_pid = self()

      construct_instance = fn _db, _shared, group ->
        :counters.add(counter, 1, 1)
        send(test_pid, {:constructed, group})
        {:stub_graphiti, group}
      end

      %{pid: pid, table: table} = start_pool(construct_instance: construct_instance)

      a1 = GraphitiPool.for(pid, "with-hyphens")
      assert_receive {:constructed, "with_hyphens"}
      assert :counters.get(counter, 1) == 1
      assert a1 == {:stub_graphiti, "with_hyphens"}

      assert [{"with_hyphens", {:stub_graphiti, "with_hyphens"}}] =
               :ets.lookup(table, "with_hyphens")

      a2 = GraphitiPool.for(pid, "with-hyphens")
      assert a2 == a1
      assert :counters.get(counter, 1) == 1

      b = GraphitiPool.for(pid, "another")
      assert_receive {:constructed, "another"}
      assert :counters.get(counter, 1) == 2
      refute b == a1

      assert Enum.sort(Enum.map(:ets.tab2list(table), fn {k, _} -> k end)) ==
               ["another", "with_hyphens"]
    end

    @tag timeout: 30_000
    test "then construction runs to completion even when it exceeds the GenServer.call default 5s timeout" do
      slow_construct = fn _db, _shared, group ->
        Process.sleep(5_500)
        {:stub_graphiti, group}
      end

      %{pid: pid} = start_pool(construct_instance: slow_construct)

      assert {:stub_graphiti, "slowgroup"} = GraphitiPool.for(pid, "slowgroup")
    end

    test "when a fresh per-group Graphiti instance is constructed then build_indices_and_constraints is invoked before the instance is cached and returned" do
      {instance, _} =
        Pythonx.eval(
          """
          class _FakeGraphiti:
              def __init__(self):
                  self.initialisation_count = 0

              async def build_indices_and_constraints(self):
                  self.initialisation_count += 1

          _FakeGraphiti()
          """,
          %{}
        )

      %{pid: pid, table: table} =
        start_pool(
          construct_instance: fn _db, _shared, _group -> instance end,
          initialise_instance: &GraphitiPool.initialise_instance/1,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      assert ^instance = GraphitiPool.for(pid, "indexed")
      assert [{"indexed", ^instance}] = :ets.lookup(table, "indexed")

      {count, _} = Pythonx.eval("g.initialisation_count", %{"g" => instance})
      assert Pythonx.decode(count) == 1

      assert ^instance = GraphitiPool.for(pid, "indexed")
      {count, _} = Pythonx.eval("g.initialisation_count", %{"g" => instance})
      assert Pythonx.decode(count) == 1
    end

    test "when a fresh per-group Graphiti instance is constructed if build_indices_and_constraints fails then the failure is non-fatal and the instance is still cached and returned" do
      {instance, _} =
        Pythonx.eval(
          """
          class _FailingGraphiti:
              async def build_indices_and_constraints(self):
                  raise RuntimeError("index setup unavailable")

          _FailingGraphiti()
          """,
          %{}
        )

      log =
        capture_log(fn ->
          %{pid: pid, table: table} =
            start_pool(
              construct_instance: fn _db, _shared, _group -> instance end,
              initialise_instance: &GraphitiPool.initialise_instance/1,
              install_loop_fn: &Gralkor.Python.install_async_runtime/0
            )

          assert ^instance = GraphitiPool.for(pid, "best-effort")
          assert [{"best_effort", ^instance}] = :ets.lookup(table, "best_effort")
          assert ^instance = GraphitiPool.for(pid, "best-effort")
        end)

      assert log =~ "build_indices_and_constraints failed (non-fatal)"
      assert log =~ "RuntimeError: index setup unavailable"
    end

    test "then concurrent callers proceed in parallel" do
      construct_instance = fn _db, _shared, group ->
        Process.sleep(100)
        {:stub_graphiti, group}
      end

      %{pid: pid} = start_pool(construct_instance: construct_instance)

      {us, results} =
        :timer.tc(fn ->
          1..4
          |> Task.async_stream(
            fn i -> GraphitiPool.for(pid, "g#{i}") end,
            max_concurrency: 4,
            ordered: false
          )
          |> Enum.map(fn {:ok, r} -> r end)
        end)

      ms = div(us, 1000)
      assert length(results) == 4

      {us_cached, _} =
        :timer.tc(fn ->
          1..100
          |> Task.async_stream(
            fn i -> GraphitiPool.for(pid, "g#{rem(i, 4) + 1}") end,
            max_concurrency: 100
          )
          |> Stream.run()
        end)

      assert div(us_cached, 1000) < 50,
             "100 concurrent cached reads should be near-instant (no GenServer hop), got #{div(us_cached, 1000)}ms (initial creation took #{ms}ms)"
    end
  end

  describe "for/1 (group_id), when called against a remote spec" do
    test "then the AsyncFalkorDB is built once at init and the per-group Graphiti instance is cached in shared ETS and reused — nothing is reconstructed per call, exactly as for embedded" do
      falkor_db_count = :counters.new(1, [])
      instance_count = :counters.new(1, [])

      construct_falkor_db = fn {:remote, _} ->
        :counters.add(falkor_db_count, 1, 1)
        {:stub_falkor_db, :counters.get(falkor_db_count, 1)}
      end

      construct_instance = fn db, _shared, group ->
        :counters.add(instance_count, 1, 1)
        {:stub_graphiti, group, db, :counters.get(instance_count, 1)}
      end

      %{pid: pid, table: table} =
        start_pool(
          falkordb_spec: {:remote, host: "h", port: 1, username: "u", password: "p", ssl: false},
          construct_falkor_db: construct_falkor_db,
          construct_instance: construct_instance,
          warmup: false
        )

      assert :counters.get(falkor_db_count, 1) == 1,
             "remote AsyncFalkorDB is constructed exactly once, at init"

      a = GraphitiPool.for(pid, "with-hyphens")
      assert :counters.get(instance_count, 1) == 1
      assert match?({:stub_graphiti, "with_hyphens", {:stub_falkor_db, 1}, _}, a)

      assert [{"with_hyphens", ^a}] = :ets.lookup(table, "with_hyphens")

      b = GraphitiPool.for(pid, "with-hyphens")
      assert b == a
      assert :counters.get(instance_count, 1) == 1
      assert :counters.get(falkor_db_count, 1) == 1

      c = GraphitiPool.for(pid, "another")
      assert :counters.get(instance_count, 1) == 2
      refute c == a
      assert :counters.get(falkor_db_count, 1) == 1

      assert Enum.sort(Enum.map(:ets.tab2list(table), fn {k, _} -> k end)) ==
               ["another", "with_hyphens"]
    end
  end

  describe "init/1 runs synchronously" do
    test "then `Gralkor.Python.install_async_runtime/0` is invoked so the pool can be booted standalone" do
      install_count = :counters.new(1, [])

      install_loop_fn = fn ->
        :counters.add(install_count, 1, 1)
        :ok
      end

      %{pid: pid} = start_pool(install_loop_fn: install_loop_fn)
      assert Process.alive?(pid)
      assert :counters.get(install_count, 1) == 1
    end

    test "then the graphiti-core LLM client, embedder, and cross-encoder are constructed once via Pythonx and shared across every Graphiti instance for the lifetime of the GenServer" do
      shared_count = :counters.new(1, [])
      instance_shareds = :ets.new(:shareds, [:public, :duplicate_bag])

      shared = %{llm_client: :the_llm, embedder: :the_embedder, cross_encoder: :the_xenc}

      construct_shared_clients = fn _llm, _embedder ->
        :counters.add(shared_count, 1, 1)
        shared
      end

      construct_instance = fn _db, received_shared, group ->
        :ets.insert(instance_shareds, {group, received_shared})
        {:stub_graphiti, group}
      end

      %{pid: pid} =
        start_pool(
          construct_shared_clients: construct_shared_clients,
          construct_instance: construct_instance
        )

      _ = GraphitiPool.for(pid, "g1")
      _ = GraphitiPool.for(pid, "g2")
      _ = GraphitiPool.for(pid, "g3")

      assert :counters.get(shared_count, 1) == 1

      shareds = instance_shareds |> :ets.tab2list() |> Enum.map(fn {_, s} -> s end)
      assert length(shareds) == 3
      assert Enum.uniq(shareds) == [shared]
    end

    test "while both configured model specs name a supported inference provider then client construction proceeds using the configured model ids" do
      test_pid = self()

      supported_pairs = [
        {%{provider: :google, id: "gemini-custom"},
         %{provider: :google, id: "gemini-embedding-custom"}},
        {%{provider: :openai, id: "gpt-4.1-mini"},
         %{provider: :openai, id: "text-embedding-3-small"}}
      ]

      Enum.each(supported_pairs, fn {llm_model, embedder_model} ->
        %{pid: pid} =
          start_pool(
            llm_model: llm_model,
            embedder_model: embedder_model,
            construct_shared_clients: fn received_llm, received_embedder ->
              send(test_pid, {:construct_shared, received_llm, received_embedder})
              %{llm_client: nil, embedder: nil, cross_encoder: nil}
            end
          )

        assert_receive {:construct_shared, ^llm_model, ^embedder_model}
        assert Process.alive?(pid)
      end)
    end

    test "while both configured model specs name a supported inference provider, while the two specs name different providers, then each client is still built for its own role's provider and startup completes" do
      test_pid = self()
      llm_model = %{provider: :openai, id: "gpt-4.1-mini"}
      embedder_model = %{provider: :google, id: "gemini-embedding-2-preview"}

      %{pid: pid} =
        start_pool(
          llm_model: llm_model,
          embedder_model: embedder_model,
          construct_shared_clients: fn received_llm, received_embedder ->
            send(test_pid, {:construct_shared, received_llm, received_embedder})
            %{llm_client: nil, embedder: nil, cross_encoder: nil}
          end
        )

      assert_receive {:construct_shared, ^llm_model, ^embedder_model}
      assert Process.alive?(pid)
    end

    test "then warmup runs: search is invoked once with a throwaway query and group_id, then Gralkor.Interpret.interpret_facts is invoked once" do
      interpret_count = :counters.new(1, [])

      interpret_fn = fn _text, _budget ->
        :counters.add(interpret_count, 1, 1)
        :ok
      end

      log =
        capture_log(fn ->
          %{pid: pid} = start_pool(interpret_fn: interpret_fn, warmup: true)
          assert Process.alive?(pid)
          GenServer.stop(pid)
        end)

      assert :counters.get(interpret_count, 1) == 1

      assert log =~ "[gralkor] warmup failed (non-fatal) — search",
             "search is invoked once (with stubs it fails the rescued Pythonx eval; the warning line proves the invocation)"
    end

    test "then logs \"[gralkor] warmup — search:… interpret:… <total>ms\" at :info" do
      log =
        capture_log(fn ->
          %{pid: pid} = start_pool(interpret_fn: fn _, _ -> :ok end, warmup: true)
          GenServer.stop(pid)
        end)

      assert log =~ ~r/\[gralkor\] warmup — search:\d+ interpret:\d+ \d+ms/
    end
  end

  describe "init/1 runs synchronously, if any warmup call raises or returns {:error, _}" do
    test "then it is caught and logged at :warning as \"[gralkor] warmup failed (non-fatal) — <stage>: <reason>\" and boot proceeds" do
      log =
        capture_log(fn ->
          %{pid: pid} = start_pool(interpret_fn: fn _, _ -> :ok end, warmup: true)
          assert Process.alive?(pid), "boot proceeded after warmup failure"
          GenServer.stop(pid)
        end)

      assert log =~ "[gralkor] warmup failed (non-fatal) — search:"
    end
  end

  describe "init/1 runs synchronously, when started with an embedded spec" do
    @describetag :integration

    test "then <data_dir>/gralkor.db.settings is removed if present, immediately before constructing AsyncFalkorDB" do
      data_dir =
        Path.join(System.tmp_dir!(), "gralkor_pool_#{System.unique_integer([:positive])}")

      File.mkdir_p!(data_dir)

      stale_tmp =
        Path.join(System.tmp_dir!(), "gralkor_stale_#{System.unique_integer([:positive])}")

      File.mkdir_p!(stale_tmp)
      File.write!(Path.join(stale_tmp, "redis.socket"), "")

      File.write!(
        Path.join(stale_tmp, "redis.pid"),
        Integer.to_string(System.pid() |> String.to_integer())
      )

      File.write!(
        Path.join(data_dir, "gralkor.db.settings"),
        Jason.encode!(%{
          "pidfile" => Path.join(stale_tmp, "redis.pid"),
          "unixsocket" => Path.join(stale_tmp, "redis.socket"),
          "dbdir" => data_dir,
          "dbfilename" => "gralkor.db"
        })
      )

      settings_path = Path.join(data_dir, "gralkor.db.settings")
      test_pid = self()

      construct_falkor_db = fn {:embedded, ^data_dir} ->
        send(test_pid, {:settings_present_at_construction, File.exists?(settings_path)})
        :stub_falkor_db
      end

      {:ok, pid} =
        start_embedded_pool(data_dir, construct_falkor_db: construct_falkor_db)

      assert Process.alive?(pid)
      assert_receive {:settings_present_at_construction, false}

      GenServer.stop(pid)
      File.rm_rf!(data_dir)
      File.rm_rf!(stale_tmp)
    end

    test "then the embedded FalkorDB construction boundary receives the data directory once and the resulting database is held for the lifetime of the GenServer" do
      data_dir =
        Path.join(System.tmp_dir!(), "gralkor_pool_#{System.unique_integer([:positive])}")

      File.mkdir_p!(data_dir)

      construction_count = :counters.new(1, [])
      instance_databases = :ets.new(:instance_databases, [:public, :duplicate_bag])

      construct_falkor_db = fn {:embedded, ^data_dir} ->
        :counters.add(construction_count, 1, 1)
        :embedded_database
      end

      construct_instance = fn database, _shared, group_id ->
        :ets.insert(instance_databases, {group_id, database})
        {:stub_graphiti, group_id}
      end

      {:ok, pid} =
        start_embedded_pool(data_dir,
          construct_falkor_db: construct_falkor_db,
          construct_instance: construct_instance
        )

      assert Process.alive?(pid)
      assert {:stub_graphiti, "one"} = GraphitiPool.for(pid, "one")
      assert {:stub_graphiti, "two"} = GraphitiPool.for(pid, "two")
      assert :counters.get(construction_count, 1) == 1

      assert Enum.sort(:ets.tab2list(instance_databases)) ==
               [{"one", :embedded_database}, {"two", :embedded_database}]

      GenServer.stop(pid)
      File.rm_rf!(data_dir)
    end
  end

  describe "ex-graphiti-pool > ontology materialisation > when an ontology module is materialised" do
    @describetag :integration

    defmodule StrictOntologyForGraphitiTest do
      use Gralkor.Ontology, entities: :strict, relationships: :scoped

      entity User do
        field(:handle, :string, required: true)
      end

      entity Preference do
        field(:description, :string, required: true)
      end

      from User do
        prefers Preference do
          field(:since, :string)
        end
      end
    end

    defmodule OpenOntologyForGraphitiTest do
      use Gralkor.Ontology, entities: :open, relationships: :open

      entity User do
        field(:handle, :string, required: true)
      end

      entity Preference do
        field(:description, :string, required: true)
      end

      from User do
        prefers(Preference)
      end
    end

    test "then the graphiti kwargs dict carries exactly the spec-selected keys (omitting unselected) and is reused per `{ontology module, merge_learning?}` cache key" do
      data_dir =
        Path.join(System.tmp_dir!(), "gralkor_pool_#{System.unique_integer([:positive])}")

      File.mkdir_p!(data_dir)

      {:ok, pid} = start_embedded_pool(data_dir)

      try do
        strict = GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest}, :infinity)

        strict_again =
          GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest}, :infinity)

        strict_merged =
          GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest, true}, :infinity)

        strict_merged_again =
          GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest, true}, :infinity)

        assert Enum.sort(Map.keys(strict)) ==
                 ["edge_type_map", "edge_types", "entity_types", "excluded_entity_types"]

        assert strict["excluded_entity_types"] == ["Entity"]

        assert strict === strict_again
        assert strict_merged === strict_merged_again
        refute strict === strict_merged
      after
        GenServer.stop(pid)
        File.rm_rf!(data_dir)
      end
    end

    test "and graphiti dictionaries use selected kwarg names outside and declared entity/edge type names inside" do
      data_dir =
        Path.join(System.tmp_dir!(), "gralkor_pool_#{System.unique_integer([:positive])}")

      File.mkdir_p!(data_dir)
      {:ok, pid} = start_embedded_pool(data_dir)

      try do
        strict = GenServer.call(pid, {:materialise, StrictOntologyForGraphitiTest}, :infinity)
        open = GenServer.call(pid, {:materialise, OpenOntologyForGraphitiTest}, :infinity)

        assert Enum.sort(Map.keys(strict)) ==
                 ["edge_type_map", "edge_types", "entity_types", "excluded_entity_types"]

        assert Enum.sort(Map.keys(open)) == ["edge_types", "entity_types"]

        {type_keys, _} =
          Pythonx.eval(
            "[sorted(entity_types.keys()), sorted(edge_types.keys())]",
            %{"entity_types" => strict["entity_types"], "edge_types" => strict["edge_types"]}
          )

        assert Pythonx.decode(type_keys) == [["Preference", "User"], ["PREFERS"]]
      after
        GenServer.stop(pid)
        File.rm_rf!(data_dir)
      end
    end

    test "then materialising with merge_learning_entity: true unions a Learning Pydantic class onto entity_types" do
      data_dir =
        Path.join(System.tmp_dir!(), "gralkor_pool_#{System.unique_integer([:positive])}")

      File.mkdir_p!(data_dir)

      {:ok, pid} = start_embedded_pool(data_dir)

      try do
        merged =
          GenServer.call(
            pid,
            {:materialise, StrictOntologyForGraphitiTest, true},
            :infinity
          )

        {names, _} =
          Pythonx.eval(
            "[cls.__name__ for cls in entity_types.values()]",
            %{"entity_types" => merged["entity_types"]}
          )

        names = names |> Pythonx.decode() |> Enum.sort()

        assert "Learning" in names
        assert "User" in names
        assert "Preference" in names
      after
        GenServer.stop(pid)
        File.rm_rf!(data_dir)
      end
    end

    test "then materialising nil with merge_learning_entity: true yields a dict carrying only the Learning entity type" do
      data_dir =
        Path.join(System.tmp_dir!(), "gralkor_pool_#{System.unique_integer([:positive])}")

      File.mkdir_p!(data_dir)

      {:ok, pid} = start_embedded_pool(data_dir)

      try do
        merged = GenServer.call(pid, {:materialise, nil, true}, :infinity)

        {names, _} =
          Pythonx.eval(
            "[cls.__name__ for cls in entity_types.values()]",
            %{"entity_types" => merged["entity_types"]}
          )

        assert names |> Pythonx.decode() |> List.to_string() == "Learning"

        refute Map.has_key?(merged, "edge_types")
        refute Map.has_key?(merged, "edge_type_map")
        refute Map.has_key?(merged, "excluded_entity_types")
      after
        GenServer.stop(pid)
        File.rm_rf!(data_dir)
      end
    end
  end
end
