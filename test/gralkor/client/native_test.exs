defmodule Gralkor.Client.NativeTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Gralkor.Client
  alias Gralkor.Client.Native
  alias Gralkor.GraphitiPool

  describe "if a recall is requested with a missing or blank agent name" do
    test "then an argument error naming the agent name is raised" do
      for agent_name <- [nil, ""] do
        assert_raise ArgumentError, ~r/agent_name/, fn ->
          Native.recall("g", agent_name, "s1", "q")
        end
      end
    end

    @tag :integration
    test "and no search is issued", context do
      %{g: g} = start_recall_recording_pool(context)

      for agent_name <- [nil, ""] do
        assert_raise ArgumentError, ~r/agent_name/, fn ->
          Native.recall("g", agent_name, "s1", "q")
        end
      end

      {recorded, _} = Pythonx.eval("g.recorded", %{"g" => g})
      assert Pythonx.decode(recorded) == %{}
    end
  end

  describe "when a logical graph identifier is encoded for Graphiti" do
    test "then its physical identifier is `g_` followed by the lowercase hexadecimal encoding of every original byte" do
      logical_id = <<0, 255, ?/, ?a, ?->>

      assert Client.sanitize_group_id(logical_id) ==
               "g_" <> Base.encode16(logical_id, case: :lower)
    end

    test "and distinct logical identifiers always produce distinct physical identifiers" do
      logical_ids = ["a-b", "a_b", "operator/a-b", "operator/a_b", "g_612d62"]

      assert logical_ids
             |> Enum.map(&Client.sanitize_group_id/1)
             |> Enum.uniq()
             |> length() == length(logical_ids)
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

  # The adapter's write and admin calls go through GraphitiPool, so exercising
  # them means starting the pool over a fake graphiti that records what it was
  # asked for. Everything the adapter is supposed to decide — the physical
  # group, the source description, which ontology applies — is visible in that
  # recording.
  defp start_recording_pool(_ctx) do
    {g, _} =
      Pythonx.eval(
        """
        import asyncio

        class _Results:
            def __init__(self):
                self.edges = []
                self.nodes = []
                self.episodes = []

        class _FakeGraphiti:
            def __init__(self):
                self.recorded = {"episodes": [], "communities": 0, "indices": 0}
                self.operation_delay = 0

            async def _wait_for_operation(self):
                if self.operation_delay:
                    await asyncio.sleep(self.operation_delay)

            async def search(self, query, num_results=10, search_filter=None):
                if query.startswith("slow:"):
                    await asyncio.sleep(0.3)
                return []

            async def search_(self, query, config=None, group_ids=None, search_filter=None):
                if query.startswith("slow:"):
                    await asyncio.sleep(0.3)
                return _Results()

            async def add_episode(self, **kwargs):
                await self._wait_for_operation()
                if kwargs.get("episode_body") == "boom":
                    raise RuntimeError("graph refused the write")
                self.recorded["episodes"].append({
                    "name": kwargs.get("name"),
                    "group_id": kwargs.get("group_id"),
                    "body": kwargs.get("episode_body"),
                    "source_kind": kwargs.get("source").value,
                    "source_description": kwargs.get("source_description"),
                    "custom_extraction_instructions": kwargs.get("custom_extraction_instructions"),
                    "entity_types": sorted((kwargs.get("entity_types") or {}).keys()),
                    "edge_types": sorted((kwargs.get("edge_types") or {}).keys()),
                    "excluded_entity_types": kwargs.get("excluded_entity_types"),
                    "kwargs": sorted(kwargs.keys()),
                })

            async def build_indices_and_constraints(self):
                await self._wait_for_operation()
                if self.recorded["indices"] == "fail":
                    raise RuntimeError("indices refused")
                self.recorded["indices"] += 1

            async def build_communities(self):
                await self._wait_for_operation()
                if self.recorded["communities"] == "fail":
                    raise RuntimeError("communities refused")
                self.recorded["communities"] += 1
                return ([1, 2, 3], [4])

        _FakeGraphiti()
        """,
        %{}
      )

    pid =
      start_supervised!(
        {GraphitiPool,
         [
           name: Gralkor.GraphitiPool,
           table: :gralkor_graphiti_instances,
           falkordb_spec: {:embedded, "/tmp/never_used"},
           construct_falkor_db: fn _spec -> :stub_falkor_db end,
           construct_shared_clients: fn _spec ->
             %{llm_client: nil, embedder: nil, cross_encoder: nil}
           end,
           construct_instance: fn _db, _shared, _group_id -> g end,
           warmup: false,
           install_loop_fn: &Gralkor.Python.install_async_runtime/0
         ]}
      )

    %{pool: pid, g: g}
  end

  defp episodes(g) do
    {raw, _} = Pythonx.eval("g.recorded['episodes']", %{"g" => g})
    Pythonx.decode(raw)
  end

  defp call_with_task_yield_deadline(fun) do
    traced_process = self()
    trace_recipient = self()
    tracer = spawn_link(fn -> forward_traces(trace_recipient) end)

    :erlang.trace(traced_process, true, [:call, {:tracer, tracer}])
    :erlang.trace_pattern({Task, :yield, 2}, true, [])

    try do
      result = fun.()

      deadline =
        receive do
          {:native_call_trace,
           {:trace, ^traced_process, :call, {Task, :yield, [_task, deadline]}}} ->
            deadline
        after
          1_000 -> flunk("the Native recall did not reach Task.yield/2")
        end

      {result, deadline}
    after
      :erlang.trace_pattern({Task, :yield, 2}, false, [])
      :erlang.trace(traced_process, false, [:call])
      send(tracer, :stop)
    end
  end

  defp forward_traces(recipient) do
    receive do
      :stop ->
        :ok

      trace ->
        send(recipient, {:native_call_trace, trace})
        forward_traces(recipient)
    end
  end

  defp start_per_group_pool do
    {fake_class, _} =
      Pythonx.eval(
        """
        class _GroupGraphiti:
            def __init__(self):
                self.recorded = {"episodes": 0, "communities": 0, "indices": 0}

            async def add_episode(self, **kwargs):
                self.recorded["episodes"] += 1

            async def build_indices_and_constraints(self):
                self.recorded["indices"] += 1

            async def build_communities(self):
                self.recorded["communities"] += 1
                return ([1, 2, 3], [4])

        _GroupGraphiti
        """,
        %{}
      )

    test_pid = self()

    start_supervised!(
      {GraphitiPool,
       name: Gralkor.GraphitiPool,
       table: :gralkor_graphiti_instances,
       falkordb_spec: {:embedded, "/tmp/never_used"},
       construct_falkor_db: fn _spec -> :stub_falkor_db end,
       construct_shared_clients: fn _spec ->
         %{llm_client: nil, embedder: nil, cross_encoder: nil}
       end,
       construct_instance: fn _db, _shared, group_id ->
         {instance, _} = Pythonx.eval("fake_class()", %{"fake_class" => fake_class})
         send(test_pid, {:constructed_instance, group_id, instance})
         instance
       end,
       warmup: false,
       install_loop_fn: &Gralkor.Python.install_async_runtime/0}
    )
  end

  defp instances_by_group(instances \\ %{}) do
    receive do
      {:constructed_instance, group_id, instance} ->
        instances_by_group(Map.put(instances, group_id, instance))
    after
      0 -> instances
    end
  end

  defp recorded(instance) do
    {recorded, _} = Pythonx.eval("instance.recorded", %{"instance" => instance})
    Pythonx.decode(recorded)
  end

  defp tcp_ports do
    Port.list()
    |> Enum.filter(&(Port.info(&1, :name) == {:name, ~c"tcp_inet"}))
    |> MapSet.new()
  end

  describe "when memory is added with a group and content" do
    @describetag :integration
    setup :start_recording_pool

    test "then the logical group reaches the physical Graphiti boundary unchanged and is encoded exactly once there",
         %{g: g} do
      assert :ok = Native.memory_add("operator-with-hyphens", "Eli works at Anthropic", "manual")
      assert [episode] = episodes(g)
      assert episode["group_id"] == Client.sanitize_group_id("operator-with-hyphens")
    end

    test "and the content is written to the graph as a plain-text episode scoped to that physical group",
         %{g: g} do
      assert :ok = Native.memory_add("operator-with-hyphens", "Eli works at Anthropic", "manual")
      assert [episode] = episodes(g)
      assert episode["group_id"] == Client.sanitize_group_id("operator-with-hyphens")
      assert episode["body"] == "Eli works at Anthropic"
    end

    test "and storage-owned direct writer provenance is recorded without a Lens", %{g: g} do
      assert :ok = Native.memory_add("g1", "content", "manual")
      assert [episode] = episodes(g)
      assert episode["source_description"] == "manual [gralkor: direct]"
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

    test "then jido_gralkor's built-in ontology is applied, so a caller neither supplies nor configures one",
         %{g: g} do
      Code.ensure_loaded!(Native)
      assert function_exported?(Native, :memory_add, 3)
      assert function_exported?(Native, :memory_add, 4)
      assert :ok = Native.memory_add("g1", "content", "manual")
      assert [episode] = episodes(g)
      refute "entity_types" in episode["kwargs"]
      refute "excluded_entity_types" in episode["kwargs"]
    end

    test "and generic entity and relationship extraction remains enabled without an application-owned schema",
         %{g: g} do
      assert :ok = Native.memory_add("g1", "content", "manual")
      assert [episode] = episodes(g)
      refute "entity_types" in episode["kwargs"]
      refute "edge_types" in episode["kwargs"]
      refute "edge_type_map" in episode["kwargs"]
      refute "excluded_entity_types" in episode["kwargs"]
    end
  end

  describe "when memory is added with a group and content > where a source kind is supplied" do
    @describetag :integration
    setup :start_recording_pool

    test "then the declared source kind is forwarded to the graph write", %{g: g} do
      assert :ok =
               Native.memory_add(
                 "g1",
                 "Eli may prefer tea.",
                 "conversation with Eli",
                 :conversation
               )

      assert [episode] = episodes(g)
      assert episode["source_kind"] == "message"
    end
  end

  describe "when memory is added with a group and content > where a source kind is supplied > while the source kind is structured record" do
    @describetag :integration
    setup :start_recording_pool

    test "then the supplied map or list is forwarded as its JSON encoding", %{g: g} do
      assert :ok =
               Native.memory_add(
                 "g1",
                 %{"status" => "approved", "votes" => ["yes", "yes"]},
                 "meeting record",
                 :structured_record
               )

      assert [episode] = episodes(g)

      assert Jason.decode!(episode["body"]) == %{
               "status" => "approved",
               "votes" => ["yes", "yes"]
             }

      assert episode["source_kind"] == "json"
    end
  end

  describe "when memory is added with a group and content > where a source description is supplied" do
    @describetag :integration
    setup :start_recording_pool

    test "then it is retained as the source beneath storage-owned direct provenance", %{g: g} do
      assert :ok = Native.memory_add("g1", "content", "captured")
      assert [%{"source_description" => "captured [gralkor: direct]"}] = episodes(g)
    end
  end

  describe "when memory is added with a group and content > where no source description is supplied" do
    @describetag :integration
    setup :start_recording_pool

    test "then the source retained beneath storage-owned direct provenance is \"manual\"",
         %{g: g} do
      assert :ok = Native.memory_add("g1", "content", nil)
      assert [%{"source_description" => "manual [gralkor: direct]"}] = episodes(g)
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
      tcp_ports_before = tcp_ports()

      assert :ok = Native.memory_add("g1", "written in-process", "manual")

      assert node(Process.whereis(Gralkor.GraphitiPool)) == node()
      assert [%{"body" => "written in-process"}] = episodes(g)
      assert tcp_ports() == tcp_ports_before
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

    test "then it carries the recall pipeline's deadline, twelve seconds unless the deployment configures another" do
      Application.delete_env(:jido_gralkor, :recall_deadline_ms)

      assert {{:ok, default_block}, 12_000} =
               call_with_task_yield_deadline(fn ->
                 Native.recall("g", "TestAgent", nil, "what do we know")
               end)

      assert default_block =~ "<gralkor-memory"

      Application.put_env(:jido_gralkor, :recall_deadline_ms, 75)

      {_configured_outcome, configured_deadline} =
        call_with_task_yield_deadline(fn ->
          Native.recall("g", "TestAgent", nil, "what else do we know")
        end)

      assert configured_deadline == 75
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

    test "then it carries no deadline of its own, so a memory addition, an index rebuild and a community build each run for as long as the graph takes",
         %{g: g} do
      original_deadline = Application.get_env(:jido_gralkor, :recall_deadline_ms)

      on_exit(fn ->
        case original_deadline do
          nil -> Application.delete_env(:jido_gralkor, :recall_deadline_ms)
          value -> Application.put_env(:jido_gralkor, :recall_deadline_ms, value)
        end
      end)

      Application.put_env(:jido_gralkor, :recall_deadline_ms, 1)
      Pythonx.eval("g.operation_delay = 0.05", %{"g" => g})

      assert :ok = Native.memory_add("g1", "content", "manual")

      assert {:ok, %{status: "built"}} = Native.build_indices()
      assert {:ok, %{communities: 3, edges: 1}} = Native.build_communities("g1")

      assert Enum.any?(episodes(g), &(&1["body"] == "content"))

      {recorded, _} = Pythonx.eval("g.recorded", %{"g" => g})
      recorded = Pythonx.decode(recorded)

      assert recorded["indices"] >= 1
      assert recorded["communities"] == 1
    end
  end

  describe "when an index and constraint rebuild is requested" do
    @describetag :integration
    setup :start_recording_pool

    test "then the rebuild is applied to the whole graph rather than to a single group" do
      :ok = stop_supervised(GraphitiPool)
      start_per_group_pool()
      assert :ok = Native.memory_add("g1", "content", "manual")
      assert :ok = Native.memory_add("g2", "content", "manual")
      instances = instances_by_group()

      assert {:ok, %{status: "built"}} = Native.build_indices()

      for group <- ["g1", "g2"] do
        assert recorded(Map.fetch!(instances, Client.sanitize_group_id(group)))["indices"] == 2
      end
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

    test "then the logical group reaches the physical Graphiti boundary unchanged and is encoded exactly once there" do
      assert {:ok, %{communities: 3, edges: 1}} = Native.build_communities("with-hyphens")

      assert Enum.map(:ets.tab2list(:gralkor_graphiti_instances), &elem(&1, 0)) == [
               Client.sanitize_group_id("with-hyphens")
             ]
    end

    test "and community building is scoped to that physical group" do
      :ok = stop_supervised(GraphitiPool)
      start_per_group_pool()
      assert :ok = Native.memory_add("other-group", "content", "manual")
      assert {:ok, %{communities: 3, edges: 1}} = Native.build_communities("with-hyphens")
      instances = instances_by_group()

      assert recorded(Map.fetch!(instances, Client.sanitize_group_id("with-hyphens")))[
               "communities"
             ] == 1

      assert recorded(Map.fetch!(instances, Client.sanitize_group_id("other-group")))[
               "communities"
             ] == 0
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
        import types

        class _FakeGraphiti:
            def __init__(self):
                self.recorded = {}

            async def search_(self, query, config=None, group_ids=None, search_filter=None):
                self.recorded.setdefault('fact_queries', []).append(query)
                if query.startswith('slow:'):
                    await asyncio.sleep(0.3)
                return types.SimpleNamespace(edges=[], nodes=[], episodes=[])

        _FakeGraphiti()
        """,
        %{}
      )

    pid =
      start_supervised!(
        {GraphitiPool,
         name: Gralkor.GraphitiPool,
         table: :gralkor_graphiti_instances,
         falkordb_spec: {:embedded, "/tmp/never_used"},
         construct_falkor_db: fn _spec -> :stub_falkor_db end,
         construct_shared_clients: fn _spec ->
           %{llm_client: nil, embedder: nil, cross_encoder: nil}
         end,
         construct_instance: fn _db, _shared, _group_id -> g end,
         initialise_instance: fn _instance -> :ok end,
         warmup: false,
         install_loop_fn: &Gralkor.Python.install_async_runtime/0}
      )

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
               group == Client.sanitize_group_id("operator-group")
             end)
    end
  end

  describe "when recall is requested for a group, agent and query > while a session id is given" do
    @describetag :integration
    setup :start_recall_recording_pool

    @tag :capture_log
    test "then it is handed to the recall pipeline for recall observability" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, block} = Native.recall("g", "TestAgent", "session-1", "raw query")
          assert block =~ "<gralkor-memory"
        end)

      assert log =~ "[gralkor] recall — session:session-1"
    end
  end

  describe "when recall is requested for a group, agent and query > where no session id is given" do
    @describetag :integration
    setup :start_recall_recording_pool

    @tag :capture_log
    test "then the recall pipeline is invoked without one" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, block} = Native.recall("g", "TestAgent", nil, "raw query")
          assert block =~ "<gralkor-memory"
        end)

      assert log =~ "[gralkor] recall — session: group:g "
    end
  end

  describe "when recall is requested for a group, agent and query > where a positive-integer recall deadline is configured" do
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

  describe "when recall is requested for a group, agent and query > if a configured recall deadline is not a positive integer" do
    test "then an argument error naming the recall deadline is raised before any search is issued" do
      original = Application.get_env(:jido_gralkor, :recall_deadline_ms)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:jido_gralkor, :recall_deadline_ms)
          value -> Application.put_env(:jido_gralkor, :recall_deadline_ms, value)
        end
      end)

      for invalid <- [0, -1, "100"] do
        Application.put_env(:jido_gralkor, :recall_deadline_ms, invalid)

        assert_raise ArgumentError, ~r/recall_deadline_ms/, fn ->
          Native.recall("g", "TestAgent", nil, "query")
        end
      end
    end
  end
end
