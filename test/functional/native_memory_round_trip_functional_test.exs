defmodule Gralkor.NativeMemoryRoundTripFunctionalTest do
  @moduledoc """
  The native adapter's write, capture, flush and recall path at its public
  seam, with the graph replaced by a recording substitute.

  Every internal component is real — `Gralkor.Client.Native`, the capture
  buffer, the flush callback the application builds, the recall pipeline. Only
  the two things outside the system boundary are substituted: the graph, by a
  fake that records what it was asked to write and returns what the test tells
  it to.

  Reifies the `native-memory-round-trip` tree.
  """

  use ExUnit.Case, async: false

  alias Gralkor.Application, as: App
  alias Gralkor.CaptureBuffer
  alias Gralkor.Client
  alias Gralkor.Client.Native
  alias Gralkor.GraphitiPool
  alias Gralkor.Message

  @moduletag :functional
  @moduletag timeout: 120_000

  @captured_source "captured [lens: operator]"

  setup do
    test_pid = self()

    {g, _} =
      Pythonx.eval(
        """
        class _Edge:
            def __init__(self, fact):
                self.fact = fact
                self.created_at = None
                self.valid_at = None
                self.invalid_at = None
                self.expired_at = None

        class _FakeGraphiti:
            def __init__(self):
                self.recorded = {"episodes": []}
                self.facts = []
                self.search_fails = False
                self.add_delay = 0

            async def add_episode(self, **kwargs):
                if self.add_delay:
                    import asyncio
                    await asyncio.sleep(self.add_delay)
                self.recorded["episodes"].append({
                    "group_id": kwargs.get("group_id"),
                    "body": kwargs.get("episode_body"),
                    "source_description": kwargs.get("source_description"),
                    "entity_types": sorted((kwargs.get("entity_types") or {}).keys()),
                })

            async def build_indices_and_constraints(self):
                pass

            async def search(self, query, num_results=10, search_filter=None):
                if self.search_fails:
                    raise RuntimeError("graph refused the search")
                return [_Edge(f) for f in self.facts]

        _FakeGraphiti()
        """,
        %{}
      )

    original_client = Application.get_env(:jido_gralkor, :client)
    Application.put_env(:jido_gralkor, :client, Native)

    on_exit(fn ->
      case original_client do
        nil -> Application.delete_env(:jido_gralkor, :client)
        mod -> Application.put_env(:jido_gralkor, :client, mod)
      end
    end)

    {:ok, pool} =
      GraphitiPool.start_link(
        name: Gralkor.GraphitiPool,
        table: :gralkor_graphiti_instances,
        falkordb_spec: {:embedded, "/tmp/never_used"},
        construct_falkor_db: fn _spec -> :stub_falkor_db end,
        construct_shared_clients: fn _llm, _embedder ->
          %{llm_client: nil, embedder: nil, cross_encoder: nil}
        end,
        construct_instance: fn _db, _shared, group_id ->
          send(test_pid, {:constructed_graph, group_id})
          g
        end,
        warmup: false,
        install_loop_fn: &Gralkor.Python.install_async_runtime/0
      )

    on_exit(fn -> if Process.alive?(pool), do: GenServer.stop(pool) end)

    start_supervised!({CaptureBuffer, [flush_callback: App.build_flush_callback(nil)]})

    %{g: g}
  end

  defp episodes(g) do
    {raw, _} = Pythonx.eval("g.recorded['episodes']", %{"g" => g})
    Pythonx.decode(raw)
  end

  defp put_facts(g, facts), do: Pythonx.eval("g.facts = facts", %{"g" => g, "facts" => facts})

  defp fail_search(g), do: Pythonx.eval("g.search_fails = True", %{"g" => g})

  defp delay_add(g, seconds),
    do: Pythonx.eval("g.add_delay = seconds", %{"g" => g, "seconds" => seconds})

  defp await_episode(g, source, budget_ms \\ 10_000)

  defp await_episode(_g, _source, budget_ms) when budget_ms <= 0, do: nil

  defp await_episode(g, source, budget_ms) do
    case Enum.find(episodes(g), &(&1["source_description"] == source)) do
      nil ->
        Process.sleep(100)
        await_episode(g, source, budget_ms - 100)

      episode ->
        episode
    end
  end

  describe "when a fact is written into an operator's memory" do
    test "then the graph stores its plain text unchanged", %{g: g} do
      assert :ok =
               Native.memory_add(
                 Client.operator_graph_id("operator-one"),
                 "Eli works at Anthropic in Sydney.",
                 "manual"
               )

      assert [episode] = episodes(g)
      assert episode["body"] == "Eli works at Anthropic in Sydney."
    end

    test "and the graph named `operator/<operator id>` receives it", %{g: g} do
      graph_id = Client.operator_graph_id("operator-one")
      assert graph_id == "operator/operator-one"

      assert :ok = Native.memory_add(graph_id, "Operator fact", "manual")

      assert [episode] = episodes(g)
      assert episode["group_id"] == Client.sanitize_group_id(graph_id)
    end
  end

  describe "when facts are written for logical operator graphs that previously normalised to the same name" do
    test "then each logical graph identifier is encoded exactly once at the physical Graphiti boundary" do
      first_logical = Client.operator_graph_id("a-b")
      second_logical = Client.operator_graph_id("a_b")
      first_physical = "g_" <> Base.encode16(first_logical, case: :lower)
      second_physical = "g_" <> Base.encode16(second_logical, case: :lower)

      assert :ok = Native.memory_add(first_logical, "first operator fact", "manual")
      assert :ok = Native.memory_add(second_logical, "second operator fact", "manual")

      assert_receive {:constructed_graph, ^first_physical}
      assert_receive {:constructed_graph, ^second_physical}
    end

    test "and the pool constructs and caches a distinct physical graph instance for each logical graph" do
      first_logical = Client.operator_graph_id("a-b")
      second_logical = Client.operator_graph_id("a_b")
      first_physical = "g_" <> Base.encode16(first_logical, case: :lower)
      second_physical = "g_" <> Base.encode16(second_logical, case: :lower)

      assert :ok = Native.memory_add(first_logical, "first operator fact", "manual")
      assert :ok = Native.memory_add(second_logical, "second operator fact", "manual")

      refute first_physical == second_physical
      assert [{^first_physical, _instance}] =
               :ets.lookup(:gralkor_graphiti_instances, first_physical)

      assert [{^second_physical, _instance}] =
               :ets.lookup(:gralkor_graphiti_instances, second_physical)
    end
  end

  describe "when memory search returns facts for recall" do
    test "then every returned fact is presented verbatim and in order inside an untrusted memory block",
         %{g: g} do
      graph_facts = [
        "Eli works at Anthropic. (source: onboarding notes)",
        "The office plant is a monstera. (source: facilities inventory)"
      ]

      returned_facts = Enum.map(graph_facts, &("- " <> &1))

      put_facts(g, graph_facts)

      assert {:ok, block} =
               Native.recall("operator_one", "TestAgent", "fresh-session", "Where does Eli work?")

      assert block =~ ~r/<gralkor-memory trust="untrusted">/
      assert block =~ "</gralkor-memory>"
      assert block =~ Enum.at(returned_facts, 0)
      assert block =~ Enum.at(returned_facts, 1)

      assert :binary.match(block, Enum.at(returned_facts, 0)) <
               :binary.match(block, Enum.at(returned_facts, 1))
    end

    test "and every returned fact retains its available source wording", %{g: g} do
      source_wording = "according to the incident report filed by Mina"
      put_facts(g, ["The Atlas launch moved to Friday, #{source_wording}."])

      assert {:ok, block} =
               Native.recall("operator_one", "TestAgent", nil, "When is Atlas launching?")

      assert block =~ source_wording
    end
  end

  describe "when a captured turn is flushed for its session" do
    test "then flush returns before graph ingestion completes", %{g: g} do
      delay_add(g, 0.5)
      capture("session-immediate")

      started_at = System.monotonic_time(:millisecond)
      assert :ok = Native.flush("session-immediate")
      assert System.monotonic_time(:millisecond) - started_at < 250
      assert episodes(g) == []
      assert await_episode(g, @captured_source)
    end

    test "and the rendered transcript eventually reaches the session's group with trusted `operator` Lens provenance",
         %{g: g} do
      capture("session-transcript")
      assert :ok = Native.flush("session-transcript")
      episode = await_episode(g, @captured_source)
      assert episode, "expected a captured episode to reach the graph"
      assert episode["group_id"] == Client.sanitize_group_id("operator_one")
      assert episode["body"] =~ "teal"
    end

    test "and a second flush writes no duplicate transcript", %{g: g} do
      capture("session-consumed")
      assert :ok = Native.flush("session-consumed")
      assert await_episode(g, @captured_source)
      assert :ok = Native.flush("session-consumed")
      Process.sleep(200)

      assert Enum.count(episodes(g), &(&1["source_description"] == @captured_source)) == 1
    end
  end

  describe "if the graph fails a recall search" do
    test "then recall returns the graph failure without a memory block", %{
      g: g
    } do
      fail_search(g)

      assert {:error, {:python, reason}} =
               Native.recall("operator_one", "TestAgent", nil, "anything at all")

      assert reason =~ "graph refused the search"
    end
  end

  defp capture(session_id) do
    Native.capture(session_id, "operator_one", "Susu", "Eli", [
      Message.new("user", "my favourite colour is teal"),
      Message.new("assistant", "Noted — teal it is.")
    ])
  end
end
