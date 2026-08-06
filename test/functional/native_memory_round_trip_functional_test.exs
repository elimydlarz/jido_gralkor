defmodule Gralkor.NativeMemoryRoundTripFunctionalTest do
  @moduledoc """
  The native adapter's write, capture, flush and recall path at its public
  seam, with the graph replaced by a recording substitute.

  Every internal component is real — `Gralkor.Client.Native`, the capture
  buffer, the flush callback the application builds, the recall pipeline. Only
  the two things outside the system boundary are substituted: the graph, by a
  fake that records what it was asked to write and returns what the test tells
  it to, and the learning step, by a deterministic function. Interpretation
  still runs against the configured model, so the leaves that depend on it are
  the ones that need a credential.

  Reifies the `native-memory-round-trip` tree.
  """

  use ExUnit.Case, async: false

  alias Gralkor.Application, as: App
  alias Gralkor.CaptureBuffer
  alias Gralkor.Client.Native
  alias Gralkor.GraphitiPool
  alias Gralkor.Message

  @moduletag :functional
  @moduletag timeout: 120_000

  setup do
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

        class _Node:
            def __init__(self, name, summary):
                self.name = name
                self.summary = summary
                self.attributes = {}

        class _Results:
            def __init__(self, nodes):
                self.nodes = nodes
                self.episodes = []

        class _FakeGraphiti:
            def __init__(self):
                self.recorded = {"episodes": []}
                self.facts = []
                self.learning_nodes = []
                self.search_fails = False

            async def add_episode(self, **kwargs):
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

            async def search_(self, query, config=None, group_ids=None, search_filter=None):
                labels = list(search_filter.node_labels) if search_filter is not None and search_filter.node_labels else []
                if labels == ["Learning"]:
                    return _Results([_Node(n[0], n[1]) for n in self.learning_nodes])
                return _Results([])

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
        construct_instance: fn _db, _shared, _group_id -> g end,
        warmup: false,
        install_loop_fn: &Gralkor.Python.install_async_runtime/0
      )

    on_exit(fn -> if Process.alive?(pool), do: GenServer.stop(pool) end)

    %{g: g}
  end

  defp start_buffer(learn_fn) do
    start_supervised!(
      {CaptureBuffer, [flush_callback: App.build_flush_callback(nil, learn_fn: learn_fn)]}
    )
  end

  defp episodes(g) do
    {raw, _} = Pythonx.eval("g.recorded['episodes']", %{"g" => g})
    Pythonx.decode(raw)
  end

  defp put_facts(g, facts), do: Pythonx.eval("g.facts = facts", %{"g" => g, "facts" => facts})

  defp put_learning(g, name, summary),
    do:
      Pythonx.eval("g.learning_nodes = [(name, summary)]", %{
        "g" => g,
        "name" => name,
        "summary" => summary
      })

  defp fail_search(g), do: Pythonx.eval("g.search_fails = True", %{"g" => g})

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

  describe "native-memory-round-trip > when a fact is written into an operator's memory" do
    test "then the write reaches the graph as a plain-text episode under that operator's group", %{
      g: g
    } do
      assert :ok =
               Native.memory_add(
                 "operator-one",
                 "Eli works at Anthropic in Sydney.",
                 "manual"
               )

      assert [episode] = episodes(g)
      assert episode["group_id"] == "operator_one"
      assert episode["body"] == "Eli works at Anthropic in Sydney."
      assert episode["source_description"] == "manual"
    end

    test "then a later recall from a session that never held the conversation returns an untrusted memory block carrying what interpretation kept",
         %{g: g} do
      :ok = Native.memory_add("operator_one", "Eli works at Anthropic in Sydney.", "manual")

      put_facts(g, [
        "- Eli works at Anthropic.",
        "- The office plant is a monstera."
      ])

      assert {:ok, block} = Native.recall("operator_one", "TestAgent", "fresh-session", "Where does Eli work?")

      assert block =~ ~r/<gralkor-memory trust="untrusted">/
      assert block =~ "</gralkor-memory>"

      lower = String.downcase(block)
      assert lower =~ "anthropic"

      refute lower =~ "monstera",
             "expected relevance to be judged against the query that was asked; got: #{block}"
    end
  end

  describe "native-memory-round-trip > when a captured turn is flushed for its session" do
    test "then the flush is accepted immediately, the transcript reaches the graph, and the buffered turns are consumed",
         %{g: g} do
      start_buffer(nil)

      :ok =
        Native.capture("session-1", "operator_one", "Susu", "Eli", [
          Message.new("user", "my favourite colour is teal"),
          Message.new("assistant", "Noted — teal it is.")
        ])

      assert :ok = Native.flush("session-1")

      episode = await_episode(g, "captured")
      assert episode, "expected a captured episode to reach the graph"
      assert episode["group_id"] == "operator_one"
      assert episode["body"] =~ "teal"

      assert :ok = Native.flush("session-1")
      Process.sleep(200)

      assert Enum.count(episodes(g), &(&1["source_description"] == "captured")) == 1
    end
  end

  describe "native-memory-round-trip > while learning is wired into the flush" do
    test "then a flushed turn's learning reaches the graph as its own episode asking for the Learning entity type",
         %{g: g} do
      learning = %Gralkor.AgentLearning{
        problem_kind: "scheduling conflict",
        approach: "moved the vacuum job",
        success: true,
        lesson: "separate overlapping jobs"
      }

      start_buffer(fn _turn, _agent, _user -> {:ok, learning} end)

      :ok =
        Native.capture("session-2", "operator_one", "Susu", "Eli", [
          Message.new("user", "the backup keeps failing"),
          Message.new("assistant", "I moved the vacuum job.")
        ])

      :ok = Native.flush("session-2")

      episode = await_episode(g, "learning")
      assert episode, "expected a learning episode to reach the graph"
      assert episode["body"] =~ "separate overlapping jobs"
      assert "Learning" in episode["entity_types"]
    end

    test "then a later recall combines what the learning search returns with the regular facts before interpretation",
         %{g: g} do
      put_facts(g, ["- Eli prefers concise answers."])
      put_learning(g, "scheduling conflict", "Move one of two overlapping jobs to a later hour.")

      assert {:ok, block} =
               Native.recall(
                 "operator_one",
                 "Susu",
                 "fresh-session",
                 "how do I resolve two jobs that overlap?"
               )

      lower = String.downcase(block)

      assert lower =~ "overlapping" or lower =~ "later hour",
             "expected the learning search's result to reach interpretation; got: #{block}"
    end
  end

  describe "native-memory-round-trip > if the graph fails the search a recall runs" do
    test "then that failure is returned to the caller and no memory block is manufactured", %{g: g} do
      fail_search(g)

      assert {:error, {:python, reason}} =
               Native.recall("operator_one", "TestAgent", nil, "anything at all")

      assert reason =~ "graph refused the search"
    end
  end
end
