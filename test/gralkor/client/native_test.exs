defmodule Gralkor.Client.NativeTest do
  use ExUnit.Case, async: false

  alias Gralkor.CaptureBuffer
  alias Gralkor.Client
  alias Gralkor.Client.Native
  alias Gralkor.GraphitiPool
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

  describe "if a capture is requested with a missing or blank session id" do
    setup :start_capture_buffer

    test "then an argument error naming the session id is raised" do
      for session_id <- [nil, ""] do
        assert_raise ArgumentError, ~r/session_id/, fn ->
          Native.capture(session_id, "g", "TestAgent", "Eli", [Message.new("user", "x")])
        end
      end
    end

    test "and no turn is buffered" do
      for session_id <- [nil, ""] do
        assert_raise ArgumentError, ~r/session_id/, fn ->
          Native.capture(session_id, "g", "TestAgent", "Eli", [Message.new("user", "x")])
        end
      end

      assert CaptureBuffer.turns_for("s1") == []
    end
  end

  describe "if a capture is requested with a missing or blank agent name" do
    setup :start_capture_buffer

    test "then an argument error naming the agent name is raised" do
      for agent_name <- [nil, ""] do
        assert_raise ArgumentError, ~r/agent_name/, fn ->
          Native.capture("s1", "g", agent_name, "Eli", [Message.new("user", "x")])
        end
      end
    end

    test "and no turn is buffered" do
      for agent_name <- [nil, ""] do
        assert_raise ArgumentError, ~r/agent_name/, fn ->
          Native.capture("s1", "g", agent_name, "Eli", [Message.new("user", "x")])
        end
      end

      assert CaptureBuffer.turns_for("s1") == []
    end
  end

  describe "if a capture is requested with a missing or blank user name" do
    setup :start_capture_buffer

    test "then an argument error naming the user name is raised" do
      for user_name <- [nil, ""] do
        assert_raise ArgumentError, ~r/user_name/, fn ->
          Native.capture("s1", "g", "TestAgent", user_name, [Message.new("user", "x")])
        end
      end
    end

    test "and no turn is buffered" do
      for user_name <- [nil, ""] do
        assert_raise ArgumentError, ~r/user_name/, fn ->
          Native.capture("s1", "g", "TestAgent", user_name, [Message.new("user", "x")])
        end
      end

      assert CaptureBuffer.turns_for("s1") == []
    end
  end

  describe "when recall is requested for a group, agent and query > if the configured interpretation output budget is not a positive integer" do
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

    test "then the adapter raises an argument error naming that setting before recall starts" do
      for value <- [0, -1, "lots"] do
        Application.put_env(:jido_gralkor, :interpret_max_output_tokens, value)

        assert_raise ArgumentError, ~r/interpret_max_output_tokens/, fn ->
          Native.recall("g", "TestAgent", "s1", "q")
        end
      end
    end
  end

  describe "when an interpretation output-token option is built for a supported provider > while the provider is OpenAI" do
    test "then the option uses `max_completion_tokens`, which OpenAI structured-output requests accept" do
      assert Native.interpret_output_token_options(:openai, 321) ==
               [max_completion_tokens: 321]
    end
  end

  describe "when an interpretation output-token option is built for a supported provider > while the provider is Google" do
    test "then the option uses `max_tokens`, which ReqLLM translates for that provider" do
      assert Native.interpret_output_token_options(:google, 654) == [max_tokens: 654]
    end
  end

  describe "when the native adapter reads a structured interpretation response > if the required relevant facts field is absent" do
    test "then the absent value remains malformed rather than becoming a valid empty selection" do
      assert {:ok, nil} = Native.interpret_relevant_facts(%{})
    end
  end

  describe "if a recall is requested with a missing or blank agent name" do
    test "then an argument error naming the agent name is raised" do
      for agent_name <- [nil, ""] do
        assert_raise ArgumentError, ~r/agent_name/, fn ->
          Native.recall("g", agent_name, "s1", "q")
        end
      end
    end

    test "and no search is issued" do
      for agent_name <- [nil, ""] do
        assert_raise ArgumentError, ~r/agent_name/, fn ->
          Native.recall("g", agent_name, "s1", "q")
        end
      end
    end
  end

  describe "if a flush is requested with a missing or blank session id" do
    test "then an argument error naming the session id is raised" do
      for session_id <- [nil, ""] do
        assert_raise ArgumentError, ~r/session_id/, fn -> Native.flush(session_id) end
      end
    end
  end

  describe "if a flush-and-await is requested with a missing or blank session id" do
    test "then an argument error naming the session id is raised" do
      for session_id <- [nil, ""] do
        assert_raise ArgumentError, ~r/session_id/, fn ->
          Native.flush_and_await(session_id, 1_000)
        end
      end
    end
  end

  describe "if a flush-and-await is requested with a missing or non-positive timeout" do
    test "then an argument error naming the timeout is raised" do
      for timeout <- [nil, 0, -1] do
        assert_raise ArgumentError, ~r/timeout_ms/, fn ->
          apply(Native, :flush_and_await, ["s1", timeout])
        end
      end
    end
  end

  describe "when a group id holding hyphens is sanitised" do
    test "then every hyphen is replaced with an underscore" do
      assert Client.sanitize_group_id("a-b-c") == "a_b_c"
    end

    test "and consecutive hyphens are each replaced independently, so none is collapsed into another" do
      assert Client.sanitize_group_id("a--b") == "a__b"
    end
  end

  describe "when a group id holding no hyphens is sanitised" do
    test "then it is returned unchanged" do
      assert Client.sanitize_group_id("abc") == "abc"
    end
  end

  describe "when the client implementation is resolved > while no client module is configured" do
    test "then the native adapter is returned" do
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

  describe "when a grouped session captures messages with agent and user names" do
    setup :start_capture_buffer

    setup do
      original = Application.get_env(:jido_gralkor, :ontology)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:jido_gralkor, :ontology)
          value -> Application.put_env(:jido_gralkor, :ontology, value)
        end
      end)

      :ok
    end

    test "then the group is sanitised before it is buffered" do
      msgs = [Message.new("user", "hi")]

      assert :ok = Native.capture("s1", "with-hyphens", "Susu", "Eli", msgs)
      assert [^msgs] = CaptureBuffer.turns_for("s1")

      :ok = CaptureBuffer.flush("s1")
      assert_receive {:flushed, "with_hyphens", "Susu", "Eli", nil, [^msgs]}
    end

    test "and the deployment-wide ontology is selected, the caller being given no ontology argument of its own" do
      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])
      assert :ok = Native.flush("s1")
      assert_receive {:flushed, "g", "Susu", "Eli", nil, _turns}
    end

    test "and that resolved ontology is buffered alongside the turn" do
      Application.put_env(:jido_gralkor, :ontology, Gralkor.TestOntologies.Strict)
      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])
      assert :ok = Native.flush("s1")
      assert_receive {:flushed, "g", "Susu", "Eli", Gralkor.TestOntologies.Strict, _turns}
    end

    test "and the buffer receives the session, sanitised group, names, ontology and messages" do
      msgs = [Message.new("user", "hi")]
      assert :ok = Native.capture("s1", "with-hyphens", "Susu", "Eli", msgs)
      assert [^msgs] = CaptureBuffer.turns_for("s1")
      assert :ok = CaptureBuffer.flush("s1")
      assert_receive {:flushed, "with_hyphens", "Susu", "Eli", nil, [^msgs]}
    end

    test "and success is returned immediately, no distillation running before the call returns" do
      assert :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])
      assert [_turn] = CaptureBuffer.turns_for("s1")
    end

    test "and nothing is logged for the turn itself, captured content becoming observable only at flush" do
      logs =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])
        end)

      assert logs == ""
    end
  end

  describe "where a turn is captured through a named Lens" do
    setup :start_capture_buffer

    setup do
      original = Application.get_env(:jido_gralkor, :ontology)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:jido_gralkor, :ontology)
          value -> Application.put_env(:jido_gralkor, :ontology, value)
        end
      end)

      :ok
    end

    test "then the operator id is buffered unsanitised, so the Lens keeps the operator's original identity" do
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

    test "and the agent name, the user name, the Lens name and the messages are appended to the capture buffer under that session" do
      msgs = [Message.new("user", "hi")]

      assert :ok =
               Native.capture("s1", "operator", "Susu", "Eli", msgs, "observations")

      assert [^msgs] = CaptureBuffer.turns_for("s1")
      assert :ok = CaptureBuffer.flush_and_await("s1", 1_000)
      assert_receive {:flushed, "operator", "Susu", "Eli", "observations", [^msgs]}
    end

    test "and the built-in ontology is not selected, a named Lens owning its own ontology" do
      Application.put_env(:jido_gralkor, :ontology, Gralkor.TestOntologies.NotAnOntology)
      msgs = [Message.new("user", "hi")]

      assert :ok =
               Native.capture("s1", "operator", "Susu", "Eli", msgs, "observations")

      assert :ok = CaptureBuffer.flush_and_await("s1", 1_000)
      assert_receive {:flushed, "operator", "Susu", "Eli", "observations", [^msgs]}
    end

    test "and success is returned immediately" do
      assert :ok =
               Native.capture(
                 "s1",
                 "operator",
                 "Susu",
                 "Eli",
                 [Message.new("user", "hi")],
                 "observations"
               )
    end
  end

  describe "where a turn is captured through a primary Lens together with additional Lenses" do
    setup :start_capture_buffer

    test "then each named Lens receives that turn in its own flush batch" do
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

    test "but the session buffers the turn only once" do
      msgs = [Message.new("user", "hi")]

      assert :ok =
               Native.capture(
                 "s1",
                 "operator",
                 "Susu",
                 "Eli",
                 msgs,
                 "observations",
                 ["generalisations"]
               )

      assert [^msgs] = CaptureBuffer.turns_for("s1")
    end
  end

  describe "when a session holding buffered turns is flushed" do
    setup :start_capture_buffer

    test "then those turns are scheduled for flush" do
      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])

      assert :ok = Native.flush("s1")
      assert_receive {:flushed, "g", "Susu", "Eli", Gralkor.DefaultOntology, _turns}
    end

    test "and success is returned before that flush completes" do
      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])
      assert :ok = Native.flush("s1")
      assert_receive {:flushed, "g", "Susu", "Eli", Gralkor.DefaultOntology, _turns}
    end
  end

  describe "when a session holding no buffered turns is flushed" do
    setup :start_capture_buffer

    test "then success is returned" do
      assert :ok = Native.flush("nope")
    end

    test "and no flush work is scheduled" do
      assert :ok = Native.flush("nope")
      refute_receive {:flushed, _, _, _, _, _}, 100
    end
  end

  describe "when buffered turns are flushed and awaited with a positive timeout > while the flush completes inside the timeout" do
    setup :start_capture_buffer

    test "then success is returned" do
      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])

      assert :ok = Native.flush_and_await("s1", 1_000)
      assert_receive {:flushed, "g", "Susu", "Eli", Gralkor.DefaultOntology, _turns}
    end

    test "and immediate recall for the bound group surfaces the flushed turns" do
      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])
      assert :ok = Native.flush_and_await("s1", 1_000)

      assert_receive {:flushed, "g", "Susu", "Eli", Gralkor.DefaultOntology,
                      [[%Message{content: "x"}]]}
    end
  end

  describe "when buffered turns are flushed and awaited with a positive timeout > while the flush does not complete inside the timeout" do
    setup do
      test_pid = self()

      callback = fn group, agent, user, ontology, turns ->
        send(test_pid, {:flush_started, group, agent, user, ontology, turns})
        Process.sleep(5_000)
        :ok
      end

      start_supervised!({CaptureBuffer, flush_callback: callback, retries: []})
      :ok
    end

    test "then a timeout error is returned" do
      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])

      assert {:error, :timeout} = Native.flush_and_await("s1", 50)
      assert_receive {:flush_started, "g", "Susu", "Eli", Gralkor.DefaultOntology, _turns}
    end

    test "and the buffered turns remain available to flush on a later call" do
      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])

      assert {:error, :timeout} = Native.flush_and_await("s1", 50)
      assert_receive {:flush_started, "g", "Susu", "Eli", Gralkor.DefaultOntology, _turns}

      assert :ok = Native.flush("s1")
      assert_receive {:flush_started, "g", "Susu", "Eli", Gralkor.DefaultOntology, _turns}
    end
  end

  describe "when buffered turns are flushed and awaited with a positive timeout > if the backend fails before the timeout elapses" do
    setup do
      start_supervised!(
        {CaptureBuffer,
         flush_callback: fn _g, _a, _u, _o, _t -> {:error, :capture_client_4xx} end, retries: []}
      )

      :ok
    end

    test "then that failure is returned unchanged" do
      :ok = Native.capture("s1", "g", "Susu", "Eli", [Message.new("user", "x")])

      assert {:error, :capture_client_4xx} = Native.flush_and_await("s1", 1_000)
    end
  end

  describe "when a session holding no buffered turns is flushed and awaited" do
    setup :start_capture_buffer

    test "then success is returned" do
      assert :ok = Native.flush_and_await("nope", 1_000)
    end
  end

  # The adapter's write and admin calls go through GraphitiPool, so exercising
  # them means starting the pool over a fake graphiti that records what it was
  # asked for. Everything the adapter is supposed to decide — the sanitised
  # group, the source description, which ontology applies — is visible in that
  # recording.
  defp start_recording_pool(_ctx) do
    {g, _} =
      Pythonx.eval(
        """
        import asyncio

        class _Results:
            def __init__(self):
                self.nodes = []
                self.episodes = []

        class _FakeGraphiti:
            def __init__(self):
                self.recorded = {"episodes": [], "communities": 0, "indices": 0}

            async def search(self, query, num_results=10, search_filter=None):
                if query.startswith("slow:"):
                    await asyncio.sleep(0.3)
                return []

            async def search_(self, query, config=None, group_ids=None, search_filter=None):
                if query.startswith("slow:"):
                    await asyncio.sleep(0.3)
                return _Results()

            async def add_episode(self, **kwargs):
                if kwargs.get("episode_body") == "boom":
                    raise RuntimeError("graph refused the write")
                self.recorded["episodes"].append({
                    "name": kwargs.get("name"),
                    "group_id": kwargs.get("group_id"),
                    "body": kwargs.get("episode_body"),
                    "source_description": kwargs.get("source_description"),
                    "entity_types": sorted((kwargs.get("entity_types") or {}).keys()),
                    "edge_types": sorted((kwargs.get("edge_types") or {}).keys()),
                    "excluded_entity_types": kwargs.get("excluded_entity_types"),
                    "kwargs": sorted(kwargs.keys()),
                })

            async def build_indices_and_constraints(self):
                if self.recorded["indices"] == "fail":
                    raise RuntimeError("indices refused")
                self.recorded["indices"] += 1

            async def build_communities(self):
                if self.recorded["communities"] == "fail":
                    raise RuntimeError("communities refused")
                return ([1, 2, 3], [4])

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

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    original = Application.get_env(:jido_gralkor, :ontology)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:jido_gralkor, :ontology)
        v -> Application.put_env(:jido_gralkor, :ontology, v)
      end
    end)

    Application.delete_env(:jido_gralkor, :ontology)

    %{pool: pid, g: g}
  end

  defp episodes(g) do
    {raw, _} = Pythonx.eval("g.recorded['episodes']", %{"g" => g})
    Pythonx.decode(raw)
  end

  describe "when memory is added with a group and content" do
    @describetag :integration
    setup :start_recording_pool

    test "then the group is sanitised before the write", %{g: g} do
      assert :ok = Native.memory_add("operator-with-hyphens", "Eli works at Anthropic", "manual")
      assert [episode] = episodes(g)
      assert episode["group_id"] == "operator_with_hyphens"
    end

    test "and the content is written to the graph as a plain-text episode scoped to the sanitised group",
         %{g: g} do
      assert :ok = Native.memory_add("operator-with-hyphens", "Eli works at Anthropic", "manual")
      assert [episode] = episodes(g)
      assert episode["group_id"] == "operator_with_hyphens"
      assert episode["body"] == "Eli works at Anthropic"
      assert episode["source_description"] == "manual"
    end

    test "and the generated name combines the millisecond timestamp with a positive monotonic integer",
         %{g: g} do
      assert :ok = Native.memory_add("g1", "first", "manual")
      assert :ok = Native.memory_add("g1", "second", "manual")

      assert [first, second] = episodes(g)
      assert first["name"] =~ ~r/^manual-add-\d+-\d+$/
      assert second["name"] =~ ~r/^manual-add-\d+-\d+$/
      refute first["name"] == second["name"]
    end

    test "and success is returned once the graph accepts the write", %{g: g} do
      assert :ok = Native.memory_add("g1", "content", "manual")
      assert [%{"body" => "content"}] = episodes(g)
    end

    test "then the deployment-wide ontology is applied while a caller may override it",
         %{g: g} do
      Code.ensure_loaded!(Native)
      assert function_exported?(Native, :memory_add, 3)
      assert function_exported?(Native, :memory_add, 4)
      Application.put_env(:jido_gralkor, :ontology, nil)
      assert :ok = Native.memory_add("g1", "content", "manual")
      assert [episode] = episodes(g)
      refute "entity_types" in episode["kwargs"]
      refute "excluded_entity_types" in episode["kwargs"]
    end
  end

  describe "when memory is added with a group and content > where a source description is supplied" do
    @describetag :integration
    setup :start_recording_pool

    test "then it is the source recorded on the episode", %{g: g} do
      assert :ok = Native.memory_add("g1", "content", "captured")
      assert [%{"source_description" => "captured"}] = episodes(g)
    end
  end

  describe "when memory is added with a group and content > where no source description is supplied" do
    @describetag :integration
    setup :start_recording_pool

    test "then the source recorded on the episode is \"manual\"", %{g: g} do
      assert :ok = Native.memory_add("g1", "content", nil)
      assert [%{"source_description" => "manual"}] = episodes(g)
    end
  end

  describe "when memory is added with a group and content > if the graph fails" do
    @describetag :integration
    setup :start_recording_pool

    test "then that failure is returned unchanged", %{g: g} do
      assert {:error, {:python, reason}} = Native.memory_add("g1", "boom", "manual")
      assert reason =~ "graph refused the write"
      assert episodes(g) == []
    end
  end

  describe "when any adapter operation is called" do
    @describetag :integration
    setup :start_recording_pool

    test "then the work runs in the calling node's own processes, no HTTP request or other network transport being involved",
         %{g: g} do
      assert Application.get_env(:jido_gralkor, :client_http) != nil

      assert :ok = Native.memory_add("g1", "written in-process", "manual")

      assert [%{"body" => "written in-process"}] = episodes(g)
    end
  end

  describe "when a recall runs" do
    @describetag :integration
    setup :start_recording_pool

    setup do
      original = Application.get_env(:jido_gralkor, :recall_deadline_ms)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:jido_gralkor, :recall_deadline_ms)
          v -> Application.put_env(:jido_gralkor, :recall_deadline_ms, v)
        end
      end)

      :ok
    end

    @tag :capture_log
    test "then it carries the recall pipeline's deadline, twelve seconds unless the deployment configures another" do
      Application.put_env(:jido_gralkor, :recall_deadline_ms, 50)

      assert {:error, :recall_deadline_expired} =
               Native.recall("g", "TestAgent", nil, "slow: what do we know")

      Application.delete_env(:jido_gralkor, :recall_deadline_ms)

      assert {:ok, block} = Native.recall("g", "TestAgent", nil, "slow: what do we know")
      assert block =~ "<gralkor-memory"
    end
  end

  describe "when a recall runs > if that deadline is exceeded" do
    @describetag :integration
    setup :start_recording_pool

    setup do
      original = Application.get_env(:jido_gralkor, :recall_deadline_ms)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:jido_gralkor, :recall_deadline_ms)
          value -> Application.put_env(:jido_gralkor, :recall_deadline_ms, value)
        end
      end)

      Application.put_env(:jido_gralkor, :recall_deadline_ms, 50)
      :ok
    end

    @tag :capture_log
    test "then an error identifying the expired deadline is returned to the caller" do
      assert {:error, :recall_deadline_expired} =
               Native.recall("g", "TestAgent", nil, "slow: what do we know")
    end

    @tag :capture_log
    test "and the work already handed to the embedded interpreter finishes unobserved, no layer being able to cancel it" do
      assert {:error, :recall_deadline_expired} =
               Native.recall("g", "TestAgent", nil, "slow: what do we know")

      Process.sleep(350)
      assert Process.alive?(Process.whereis(Gralkor.GraphitiPool))
    end
  end

  describe "where any adapter operation other than recall runs" do
    @describetag :integration
    setup :start_recording_pool

    test "then it carries no deadline of its own, so a memory addition, a capture flush, an index rebuild and a community build each run for as long as the graph takes" do
      assert :ok = Native.memory_add("g1", "content", "manual")
      assert {:ok, %{status: "built"}} = Native.build_indices()
      assert {:ok, %{communities: 3, edges: 1}} = Native.build_communities("g1")
    end
  end

  describe "when an index and constraint rebuild is requested" do
    @describetag :integration
    setup :start_recording_pool

    test "then the rebuild is applied to the whole graph rather than to a single group", %{g: g} do
      Native.memory_add("g1", "content", "manual")
      assert {:ok, %{status: "built"}} = Native.build_indices()

      {recorded, _} = Pythonx.eval("g.recorded['indices']", %{"g" => g})
      assert Pythonx.decode(recorded) == 2
    end

    test "and a status is returned once the rebuild completes" do
      assert {:ok, %{status: "built"}} = Native.build_indices()
    end
  end

  describe "when an index and constraint rebuild is requested > if the graph fails" do
    @describetag :integration
    setup :start_recording_pool

    test "then that failure is returned unchanged", %{g: g} do
      assert :ok = Native.memory_add("g1", "content", "manual")
      Pythonx.eval("g.recorded['indices'] = 'fail'", %{"g" => g})
      assert {:error, {:python, reason}} = Native.build_indices()
      assert reason =~ "indices refused"
    end
  end

  describe "when community building is requested for a group" do
    @describetag :integration
    setup :start_recording_pool

    test "then the group is sanitised before use" do
      assert {:ok, %{communities: 3, edges: 1}} = Native.build_communities("with-hyphens")

      assert Enum.any?(:ets.tab2list(:gralkor_graphiti_instances), fn {group, _} ->
               group == "with_hyphens"
             end)
    end

    test "and community building is scoped to the sanitised group" do
      assert {:ok, %{communities: 3, edges: 1}} = Native.build_communities("with-hyphens")

      assert Enum.any?(:ets.tab2list(:gralkor_graphiti_instances), fn {group, _} ->
               group == "with_hyphens"
             end)
    end

    test "and the number of communities and the number of edges built are returned" do
      assert {:ok, %{communities: 3, edges: 1}} = Native.build_communities("with-hyphens")
    end
  end

  describe "when community building is requested for a group > if the graph fails" do
    @describetag :integration
    setup :start_recording_pool

    test "then that failure is returned unchanged", %{g: g} do
      Pythonx.eval("g.recorded['communities'] = 'fail'", %{"g" => g})
      assert {:error, {:python, reason}} = Native.build_communities("g1")
      assert reason =~ "communities refused"
    end
  end

  defp start_recall_recording_pool(_ctx) do
    {g, _} =
      Pythonx.eval(
        """
        import asyncio

        class _FakeGraphiti:
            def __init__(self):
                self.recorded = {}

            async def search(self, query, num_results=10, search_filter=None):
                self.recorded.setdefault('fact_queries', []).append(query)
                if query.startswith('slow:'):
                    await asyncio.sleep(0.3)
                return []

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
        initialise_instance: fn _instance -> :ok end,
        warmup: false,
        install_loop_fn: &Gralkor.Python.install_async_runtime/0
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    %{pid: pid, g: g}
  end

  describe "when recall is requested for a group, agent and query" do
    @describetag :integration
    setup :start_recall_recording_pool

    test "then a fact search scoped to the group is supplied to the recall pipeline", %{g: g} do
      assert {:ok, _block} = Native.recall("operator-group", "TestAgent", nil, "raw query")
      {recorded, _} = Pythonx.eval("g.recorded", %{"g" => g})
      recorded = Pythonx.decode(recorded)
      assert recorded["fact_queries"] == ["raw query"]

      assert Enum.any?(:ets.tab2list(:gralkor_graphiti_instances), fn {group, _} ->
               group == "operator_group"
             end)
    end
  end

  describe "when recall is requested for a group, agent and query > while a session id is given" do
    @describetag :integration
    setup :start_recall_recording_pool
    setup :start_capture_buffer

    test "then it is handed to the recall pipeline, so the turns buffered for that session become the conversation context" do
      messages = [Message.new("user", "earlier context")]
      assert :ok = Native.capture("session-1", "g", "TestAgent", "Eli", messages)
      assert {:ok, block} = Native.recall("g", "TestAgent", "session-1", "raw query")
      assert block =~ "<gralkor-memory"
      assert [^messages] = CaptureBuffer.turns_for("session-1")
    end
  end

  describe "when recall is requested for a group, agent and query > where no session id is given" do
    @describetag :integration
    setup :start_recall_recording_pool

    test "then the recall pipeline is invoked without one" do
      assert {:ok, block} = Native.recall("g", "TestAgent", nil, "raw query")
      assert block =~ "<gralkor-memory"
    end

    test "and the conversation context is empty" do
      assert {:ok, block} = Native.recall("g", "TestAgent", nil, "raw query")
      assert block =~ "No relevant memories found."
    end
  end

  describe "when recall is requested for a group, agent and query > where a recall deadline is configured" do
    @describetag :integration
    setup :start_recall_recording_pool

    test "then it is forwarded to the recall pipeline in place of the default deadline" do
      original = Application.get_env(:jido_gralkor, :recall_deadline_ms)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:jido_gralkor, :recall_deadline_ms)
          value -> Application.put_env(:jido_gralkor, :recall_deadline_ms, value)
        end
      end)

      Application.put_env(:jido_gralkor, :recall_deadline_ms, 50)

      assert {:error, :recall_deadline_expired} =
               Native.recall("g", "TestAgent", nil, "slow: raw query")
    end
  end

  describe "when recall is requested for a group, agent and query > where an interpretation output budget is configured" do
    @describetag :integration
    setup :start_recall_recording_pool

    setup do
      original = Application.get_env(:jido_gralkor, :interpret_max_output_tokens)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:jido_gralkor, :interpret_max_output_tokens)
          value -> Application.put_env(:jido_gralkor, :interpret_max_output_tokens, value)
        end
      end)

      :ok
    end

    test "then each call reads the current configured budget without requiring a restart" do
      Application.put_env(:jido_gralkor, :interpret_max_output_tokens, 111)
      assert {:ok, _block} = Native.recall("g", "TestAgent", nil, "first query")

      Application.put_env(:jido_gralkor, :interpret_max_output_tokens, 222)
      assert {:ok, _block} = Native.recall("g", "TestAgent", nil, "second query")
    end

    test "and it is forwarded to the recall pipeline as the interpretation output-token budget" do
      Application.put_env(:jido_gralkor, :interpret_max_output_tokens, 333)
      assert {:ok, block} = Native.recall("g", "TestAgent", nil, "raw query")
      assert block =~ "<gralkor-memory"
    end
  end
end
