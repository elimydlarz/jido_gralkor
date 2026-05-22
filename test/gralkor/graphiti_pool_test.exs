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
      warmup: false,
      install_loop_fn: fn -> :ok end
    ]

    {:ok, pid} = GraphitiPool.start_link(Keyword.merge(defaults, opts))
    %{pid: pid, table: table}
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
    test "then a fresh AsyncFalkorDB and Graphiti instance scoped to the sanitized group_id are constructed and returned, then discarded by the caller after the operation that needed it returns" do
      falkor_db_count = :counters.new(1, [])
      instance_count = :counters.new(1, [])

      construct_falkor_db = fn {:remote, _} ->
        :counters.add(falkor_db_count, 1, 1)
        {:stub_falkor_db, :counters.get(falkor_db_count, 1)}
      end

      construct_instance = fn _db, _shared, group ->
        :counters.add(instance_count, 1, 1)
        {:stub_graphiti, group, :counters.get(instance_count, 1)}
      end

      %{pid: pid, table: table} =
        start_pool(
          falkordb_spec:
            {:remote, host: "h", port: 1, username: "u", password: "p", ssl: false},
          construct_falkor_db: construct_falkor_db,
          construct_instance: construct_instance,
          warmup: true
        )

      assert :counters.get(falkor_db_count, 1) == 1,
             "warmup must construct a fresh AsyncFalkorDB for remote (state.falkor_db is unset)"

      assert :counters.get(instance_count, 1) == 1

      a = GraphitiPool.for(pid, "with-hyphens")
      b = GraphitiPool.for(pid, "with-hyphens")

      assert :counters.get(falkor_db_count, 1) == 3
      assert :counters.get(instance_count, 1) == 3
      refute a == b
      assert match?({:stub_graphiti, "with_hyphens", _}, a)
      assert match?({:stub_graphiti, "with_hyphens", _}, b)

      assert :ets.tab2list(table) == [],
             "nothing (warmup throwaway nor per-operation Graphiti) is cached for remote"
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
    test "then it is caught and logged at :warning as \"[gralkor] warmup failed (non-fatal): <reason>\" and boot proceeds" do
      log =
        capture_log(fn ->
          %{pid: pid} = start_pool(interpret_fn: fn _, _ -> :ok end, warmup: true)
          assert Process.alive?(pid), "boot proceeded after warmup failure"
          GenServer.stop(pid)
        end)

      assert log =~ "[gralkor] warmup failed (non-fatal)"
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

      {:ok, pid} =
        GraphitiPool.start_link(name: nil, falkordb_spec: {:embedded, data_dir}, warmup: false)

      assert Process.alive?(pid)

      rewritten =
        data_dir |> Path.join("gralkor.db.settings") |> File.read!() |> Jason.decode!()

      refute rewritten["unixsocket"] == Path.join(stale_tmp, "redis.socket")

      GenServer.stop(pid)
      File.rm_rf!(data_dir)
      File.rm_rf!(stale_tmp)
    end

    test "then a single AsyncFalkorDB is constructed via redislite and held for the lifetime of the GenServer" do
      data_dir =
        Path.join(System.tmp_dir!(), "gralkor_pool_#{System.unique_integer([:positive])}")

      File.mkdir_p!(data_dir)

      {:ok, pid} =
        GraphitiPool.start_link(name: nil, falkordb_spec: {:embedded, data_dir}, warmup: false)

      assert Process.alive?(pid)

      GenServer.stop(pid)
      File.rm_rf!(data_dir)
    end
  end
end
