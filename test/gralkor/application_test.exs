defmodule Gralkor.ApplicationTest do
  use ExUnit.Case, async: false

  alias Gralkor.Application, as: App
  alias Gralkor.Client

  setup do
    original_env = System.get_env("GRALKOR_DATA_DIR")
    original_client = Application.get_env(:jido_gralkor, :client)
    original_falkordb = Application.get_env(:jido_gralkor, :falkordb)

    on_exit(fn ->
      case original_env do
        nil -> System.delete_env("GRALKOR_DATA_DIR")
        v -> System.put_env("GRALKOR_DATA_DIR", v)
      end

      case original_client do
        nil -> Application.delete_env(:jido_gralkor, :client)
        v -> Application.put_env(:jido_gralkor, :client, v)
      end

      case original_falkordb do
        nil -> Application.delete_env(:jido_gralkor, :falkordb)
        v -> Application.put_env(:jido_gralkor, :falkordb, v)
      end
    end)

    Application.delete_env(:jido_gralkor, :client)
    Application.delete_env(:jido_gralkor, :falkordb)

    test_pid = self()

    recording_add = fn group, body, source, ontology, _opts ->
      send(test_pid, {:add, group, body, source, ontology})
      :ok
    end

    turn = [
      Gralkor.Message.new("user", "Q"),
      Gralkor.Message.new("behaviour", "thinking"),
      Gralkor.Message.new("assistant", "A")
    ]

    %{recording_add: recording_add, turn: turn}
  end

  describe "when the application starts > while neither a remote connection nor a data directory is configured" do
    test "then no children are supervised, because the consumer has not opted into the native runtime" do
      System.delete_env("GRALKOR_DATA_DIR")

      assert [] = App.children()
    end
  end

  describe "when the application starts > while a data directory is configured > and no remote connection is configured" do
    test "then the Python runtime, graph pool, Reflection supervisor, and capture buffer are supervised in that order" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())

      children = App.children()

      assert length(children) == 4

      [first, second, third, fourth] = children

      assert {Gralkor.Python, [reap_orphans: true]} = first
      assert {Gralkor.GraphitiPool, _} = second
      assert {Gralkor.Reflection.Supervisor, reflection_opts} = third
      assert {Gralkor.CaptureBuffer, _} = fourth
      scheduler_opts = Keyword.fetch!(reflection_opts, :scheduler_opts)
      assert Keyword.fetch!(scheduler_opts, :journal_path) =~ "reflection_scheduler.dets"
    end

    test "and startup returns only once all four have initialised, so a consumer needs no separate readiness gate" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())
      Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)

      assert [
               {Gralkor.Python, [reap_orphans: true]},
               {Gralkor.GraphitiPool, _},
               {Gralkor.Reflection.Supervisor, _},
               {Gralkor.CaptureBuffer, opts}
             ] = App.children()

      assert is_function(Keyword.fetch!(opts, :flush_callback), 5)
    end

    test "and the graph pool is constructed with the embedded connection" do
      data_dir =
        Path.join(
          System.tmp_dir!(),
          "ex_app_test_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
        )

      System.put_env("GRALKOR_DATA_DIR", data_dir)

      [_python, {Gralkor.GraphitiPool, opts}, _scheduler, _buffer] = App.children()

      assert Keyword.fetch!(opts, :falkordb_spec) == {:embedded, Path.expand(data_dir)}
    end

    test "and the Python runtime is told to sweep for orphaned embedded servers, this deployment spawning one of its own" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())

      assert [{Gralkor.Python, [reap_orphans: true]}, _, _, _] = App.children()
    end
  end

  describe "when the application starts > while a remote FalkorDB connection is configured" do
    test "then the Python runtime, graph pool, Reflection supervisor, and capture buffer are supervised in that order" do
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)

      children = App.children()

      assert Enum.map(children, fn {module, _opts} -> module end) == [
               Gralkor.Python,
               Gralkor.GraphitiPool,
               Gralkor.Reflection.Supervisor,
               Gralkor.CaptureBuffer
             ]
    end

    test "and the graph pool is constructed with the remote connection, so no embedded server is spawned" do
      Application.put_env(:jido_gralkor, :falkordb,
        host: "falkor.example",
        port: 6379,
        username: "alice",
        password: "secret"
      )

      [_python, {Gralkor.GraphitiPool, opts}, _scheduler, _buffer] = App.children()

      assert Keyword.fetch!(opts, :falkordb_spec) ==
               {:remote,
                [host: "falkor.example", port: 6379, username: "alice", password: "secret"]}
    end

    test "and the Python runtime is told not to sweep for orphaned embedded servers, this deployment never having spawned one" do
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)

      assert [{Gralkor.Python, [reap_orphans: false]}, _, _, _] = App.children()
    end

    test "and a configured data directory is ignored" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)

      [{Gralkor.Python, [reap_orphans: false]}, {Gralkor.GraphitiPool, opts}, _, _] =
        App.children()

      assert {:remote, _} = Keyword.fetch!(opts, :falkordb_spec)
    end
  end

  describe "if the remote FalkorDB configuration is not a keyword list carrying a host and a port" do
    test "then startup raises before any child starts" do
      Application.put_env(:jido_gralkor, :falkordb, port: 6379)
      assert_raise ArgumentError, ~r/:host/, fn -> App.children() end

      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example")
      assert_raise ArgumentError, ~r/:port/, fn -> App.children() end

      Application.put_env(:jido_gralkor, :falkordb, "falkor://host:6379")
      assert_raise ArgumentError, ~r/keyword list/, fn -> App.children() end
    end
  end

  describe "when a Lens capture flush runs" do
    test "then the selected turns are rendered in the order they were appended" do
      test_pid = self()

      ingest = fn request ->
        send(test_pid, {:ingested, request})
        :ok
      end

      callback = App.build_lens_flush_callback(ingest_fn: ingest)

      turns = [
        [Gralkor.Message.new("user", "Remember this")],
        [Gralkor.Message.new("assistant", "I will")]
      ]

      assert :ok =
               callback.(
                 "operator-one",
                 "Susu",
                 "Eli",
                 "observations",
                 turns,
                 "ingestion-one"
               )

      assert_receive {:ingested,
                      %Gralkor.Ingest{
                        id: "ingestion-one",
                        operator_id: "operator-one",
                        lens: "observations",
                        content: "Eli: Remember this\nSusu: I will",
                        source_description: "captured"
                      }}
    end

    test "and the rendered transcript is submitted through the selected Lens as a captured episode" do
      test_pid = self()

      callback =
        App.build_lens_flush_callback(
          ingest_fn: fn request ->
            send(test_pid, {:ingested, request})
            :ok
          end
        )

      turns = [
        [Gralkor.Message.new("user", "Remember this")],
        [Gralkor.Message.new("assistant", "I will")]
      ]

      assert :ok =
               callback.(
                 "operator-one",
                 "Susu",
                 "Eli",
                 "observations",
                 turns,
                 "ingestion-one"
               )

      assert_receive {:ingested,
                      %Gralkor.Ingest{
                        id: "ingestion-one",
                        operator_id: "operator-one",
                        lens: "observations",
                        content: "Eli: Remember this\nSusu: I will",
                        source_description: "captured"
                      }}
    end
  end

  describe "when the application starts > while the in-memory client is configured" do
    test "then no children are supervised regardless of configured local or remote storage" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)
      Application.put_env(:jido_gralkor, :client, Gralkor.Client.InMemory)

      assert [] = App.children()
    end
  end

  describe "when a legacy or Lens capture flush renders an empty transcript" do
    @tag :capture_log
    test "then no legacy episode write or Lens ingestion is submitted" do
      add_episode_fn = fn _g, _b, _s, _o, _opts -> flunk("add_episode should not be called") end

      cb =
        App.build_flush_callback(nil,
          add_episode_fn: add_episode_fn
        )

      logs =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert :ok = cb.("g", "TestAgent", "Eli", nil, [])
        end)

      refute logs =~ "[gralkor] capture flushed"
      refute logs =~ "[gralkor] [test] capture flush body"

      lens_cb =
        App.build_lens_flush_callback(
          ingest_fn: fn _request -> flunk("Lens ingestion should not be called") end
        )

      assert :ok =
               lens_cb.(
                 "operator",
                 "TestAgent",
                 "Eli",
                 "observations",
                 [],
                 "ingestion"
               )
    end

    test "and the flush reports success" do
      cb =
        App.build_flush_callback(nil,
          add_episode_fn: fn _g, _b, _s, _o, _opts ->
            flunk("add_episode should not be called")
          end
        )

      assert :ok = cb.("g", "TestAgent", "Eli", nil, [])

      lens_cb =
        App.build_lens_flush_callback(
          ingest_fn: fn _request -> flunk("Lens ingestion should not be called") end
        )

      assert :ok =
               lens_cb.(
                 "operator",
                 "TestAgent",
                 "Eli",
                 "observations",
                 [],
                 "ingestion"
               )
    end
  end

  describe "when a capture flush runs" do
    test "then the transcript episode is rendered from the user and assistant text of every captured turn only, with no agent reasoning and no inference call",
         %{recording_add: add, turn: turn} do
      cb = App.build_flush_callback(nil, add_episode_fn: add)

      assert :ok = cb.("g1", "Susu", "Eli", nil, [turn])
      assert_receive {:add, "g1", body, "captured", nil}
      assert body =~ "Eli: Q"
      assert body =~ "Susu: A"
      refute body =~ "thinking"
    end

    test "and the rendered transcript is written as a captured episode", %{
      recording_add: add,
      turn: turn
    } do
      cb = App.build_flush_callback(nil, add_episode_fn: add)

      assert :ok = cb.("g1", "Susu", "Eli", :ont, [turn])
      assert_receive {:add, "g1", "Eli: Q\nSusu: A", "captured", :ont}
    end

    test "and the trusted originating Lens is recorded as `operator`", %{turn: turn} do
      test_pid = self()

      cb =
        App.build_flush_callback(nil,
          add_episode_fn: fn _group, _body, _source, _ontology, opts ->
            send(test_pid, {:capture_opts, opts})
            :ok
          end
        )

      assert :ok = cb.("g1", "Susu", "Eli", nil, [turn])
      assert_receive {:capture_opts, opts}
      assert opts[:lens] == "operator"
    end
  end

  describe "when a capture flush writes its captured episode successfully" do
    @tag :capture_log
    test "then a single line reporting the group, the transcript size, and the duration is logged" do
      add_episode_fn = fn _g, _b, _s, _o, _opts -> :ok end

      cb =
        App.build_flush_callback(nil,
          add_episode_fn: add_episode_fn
        )

      turns = [[Gralkor.Message.new("user", "hi"), Gralkor.Message.new("assistant", "hello")]]

      logs =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert :ok = cb.("g1", "TestAgent", "Eli", nil, turns)
        end)

      assert logs =~ "[gralkor] capture flushed"
      assert logs =~ "group:g1"
      assert logs =~ ~r/bodyChars:\d+/
      assert logs =~ ~r/\d+ms/
    end

    @tag :capture_log
    test "and the flush reports success" do
      cb = App.build_flush_callback(nil, add_episode_fn: fn _g, _b, _s, _o, _opts -> :ok end)
      turns = [[Gralkor.Message.new("user", "hi")]]

      logs =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert :ok = cb.("g1", "TestAgent", "Eli", nil, turns)
        end)

      assert logs =~ "[gralkor] capture flushed"
      assert logs =~ "group:g1"
      refute logs =~ "capture flush failed"
    end
  end

  describe "when a capture flush writes its captured episode successfully > where test mode is enabled" do
    setup do
      Application.put_env(:jido_gralkor, :test, true)
      on_exit(fn -> Application.delete_env(:jido_gralkor, :test) end)
      :ok
    end

    @tag :capture_log
    test "then the rendered transcript itself is logged, so what actually landed in memory is readable from the logs" do
      add_episode_fn = fn _g, _b, _s, _o, _opts -> :ok end

      cb =
        App.build_flush_callback(nil,
          add_episode_fn: add_episode_fn
        )

      turns = [[Gralkor.Message.new("user", "hi"), Gralkor.Message.new("assistant", "hello")]]

      logs =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = cb.("g1", "TestAgent", "Eli", nil, turns)
        end)

      assert logs =~ "[gralkor] [test] capture flush body:"
      assert logs =~ "Eli: hi"

      Application.delete_env(:jido_gralkor, :test)

      cb =
        App.build_flush_callback(nil,
          add_episode_fn: fn _g, _b, _s, _o, _opts -> :ok end
        )

      disabled_turns = [[Gralkor.Message.new("user", "hi")]]

      disabled_logs =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = cb.("g1", "TestAgent", "Eli", nil, disabled_turns)
        end)

      refute disabled_logs =~ "[gralkor] [test]"
    end
  end

  describe "if writing the captured episode fails" do
    @tag :capture_log
    test "then no success line is logged, so a failed attempt is never recorded as a success" do
      cb =
        App.build_flush_callback(nil,
          add_episode_fn: fn _g, _b, _s, _o, _opts ->
            {:error, {:python, "ConnectionError: reset by peer"}}
          end
        )

      turns = [[Gralkor.Message.new("user", "hi")]]

      logs =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert {:error, {:python, "ConnectionError: reset by peer"}} =
                   cb.("g1", "TestAgent", "Eli", nil, turns)
        end)

      refute logs =~ "[gralkor] capture flushed"
      assert logs =~ "[gralkor] capture flush failed"
      assert logs =~ "group:g1"
      assert logs =~ "retrying"
    end

    @tag :capture_log
    test "and a concise warning naming the group and the reason is logged" do
      cb =
        App.build_flush_callback(nil,
          add_episode_fn: fn _g, _b, _s, _o, _opts -> {:error, :disk_full} end
        )

      turns = [[Gralkor.Message.new("user", "hi")]]

      logs =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          assert {:error, :disk_full} = cb.("g1", "TestAgent", "Eli", nil, turns)
        end)

      flush_line =
        logs
        |> String.split("\n")
        |> Enum.find("", &String.contains?(&1, "capture flush failed"))

      assert flush_line =~ "disk_full"
      assert flush_line =~ "group:g1"
    end

    @tag :capture_log
    test "and the failure is returned unchanged, so the capture buffer owns retry and backoff" do
      cb =
        App.build_flush_callback(nil,
          add_episode_fn: fn _g, _b, _s, _o, _opts ->
            {:error, {:python, "ConnectionError: reset by peer"}}
          end
        )

      turns = [[Gralkor.Message.new("user", "hi")]]

      assert {:error, {:python, "ConnectionError: reset by peer"}} =
               cb.("g1", "TestAgent", "Eli", nil, turns)
    end
  end

  describe "when a capture flush is retried after its captured episode has already been written" do
    test "then that captured episode is written a second time, because episode writes are not idempotent",
         %{
           recording_add: add,
           turn: turn
         } do
      cb = App.build_flush_callback(nil, add_episode_fn: add)

      assert :ok = cb.("g1", "Susu", "Eli", nil, [turn])
      assert :ok = cb.("g1", "Susu", "Eli", nil, [turn])

      assert_receive {:add, "g1", body, "captured", nil}
      assert_receive {:add, "g1", ^body, "captured", nil}
    end
  end

  # The production path (start/2) builds the flush callback with NO add_episode_fn
  # dep, so it falls back to the default. Every other build_flush_callback test
  # injects a stub add_episode_fn and never exercises that default — which is
  # exactly where a dispatch bug hides: GraphitiPool.add_episode carries defaults
  # on server (1st) and opts (6th), so a 5-arity capture bound the wrong params and
  # raised FunctionClauseError on every real capture, exhausting CaptureBuffer and
  # writing nothing. This wires the real GraphitiPool (fake graphiti recording the
  # add_episode call) and drives the DEFAULT-wired callback end-to-end.
  describe "when a capture flush runs > while no episode-writing dependency is supplied" do
    @describetag :integration

    setup do
      {g, _} =
        Pythonx.eval(
          """
          import asyncio

          class _FakeGraphiti:
              def __init__(self):
                  self.recorded = {}

              async def build_indices_and_constraints(self):
                  return None

              async def add_episode(self, **kwargs):
                  self.recorded['episode_body'] = kwargs.get('episode_body')
                  self.recorded['source_description'] = kwargs.get('source_description')
                  self.recorded['group_id'] = kwargs.get('group_id')
                  return None

          _FakeGraphiti()
          """,
          %{}
        )

      {:ok, pid} =
        Gralkor.GraphitiPool.start_link(
          name: Gralkor.GraphitiPool,
          table: :gralkor_graphiti_instances,
          falkordb_spec: {:embedded, "/tmp/never_used"},
          construct_falkor_db: fn _spec -> :stub_falkor_db end,
          construct_shared_clients: fn _llm, _embedder ->
            %{llm_client: nil, embedder: nil, cross_encoder: nil}
          end,
          construct_instance: fn _db, _shared, _group_id -> g end,
          warmup: false,
          install_loop_fn: &Gralkor.Python.install_async_runtime/0
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{g: g}
    end

    test "then default writes name the graph pool server explicitly and reach it without shifted arguments",
         %{g: g} do
      cb = App.build_flush_callback({:embedded, "/tmp/never_used"})

      turns = [
        [
          Gralkor.Message.new("user", "the backup keeps failing"),
          Gralkor.Message.new("assistant", "I moved the vacuum job to 04:00")
        ]
      ]

      assert :ok = cb.("flush_group", "Susu", "Eli", nil, turns)

      {rec, _} = Pythonx.eval("g.recorded", %{"g" => g})
      rec = Pythonx.decode(rec)
      assert rec["source_description"] == "captured [lens: operator]"
      assert rec["group_id"] == Client.sanitize_group_id("flush_group")
      assert rec["episode_body"] =~ "vacuum"
    end
  end
end
