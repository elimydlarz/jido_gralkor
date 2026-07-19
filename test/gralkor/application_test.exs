defmodule Gralkor.ApplicationTest do
  use ExUnit.Case, async: false

  require Logger

  alias Gralkor.Application, as: App

  setup do
    original_env = System.get_env("GRALKOR_DATA_DIR")
    original_client = Application.get_env(:jido_gralkor, :client)
    original_falkordb = Application.get_env(:jido_gralkor, :falkordb)
    original_gen_on_flush = Application.get_env(:jido_gralkor, :generalise_on_flush)

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

      case original_gen_on_flush do
        nil -> Application.delete_env(:jido_gralkor, :generalise_on_flush)
        v -> Application.put_env(:jido_gralkor, :generalise_on_flush, v)
      end
    end)

    Application.delete_env(:jido_gralkor, :client)
    Application.delete_env(:jido_gralkor, :falkordb)
    Application.delete_env(:jido_gralkor, :generalise_on_flush)
    :ok
  end

  describe "ex-application > start/2 child specs > when neither :falkordb nor GRALKOR_DATA_DIR is set" do
    test "the supervisor includes no children" do
      System.delete_env("GRALKOR_DATA_DIR")

      assert [] = App.children()
    end
  end

  describe "ex-application > start/2 child specs > when GRALKOR_DATA_DIR is set and :falkordb is unset (embedded)" do
    test "the supervisor includes Gralkor.Python, Gralkor.GraphitiPool, Gralkor.CaptureBuffer in order" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())

      children = App.children()

      assert length(children) == 3

      [first, second, third] = children

      assert {Gralkor.Python, [reap_orphans: true]} = first
      assert {Gralkor.GraphitiPool, _} = second
      assert {Gralkor.CaptureBuffer, _} = third
    end

    test "the same set is returned when client is explicitly Gralkor.Client.Native" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())
      Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)

      assert [
               {Gralkor.Python, [reap_orphans: true]},
               {Gralkor.GraphitiPool, _},
               {Gralkor.CaptureBuffer, _}
             ] = App.children()
    end

    test "GraphitiPool is configured with an :embedded falkordb_spec carrying the expanded data_dir" do
      data_dir = Path.join(System.tmp_dir!(), "ex_app_test_#{System.unique_integer([:positive])}")
      System.put_env("GRALKOR_DATA_DIR", data_dir)

      [_python, {Gralkor.GraphitiPool, opts}, _buffer] = App.children()

      assert Keyword.fetch!(opts, :falkordb_spec) == {:embedded, Path.expand(data_dir)}
    end

    test "CaptureBuffer is configured with a flush_callback function" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())

      [_python, _pool, {Gralkor.CaptureBuffer, opts}] = App.children()

      assert is_function(Keyword.fetch!(opts, :flush_callback), 5)
    end
  end

  describe "ex-application > start/2 child specs > when :falkordb is set (remote)" do
    test "the supervisor includes Gralkor.Python with reap_orphans: false, GraphitiPool with the remote spec, and CaptureBuffer" do
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)

      [
        {Gralkor.Python, [reap_orphans: false]},
        {Gralkor.GraphitiPool, opts},
        {Gralkor.CaptureBuffer, _}
      ] =
        App.children()

      assert Keyword.fetch!(opts, :falkordb_spec) ==
               {:remote, [host: "falkor.example", port: 6379]}
    end

    test "remote wins over GRALKOR_DATA_DIR when both are set" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)

      [{Gralkor.Python, [reap_orphans: false]}, {Gralkor.GraphitiPool, opts}, _] = App.children()

      assert {:remote, _} = Keyword.fetch!(opts, :falkordb_spec)
    end

    test "username and password are carried through to the remote spec" do
      Application.put_env(:jido_gralkor, :falkordb,
        host: "falkor.example",
        port: 6379,
        username: "alice",
        password: "secret"
      )

      [_python, {Gralkor.GraphitiPool, opts}, _] = App.children()

      {:remote, kw} = Keyword.fetch!(opts, :falkordb_spec)
      assert Keyword.fetch!(kw, :username) == "alice"
      assert Keyword.fetch!(kw, :password) == "secret"
    end

    test "raises ArgumentError when :falkordb is missing :host" do
      Application.put_env(:jido_gralkor, :falkordb, port: 6379)

      assert_raise ArgumentError, ~r/:host/, fn -> App.children() end
    end

    test "raises ArgumentError when :falkordb is missing :port" do
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example")

      assert_raise ArgumentError, ~r/:port/, fn -> App.children() end
    end

    test "raises ArgumentError when :falkordb is not a keyword list" do
      Application.put_env(:jido_gralkor, :falkordb, "falkor://host:6379")

      assert_raise ArgumentError, ~r/keyword list/, fn -> App.children() end
    end
  end

  describe "ex-application > build_lens_flush_callback/1" do
    test "renders the selected turns and submits the transcript through the selected Lens" do
      test_pid = self()
      ingest = fn request -> send(test_pid, {:ingested, request}); :ok end
      callback = App.build_lens_flush_callback(ingest_fn: ingest)

      turns = [
        [Gralkor.Message.new("user", "Remember this")],
        [Gralkor.Message.new("assistant", "I will")]
      ]

      assert :ok =
               callback.("operator-one", "Susu", "Eli", "observations", turns)

      assert_receive {:ingested,
                      %Gralkor.Ingest{
                        operator_id: "operator-one",
                        lens: "observations",
                        content: "Eli: Remember this\nSusu: I will",
                        source_description: "captured"
                      }}
    end
  end

  describe "ex-application > start/2 child specs > when `:jido_gralkor, :client` is configured to Gralkor.Client.InMemory" do
    test "the supervisor includes no children regardless of GRALKOR_DATA_DIR or :falkordb" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)
      Application.put_env(:jido_gralkor, :client, Gralkor.Client.InMemory)

      assert [] = App.children()
    end
  end

  describe "ex-capture > flush > when the transcript episode body is empty" do
    @tag :capture_log
    test "no episode is added and nothing is logged" do
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
    end
  end

  describe "ex-capture > flush > when the episode is added" do
    @tag :capture_log
    test "logs the group, body size, and how long the add took" do
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
  end

  describe "ex-capture > flush > when test mode is enabled" do
    setup do
      Application.put_env(:jido_gralkor, :test, true)
      on_exit(fn -> Application.delete_env(:jido_gralkor, :test) end)
      :ok
    end

    @tag :capture_log
    test "also logs the captured transcript body" do
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
    end
  end

  describe "ex-capture > flush > when test mode is disabled" do
    @tag :capture_log
    test "does not log the captured transcript body" do
      cb =
        App.build_flush_callback(nil,
          add_episode_fn: fn _g, _b, _s, _o, _opts -> :ok end
        )

      turns = [[Gralkor.Message.new("user", "hi")]]

      logs =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = cb.("g1", "TestAgent", "Eli", nil, turns)
        end)

      refute logs =~ "[gralkor] [test]"
    end
  end

  describe "ex-application > build_flush_callback/2 > when add_episode_fn returns :ok" do
    @tag :capture_log
    test "logs '[gralkor] capture flushed' at :info and returns :ok" do
      cb =
        App.build_flush_callback(nil,
          add_episode_fn: fn _g, _b, _s, _o, _opts -> :ok end
        )

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

  describe "ex-application > build_flush_callback/2 > when add_episode_fn returns {:error, reason}" do
    @tag :capture_log
    test "does not log 'capture flushed', logs a concise warning, and returns the error unchanged" do
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
    test "the warning is concise — it does not embed a multi-line traceback blob" do
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
    end
  end

  describe "ex-application > build_flush_callback > when generalise_fn is provided" do
    test "after add_episode_fn returns :ok, generalise_fn is called with (group_id, body)" do
      add_fn = fn _g, _b, _s, _o, _opts -> :ok end
      test_pid = self()

      cb =
        App.build_flush_callback(nil,
          add_episode_fn: add_fn,
          generalise_fn: fn group_id, body ->
            send(test_pid, {:generalise_called, group_id, body})
          end
        )

      turns = [[Gralkor.Message.new("user", "hi")]]

      assert :ok = cb.("g1", "TestAgent", "Eli", nil, turns)

      assert_receive {:generalise_called, "g1", body}, 500
      assert body =~ "Eli: hi"
    end

    test "when generalise_fn is nil (default), no generalise step runs" do
      add_fn = fn _g, _b, _s, _o, _opts -> :ok end

      cb =
        App.build_flush_callback(nil,
          add_episode_fn: add_fn
        )

      turns = [[Gralkor.Message.new("user", "hi")]]
      assert :ok = cb.("g1", "TestAgent", "Eli", nil, turns)
    end

    test "when add_episode_fn fails, generalise_fn is NOT called" do
      add_fn = fn _g, _b, _s, _o, _opts -> {:error, :disk_full} end
      test_pid = self()

      cb =
        App.build_flush_callback(nil,
          add_episode_fn: add_fn,
          generalise_fn: fn _group_id, _body ->
            send(test_pid, {:generalise_called})
          end
        )

      turns = [[Gralkor.Message.new("user", "hi")]]

      {:error, :disk_full} = cb.("g1", "TestAgent", "Eli", nil, turns)

      Process.sleep(50)
      refute_received {:generalise_called}
    end
  end

  describe "ex-application > build_flush_callback learning routing" do
    setup do
      test_pid = self()

      recording_add = fn group, body, source, ontology, _opts ->
        send(test_pid, {:add, group, body, source, ontology})
        :ok
      end

      learning = %Gralkor.AgentLearning{
        problem_kind: "deploy timeout",
        approach: "warm cache at boot",
        success: true,
        lesson: "cold caches fail the first health check"
      }

      turn = [
        Gralkor.Message.new("user", "Q"),
        Gralkor.Message.new("behaviour", "thinking"),
        Gralkor.Message.new("assistant", "A")
      ]

      %{recording_add: recording_add, learning: learning, turn: turn}
    end

    test "every turn is learned from — each becomes a separate 'learning' episode in the same group/ontology",
         %{recording_add: add, learning: learning, turn: turn} do
      turn2 = [Gralkor.Message.new("user", "Q2"), Gralkor.Message.new("assistant", "A2")]

      cb =
        App.build_flush_callback(nil,
          add_episode_fn: add,
          learn_fn: fn _turn, _agent, _user -> {:ok, learning} end
        )

      assert :ok = cb.("g1", "Susu", "Eli", :ont, [turn, turn2])

      assert_receive {:add, "g1", _transcript, "captured", :ont}
      assert_receive {:add, "g1", body1, "learning", :ont}
      assert_receive {:add, "g1", body2, "learning", :ont}
      assert body1 =~ "deploy timeout"
      assert body2 =~ "cold caches fail the first health check"
    end

    test "when the learning add_episode_fn returns {:error, reason}, the flush callback returns it (not swallowed)",
         %{learning: learning, turn: turn} do
      add = fn _g, _b, source, _o, _opts ->
        if source == "learning", do: {:error, :graph_down}, else: :ok
      end

      cb =
        App.build_flush_callback(nil,
          add_episode_fn: add,
          learn_fn: fn _t, _a, _u -> {:ok, learning} end
        )

      assert {:error, :graph_down} = cb.("g1", "Susu", "Eli", nil, [turn])
    end

    test "when learn_fn returns {:error, reason}, the flush callback returns it (not swallowed)",
         %{
           recording_add: add,
           turn: turn
         } do
      cb =
        App.build_flush_callback(nil,
          add_episode_fn: add,
          learn_fn: fn _t, _a, _u -> {:error, :upstream} end
        )

      assert {:error, :upstream} = cb.("g1", "Susu", "Eli", nil, [turn])
    end

    test "when learn_fn raises, the exception propagates (not swallowed)", %{
      recording_add: add,
      turn: turn
    } do
      cb =
        App.build_flush_callback(nil,
          add_episode_fn: add,
          learn_fn: fn _t, _a, _u -> raise "boom" end
        )

      assert_raise RuntimeError, "boom", fn -> cb.("g1", "Susu", "Eli", nil, [turn]) end
    end

    test "when learn_fn is nil (default), no learning episode is added", %{
      recording_add: add,
      turn: turn
    } do
      cb = App.build_flush_callback(nil, add_episode_fn: add)

      assert :ok = cb.("g1", "Susu", "Eli", nil, [turn])
      assert_receive {:add, "g1", _b, "captured", nil}
      refute_receive {:add, _, _, "learning", _}, 100
    end

    test "when the captured add fails, no learning episode is written (no double-write on retry)",
         %{
           learning: learning,
           turn: turn
         } do
      test_pid = self()

      add = fn group, body, source, ontology, _opts ->
        send(test_pid, {:add, group, body, source, ontology})
        if source == "captured", do: {:error, :disk_full}, else: :ok
      end

      cb =
        App.build_flush_callback(nil,
          add_episode_fn: add,
          learn_fn: fn _t, _a, _u -> {:ok, learning} end
        )

      assert {:error, :disk_full} = cb.("g1", "Susu", "Eli", nil, [turn])
      assert_receive {:add, "g1", _b, "captured", nil}
      refute_receive {:add, _, _, "learning", _}, 100
    end

    test "a turn whose transcript is empty still writes the learning", %{
      recording_add: add,
      learning: learning
    } do
      cb =
        App.build_flush_callback(nil,
          add_episode_fn: add,
          learn_fn: fn _t, _a, _u -> {:ok, learning} end
        )

      behaviour_only = [Gralkor.Message.new("behaviour", "just thinking")]

      assert :ok = cb.("g1", "Susu", "Eli", nil, [behaviour_only])
      refute_receive {:add, _, _, "captured", _}, 100
      assert_receive {:add, "g1", _b, "learning", _}
    end

    test "the learning write signals merge_learning_entity; the captured write does not",
         %{learning: learning, turn: turn} do
      cb =
        App.build_flush_callback(nil,
          add_episode_fn: fn group, body, source, ontology, opts ->
            send(self(), {:add, group, body, source, ontology, opts})
            :ok
          end,
          learn_fn: fn _t, _a, _u -> {:ok, learning} end
        )

      assert :ok = cb.("g1", "Susu", "Eli", :ont, [turn])

      assert_received {:add, "g1", _transcript, "captured", :ont, captured_opts}
      refute Keyword.get(captured_opts, :merge_learning_entity, false),
             "captured write must not merge Learning"

      assert_received {:add, "g1", _learning_body, "learning", :ont, learning_opts}
      assert Keyword.get(learning_opts, :merge_learning_entity) == true,
             "learning write signals merge_learning_entity: true"
    end

    test "the learning write signals merge_learning_entity even when no consumer ontology is configured",
         %{learning: learning, turn: turn} do
      cb =
        App.build_flush_callback(nil,
          add_episode_fn: fn group, body, source, ontology, opts ->
            send(self(), {:add, group, body, source, ontology, opts})
            :ok
          end,
          learn_fn: fn _t, _a, _u -> {:ok, learning} end
        )

      assert :ok = cb.("g1", "Susu", "Eli", nil, [turn])

      assert_received {:add, "g1", _transcript, "captured", nil, captured_opts}
      refute Keyword.get(captured_opts, :merge_learning_entity, false)

      assert_received {:add, "g1", _learning_body, "learning", nil, learning_opts}
      assert Keyword.get(learning_opts, :merge_learning_entity) == true
    end
  end

  describe "ex-application > generalise_fn_for_flush/0 > when :generalise_on_flush is true" do
    test "returns &Gralkor.Client.Native.generalise/2, so build_children wires it into the CaptureBuffer flush_callback" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())
      Application.put_env(:jido_gralkor, :generalise_on_flush, true)

      assert App.generalise_fn_for_flush() == (&Gralkor.Client.Native.generalise/2)

      [_python, _pool, {Gralkor.CaptureBuffer, opts}] = App.children()
      assert is_function(Keyword.fetch!(opts, :flush_callback), 5)
    end
  end

  describe "ex-application > generalise_fn_for_flush/0 > when :generalise_on_flush is false or unset (default)" do
    test "returns nil, so no generalise step runs on flush" do
      Application.delete_env(:jido_gralkor, :generalise_on_flush)
      assert App.generalise_fn_for_flush() == nil

      Application.put_env(:jido_gralkor, :generalise_on_flush, false)
      assert App.generalise_fn_for_flush() == nil
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
  describe "ex-application > build_flush_callback/2 > when no add_episode_fn dep is provided (integration)" do
    @describetag :integration

    setup do
      {g, _} =
        Pythonx.eval(
          """
          import asyncio

          class _FakeGraphiti:
              def __init__(self):
                  self.recorded = {}

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

    test "the default add_episode_fn reaches GraphitiPool.add_episode without raising", %{g: g} do
      cb = App.build_flush_callback({:embedded, "/tmp/never_used"})

      turns = [[Gralkor.Message.new("user", "the backup keeps failing"), Gralkor.Message.new("assistant", "I moved the vacuum job to 04:00")]]

      assert :ok = cb.("flush_group", "Susu", "Eli", nil, turns)

      {rec, _} = Pythonx.eval("g.recorded", %{"g" => g})
      rec = Pythonx.decode(rec)
      assert rec["source_description"] == "captured"
      assert rec["group_id"] == "flush_group"
      assert rec["episode_body"] =~ "vacuum"
    end
  end
end
