defmodule Gralkor.Client.NativeTest do
  use ExUnit.Case, async: false

  require Logger

  alias Gralkor.CaptureBuffer
  alias Gralkor.Client
  alias Gralkor.Client.Native
  alias Gralkor.Message

  defp start_capture_buffer(_ctx) do
    test_pid = self()

    callback = fn group, agent, user, ontology, turns ->
      send(test_pid, {:flushed, group, agent, user, ontology, turns})
      :ok
    end

    start_supervised!(
      {CaptureBuffer, flush_callback: callback, lens_flush_callback: callback, retries: []}
    )

    :ok
  end

  describe "ex-client-native > if capture is called with a blank string session_id" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/session_id/, fn ->
        Native.capture("", "g", "TestAgent", "Eli", [Message.new("user", "x")])
      end
    end
  end

  describe "ex-client-native > if capture is called with a nil session_id" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/session_id/, fn ->
        Native.capture(nil, "g", "TestAgent", "Eli", [Message.new("user", "x")])
      end
    end
  end

  describe "ex-client-native > if capture is called with a blank agent_name" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Native.capture("s1", "g", "", "Eli", [Message.new("user", "x")])
      end
    end
  end

  describe "ex-client-native > if capture is called with a nil agent_name" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Native.capture("s1", "g", nil, "Eli", [Message.new("user", "x")])
      end
    end
  end

  describe "ex-client-native > if capture is called with a blank user_name" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/user_name/, fn ->
        Native.capture("s1", "g", "TestAgent", "", [Message.new("user", "x")])
      end
    end
  end

  describe "ex-client-native > if capture is called with a nil user_name" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/user_name/, fn ->
        Native.capture("s1", "g", "TestAgent", nil, [Message.new("user", "x")])
      end
    end
  end

  describe "ex-client-native > interpret output budget > if :interpret_max_output_tokens is set to a non-positive or non-integer value" do
    setup do
      original = Application.get_env(:jido_gralkor, :interpret_max_output_tokens)

      on_exit(fn ->
        if original == nil do
          Application.delete_env(:jido_gralkor, :interpret_max_output_tokens)
        else
          Application.put_env(:jido_gralkor, :interpret_max_output_tokens, original)
        end
      end)

      :ok
    end

    test "raises ArgumentError on zero" do
      Application.put_env(:jido_gralkor, :interpret_max_output_tokens, 0)

      assert_raise ArgumentError, ~r/interpret_max_output_tokens/, fn ->
        Native.recall("g", "TestAgent", "s1", "q")
      end
    end

    test "raises ArgumentError on negative" do
      Application.put_env(:jido_gralkor, :interpret_max_output_tokens, -1)

      assert_raise ArgumentError, ~r/interpret_max_output_tokens/, fn ->
        Native.recall("g", "TestAgent", "s1", "q")
      end
    end

    test "raises ArgumentError on non-integer" do
      Application.put_env(:jido_gralkor, :interpret_max_output_tokens, "lots")

      assert_raise ArgumentError, ~r/interpret_max_output_tokens/, fn ->
        Native.recall("g", "TestAgent", "s1", "q")
      end
    end
  end

  describe "ex-client-native > if recall is called with a blank agent_name" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Native.recall("g", "", "s1", "q")
      end
    end
  end

  describe "ex-client-native > if recall is called with a nil agent_name" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Native.recall("g", nil, "s1", "q")
      end
    end
  end

  describe "ex-client-native > if flush is called with a blank string session_id" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/session_id/, fn ->
        Native.flush("")
      end
    end
  end

  describe "ex-client-native > if flush is called with a nil session_id" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/session_id/, fn ->
        Native.flush(nil)
      end
    end
  end

  describe "ex-client-native > if flush_and_await is called with a blank string session_id" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/session_id/, fn ->
        Native.flush_and_await("", 1_000)
      end
    end
  end

  describe "ex-client-native > if flush_and_await is called with a nil session_id" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/session_id/, fn ->
        Native.flush_and_await(nil, 1_000)
      end
    end
  end

  describe "ex-client-native > if flush_and_await is called with a non-positive timeout_ms" do
    test "raises ArgumentError when timeout_ms is zero" do
      assert_raise ArgumentError, ~r/timeout_ms/, fn ->
        Native.flush_and_await("s1", 0)
      end
    end

    test "raises ArgumentError when timeout_ms is negative" do
      assert_raise ArgumentError, ~r/timeout_ms/, fn ->
        Native.flush_and_await("s1", -1)
      end
    end

    test "raises ArgumentError when timeout_ms is missing" do
      assert_raise ArgumentError, ~r/timeout_ms/, fn ->
        Native.flush_and_await("s1", nil)
      end
    end
  end

  describe "ex-memory-add > ontology validation" do
    test "raises ArgumentError when ontology is a module that does not export __ontology__/0" do
      assert_raise ArgumentError, ~r/NotAnOntology/, fn ->
        Native.memory_add("g", "content", "manual", Gralkor.TestOntologies.NotAnOntology)
      end
    end

    test "raises ArgumentError when ontology is a non-module value" do
      assert_raise ArgumentError, ~r/not-a-module/, fn ->
        Native.memory_add("g", "content", "manual", "not-a-module")
      end
    end
  end

  describe "ex-memory-add > arity" do
    test "memory_add/3 is exported" do
      assert function_exported?(Native, :memory_add, 3)
    end

    test "memory_add/4 is exported" do
      assert function_exported?(Native, :memory_add, 4)
    end
  end

  describe "ex-memory-add > memory_add/3 delegates to memory_add/4 with Config.ontology/0" do
    setup do
      original = Application.get_env(:jido_gralkor, :ontology)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:jido_gralkor, :ontology)
          v -> Application.put_env(:jido_gralkor, :ontology, v)
        end
      end)
    end

    test "when :ontology is unset, memory_add/3 passes the ontology guard and reaches GraphitiPool" do
      Application.delete_env(:jido_gralkor, :ontology)

      # memory_add/3 delegates to /4 with Config.ontology() → nil.
      # raise_unless_ontology_or_nil! accepts nil, so we reach GraphitiPool.
      # The crash is about ETS (no OTP stack), NOT about ontology — that
      # proves the guard passed.
      assert_raise ArgumentError, ~r/ETS/, fn ->
        Native.memory_add("g", "content", "manual")
      end
    end
  end

  describe "ex-sanitize-group-id > when the id contains hyphens" do
    test "hyphens are replaced with underscores" do
      assert Client.sanitize_group_id("a-b-c") == "a_b_c"
    end
  end

  describe "ex-sanitize-group-id > when the id has consecutive hyphens" do
    test "each hyphen is replaced independently" do
      assert Client.sanitize_group_id("a--b") == "a__b"
    end
  end

  describe "ex-sanitize-group-id > when the id has no hyphens" do
    test "it is returned unchanged" do
      assert Client.sanitize_group_id("abc") == "abc"
    end
  end

  describe "ex-impl-resolver > when :jido_gralkor/:client is unset in app env" do
    test "Gralkor.Client.Native is returned" do
      original = Application.get_env(:jido_gralkor, :client)
      Application.delete_env(:jido_gralkor, :client)

      try do
        assert Client.impl() == Native
      after
        case original do
          nil -> Application.delete_env(:jido_gralkor, :client)
          v -> Application.put_env(:jido_gralkor, :client, v)
        end
      end
    end
  end

  describe "ex-capture > request shape > capture/5" do
    setup :start_capture_buffer

    test "invokes CaptureBuffer.append/6 with sanitized group_id, names, ontology, and messages" do
      msgs = [Message.new("user", "hi")]

      assert :ok = Native.capture("s1", "with-hyphens", "Susu", "Eli", msgs)
      assert [^msgs] = CaptureBuffer.turns_for("s1")

      :ok = CaptureBuffer.flush("s1")
      assert_receive {:flushed, "with_hyphens", "Susu", "Eli", nil, [^msgs]}
    end
  end

  describe "ex-capture > request shape > capture/6 with a Lens" do
    setup :start_capture_buffer

    test "invokes CaptureBuffer.append_lens/6 with the operator id, names, Lens, and messages" do
      msgs = [Message.new("user", "hi")]

      assert :ok =
               Native.capture(
                 "s1",
                 "operator-with-hyphens",
                 "Susu",
                 "Eli",
                 msgs,
                 "observations"
               )

      assert [^msgs] = CaptureBuffer.turns_for("s1")
      assert :ok = CaptureBuffer.flush_and_await("s1", 1_000)

      assert_receive {:flushed, "operator-with-hyphens", "Susu", "Eli", "observations", [^msgs]}
    end
  end

  describe "ex-capture > request shape > capture/7 with primary and additional Lenses" do
    setup :start_capture_buffer

    test "invokes CaptureBuffer.append_lenses/6 with the operator id, names, Lenses, and messages" do
      msgs = [Message.new("user", "hi")]

      assert :ok =
               Native.capture(
                 "s1",
                 "operator-with-hyphens",
                 "Susu",
                 "Eli",
                 msgs,
                 "observations",
                 ["generalisations"]
               )

      assert [^msgs] = CaptureBuffer.turns_for("s1")
      assert :ok = CaptureBuffer.flush_and_await("s1", 1_000)

      assert_receive {:flushed, "operator-with-hyphens", "Susu", "Eli", "observations", [^msgs]}

      assert_receive {:flushed, "operator-with-hyphens", "Susu", "Eli", "generalisations",
                      [^msgs]}
    end
  end

  describe "ex-capture > then returns :ok immediately (does not call distill synchronously)" do
    setup :start_capture_buffer

    test "returns :ok" do
      assert :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])
    end
  end

  describe "ex-flush > when called with a session_id with buffered turns" do
    setup :start_capture_buffer

    test "the buffered turns are scheduled for flush and :ok is returned" do
      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])

      assert :ok = Native.flush("s1")
      assert_receive {:flushed, "g", "Susu", "Eli", nil, _turns}
    end
  end

  describe "ex-flush > when called with a session_id with no buffered turns" do
    setup :start_capture_buffer

    test ":ok is returned and no work is scheduled" do
      assert :ok = Native.flush("nope")
      refute_receive {:flushed, _, _, _, _, _}, 100
    end
  end

  describe "ex-flush-and-await > when called with a session_id with buffered turns and a positive timeout_ms" do
    setup :start_capture_buffer

    test ":ok is returned when the flush completes within the timeout" do
      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])

      assert :ok = Native.flush_and_await("s1", 1_000)
      assert_receive {:flushed, "g", "Susu", "Eli", nil, _turns}
    end
  end

  describe "ex-flush-and-await > when called with a session_id with no buffered turns" do
    setup :start_capture_buffer

    test ":ok is returned" do
      assert :ok = Native.flush_and_await("nope", 1_000)
    end
  end

  # The adapter's search wiring is private, so the only way to exercise it is
  # through the public calls the plugin makes. A wrong call does not raise here —
  # Recall.await_aux swallows an auxiliary search's exit and logs it — so each
  # test below asserts both the absence of that log and what the graph was
  # actually asked for.
  describe "ex-client-native > when a recall runs through the adapter's own search wiring" do
    @describetag :integration

    setup do
      {g, _} =
        Pythonx.eval(
          """
          import asyncio

          class _Episode:
              def __init__(self, content):
                  self.content = content
                  self.source_description = "generalisation"

          class _Results:
              def __init__(self, episodes=None):
                  self.nodes = []
                  self.episodes = episodes or []

          class _FakeGraphiti:
              def __init__(self):
                  self.recorded = {}

              # the main recall search uses edge search
              async def search(self, query, num_results=10, search_filter=None):
                  return []

              # the generalisation and learning searches use NODE search, and
              # reading generalisations back uses EPISODE search — both arrive
              # here as g.search_, so every call is recorded by what it asked for
              async def search_(self, query, config=None, group_ids=None, search_filter=None):
                  if config is not None and config.episode_config is not None:
                      self.recorded.setdefault('episode_calls', []).append(
                          [m.value for m in config.episode_config.search_methods]
                      )
                      return _Results(episodes=[
                          _Episode('GEN|v1|{"id":"gen-1","level":0,"confidence":0.8,"generalises":[]}\\nEli prefers dark mode'),
                      ])

                  self.recorded.setdefault('node_label_calls', []).append(
                      list(search_filter.node_labels)
                      if search_filter is not None and search_filter.node_labels
                      else []
                  )
                  return _Results()

          _FakeGraphiti()
          """,
          %{}
        )

      {:ok, pid} =
        GraphitiPool.start_link(
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

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      %{pid: pid, g: g}
    end

    test "then the learning search reaches the graph as a node search restricted to the node label Learning",
         %{g: g} do
      import ExUnit.CaptureLog

      logs =
        capture_log(fn ->
          assert {:ok, _block} = Native.recall("g", "TestAgent", nil, "how do I schedule X")
        end)

      # The real learning_search_fn closure (Native.learning_search_fn/0) called
      # GraphitiPool.search_nodes and returned without raising. If it had raised,
      # Recall.await_aux would have logged "[gralkor] recall learning search failed".
      refute String.contains?(logs, "learning search failed")

      # And it ran as a NODE search filtered to node_labels: ["Learning"] — the
      # fake graphiti recorded the labels of every search_ it received.
      {rec, _} = Pythonx.eval("g.recorded", %{"g" => g})
      assert ["Learning"] in (rec |> Pythonx.decode())["node_label_calls"]
    end

    test "then the generalisation search reaches the graph as a node search, so a generalisation naming a single subject is returned",
         %{g: g} do
      import ExUnit.CaptureLog

      logs =
        capture_log(fn ->
          assert {:ok, _block} = Native.recall("g", "TestAgent", nil, "what does Eli prefer")
        end)

      refute String.contains?(logs, "gen search failed")

      {rec, _} = Pythonx.eval("g.recorded", %{"g" => g})
      assert [] in (rec |> Pythonx.decode())["node_label_calls"]
    end

    test "then searching generalisations asks the graph for episodes and decodes the stored bodies",
         %{g: g} do
      assert {:ok, [generalisation]} = Native.search_generalisations("g", "dark mode", 5)

      assert generalisation.id == "gen-1"
      assert generalisation.content == "Eli prefers dark mode"
      assert generalisation.level == 0
      assert generalisation.confidence == 0.8

      {rec, _} = Pythonx.eval("g.recorded", %{"g" => g})
      assert (rec |> Pythonx.decode())["episode_calls"] == [["bm25"]]
    end
  end
end
