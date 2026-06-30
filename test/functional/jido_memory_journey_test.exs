defmodule Gralkor.JidoMemoryJourneyTest do
  @moduledoc """
  End-to-end functional test: real PythonX runtime, real graphiti-core, real
  embedded falkordblite. Elixir-side (distill, interpret) uses DeepSeek via
  req_llm (reads DEEPSEEK_API_KEY from `.env`). Python-side graphiti clients
  (entity/edge extraction, embeddings, reranker) are still hard-wired to
  Google Gemini and need GOOGLE_API_KEY.

  Reifies the `jido-memory-journey` tree.
  """

  use ExUnit.Case, async: false

  alias Gralkor.Application, as: App
  alias Gralkor.CaptureBuffer
  alias Gralkor.Client
  alias Gralkor.Client.Native
  alias Gralkor.GraphitiPool
  alias Gralkor.Message

  @moduletag :journey
  @moduletag timeout: 300_000

  setup_all do
    Application.put_env(:jido_gralkor, :recall_deadline_ms, 60_000)
    on_exit(fn -> Application.delete_env(:jido_gralkor, :recall_deadline_ms) end)

    original_client = Application.get_env(:jido_gralkor, :client)
    Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)

    on_exit(fn ->
      case original_client do
        nil -> Application.delete_env(:jido_gralkor, :client)
        mod -> Application.put_env(:jido_gralkor, :client, mod)
      end
    end)

    data_dir =
      Path.join(System.tmp_dir!(), "gralkor_journey_#{System.unique_integer([:positive])}")

    File.mkdir_p!(data_dir)
    System.put_env("GRALKOR_DATA_DIR", data_dir)

    {:ok, _python} = start_supervised(Gralkor.Python)

    {:ok, _pool} =
      start_supervised(
        {GraphitiPool,
         [
           falkordb_spec: {:embedded, data_dir},
           llm_model: %{provider: :google, id: "gemini-3.1-flash-lite"},
           embedder_model: %{provider: :google, id: "gemini-embedding-2-preview"},
           interpret_fn: Native.interpret_callback(),
           warmup: false
         ]}
      )

    flush_callback =
      App.build_flush_callback({:embedded, data_dir}, learn_fn: &Native.learn/3)

    {:ok, _buffer} = start_supervised({CaptureBuffer, [flush_callback: flush_callback]})

    on_exit(fn -> File.rm_rf!(data_dir) end)

    %{group_id: "journey_#{System.unique_integer([:positive])}"}
  end

  describe "jido-memory-journey > round-trip" do
    test "memory_add stores a fact, recall surfaces it under the same group_id", %{
      group_id: group_id
    } do
      :ok =
        Client.impl().memory_add(
          group_id,
          "Eli works at Anthropic in Sydney. He prefers concise technical explanations over verbose ones.",
          "manual",
          nil
        )

      session_id = "session_#{System.unique_integer([:positive])}"

      assert {:ok, block} =
               Client.impl().recall(group_id, "TestAgent", session_id, "Where does Eli work?")

      assert block =~ ~r/<gralkor-memory trust="untrusted">/
      assert block =~ "</gralkor-memory>"

      lower = String.downcase(block)

      assert lower =~ "anthropic" or lower =~ "sydney",
             "expected recall to surface a fact about Eli's employer or location; got: #{block}"
    end
  end

  describe "jido-memory-journey > flush" do
    test "captured turns are flushed and become recallable after flush", %{
      group_id: group_id
    } do
      session_id = "session_#{System.unique_integer([:positive])}"

      :ok =
        Client.impl().capture(session_id, group_id, "TestAgent", "Eli", [
          Message.new(
            "user",
            "Important context: Eli's favourite colour is teal, and Eli drives a blue Subaru Outback."
          ),
          Message.new(
            "assistant",
            "Noted — Eli's favourite colour is teal and Eli drives a blue Subaru Outback."
          )
        ])

      :ok = Client.impl().flush(session_id)

      # Give the buffer flush + distill + graphiti add_episode some time to land.
      Process.sleep(45_000)

      lookup_session = "lookup_#{System.unique_integer([:positive])}"

      assert {:ok, block} =
               Client.impl().recall(
                 group_id,
                 "TestAgent",
                 lookup_session,
                 "What car does Eli drive?"
               )

      lower = String.downcase(block)

      assert lower =~ "subaru" or lower =~ "outback",
             "expected recall to surface a fact about the car; got: #{block}"
    end
  end

  describe "jido-memory-journey > ERL round-trip" do
    test "a captured turn becomes a learning recalled by the kind of problem", %{
      group_id: group_id
    } do
      session_id = "erl_#{System.unique_integer([:positive])}"

      :ok =
        Client.impl().capture(
          session_id,
          group_id,
          "Susu",
          "Eli",
          [
            Message.new("user", "the nightly database backup keeps failing with a lock timeout"),
            Message.new(
              "behaviour",
              "thought: inspected the cron — the backup job and the vacuum job both start at 02:00 and contend on the same table"
            ),
            Message.new(
              "behaviour",
              "tool inspect_schedule → backup and vacuum overlap at 02:00"
            ),
            Message.new(
              "assistant",
              "I moved the vacuum job to 04:00 so it no longer overlaps the backup; the nightly backups now succeed."
            )
          ]
        )

      :ok = Client.impl().flush(session_id)

      # Give the buffer flush + ex-learn LLM call + graphiti add_episode time to land.
      Process.sleep(60_000)

      query = "how do I resolve a scheduling conflict between two jobs that causes lock timeouts?"

      # DIAGNOSTIC PROBE (two signals in one run):
      #  (a) unfiltered search — proves the learning episode was written and is
      #      findable at all (the main recall path would surface it).
      #  (b) Learning-filtered search — the ERL-specific claim: the real graphiti
      #      extractor emitted a Learning-typed node AND SearchFilters(node_labels:
      #      ["Learning"]) retrieves the learning facts.
      # If (a) finds the lesson but (b) does not, the node_labels filter is the
      # problem (design/semantics), not the write path.
      lesson_terms = ["vacuum", "schedul", "overlap", "backup", "04:00", "4:00"]
      hit? = fn facts -> Enum.any?(facts, fn f -> String.downcase(f.fact) |> then(fn t -> Enum.any?(lesson_terms, &String.contains?(t, &1)) end) end) end

      {:ok, unfiltered} = GraphitiPool.search(GraphitiPool, group_id, query, 10, [])
      {:ok, filtered} =
        GraphitiPool.search(GraphitiPool, group_id, query, 10,
          search_filter: %{node_labels: ["Learning"]}
        )

      require Logger
      Logger.info("[erl-probe] unfiltered (#{length(unfiltered)}): #{inspect(Enum.map(unfiltered, & &1.fact))}")
      Logger.info("[erl-probe] filtered (#{length(filtered)}): #{inspect(Enum.map(filtered, & &1.fact))}")

      # ROOT-CAUSE PROBE: list every entity node in the group and its labels,
      # straight from graphiti. If no node carries the "Learning" label, the
      # custom-entity-type approach never produced a Learning node (the extractor
      # cannot classify "this episode is a learning" as an entity). If a Learning
      # node exists but the filtered search is still empty, the filter semantics
      # (edge node_labels) are the issue instead.
      instance = GraphitiPool.for(GraphitiPool, group_id)
      sanitized = Gralkor.Client.sanitize_group_id(group_id)

      {labels_raw, _} =
        Pythonx.eval(
          """
          import asyncio
          from graphiti_core.nodes import EntityNode
          try:
              nodes = asyncio._gralkor_run(EntityNode.get_by_group_ids(g.driver, [gid]))
              result = [(n.name, list(n.labels)) for n in nodes]
          except BaseException as e:
              result = [("PROBE_ERROR", [f"{type(e).__name__}: {e}"])]
          result
          """,
          %{"g" => instance, "gid" => sanitized}
        )

      node_labels = Pythonx.decode(labels_raw)
      Logger.info("[erl-probe] entity nodes + labels: #{inspect(node_labels)}")

      assert hit?.(unfiltered),
             "unfiltered search did not surface the lesson — the learning episode was not written or not extracted into searchable facts; got: #{inspect(Enum.map(unfiltered, & &1.fact))}"

      assert hit?.(filtered),
             "Learning-filtered search returned nothing while unfiltered found it — the node_labels filter does not match the learning facts; filtered: #{inspect(Enum.map(filtered, & &1.fact))}; nodes: #{inspect(node_labels)}"

      lookup = "erl_lookup_#{System.unique_integer([:positive])}"

      assert {:ok, block} = Client.impl().recall(group_id, "Susu", lookup, query)

      lower = String.downcase(block)

      assert lower =~ "vacuum" or lower =~ "schedul" or lower =~ "overlap" or lower =~ "backup",
             "expected recall to surface the ERL lesson about rescheduling the conflicting job; got: #{block}"
    end
  end
end
