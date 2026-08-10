defmodule Gralkor.JidoMemoryJourneyTest do
  @moduledoc """
  End-to-end journey test: real PythonX runtime, real graphiti-core, real
  embedded falkordblite. Both sides follow the configured inference roles —
  the Elixir side (distill, interpret, learn) through `Gralkor.Config.llm_model/0`
  and the Python-side graphiti clients (entity/edge extraction, embeddings,
  reranker) through the same `GRALKOR_LLM_MODEL` / `GRALKOR_EMBEDDER_MODEL`
  specs — so the credential this suite needs is whichever provider those
  select.

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
           llm_model: Gralkor.Config.llm_model(),
           embedder_model: Gralkor.Config.embedder_model(),
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

  describe "when a fact is written before a fresh-session recall" do
    test "then the untrusted memory response semantically references the written fact", %{
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

  describe "when a captured turn is flushed before a fresh-session recall" do
    test "then the turn becomes recallable under the same operator group", %{
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

  describe "when a solved turn is flushed with learning enabled" do
    test "then its lesson survives Learning-node retrieval and full recall", %{
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

      # Give the buffer flush + ex-learn LLM call + graphiti add_episode (entity
      # extraction populates the Learning node) time to land.
      Process.sleep(60_000)

      query = "how do I resolve a scheduling conflict between two jobs that causes lock timeouts?"

      lesson_terms = ["vacuum", "schedul", "overlap", "backup", "04:00", "4:00"]

      # The ERL-specific contract: the learning was extracted into a Learning
      # custom-entity NODE (add_episode + Gralkor.LearningEntity), and NODE search
      # filtered to node_labels: ["Learning"] retrieves it. This is the path the
      # client's learning_search_fn uses — isolated from the unfiltered main
      # search, which would surface the episode regardless.
      {:ok, learning_nodes} =
        GraphitiPool.search_nodes(GraphitiPool, group_id, query, 5, node_labels: ["Learning"])

      require Logger
      Logger.info("[erl] learning nodes (#{length(learning_nodes)}): #{inspect(learning_nodes)}")

      assert learning_nodes != [],
             "node search filtered to ['Learning'] returned no nodes — the Learning entity was not extracted"

      node_text =
        learning_nodes
        |> Enum.map(fn n -> "#{n.name} #{n.summary} #{inspect(n.attributes)}" end)
        |> Enum.join("\n")
        |> String.downcase()

      assert Enum.any?(lesson_terms, &String.contains?(node_text, &1)),
             "the Learning node did not carry the lesson; got: #{inspect(learning_nodes)}"

      # End-to-end: full recall surfaces the lesson (the learning search feeds the
      # combined facts into interpretation).
      lookup = "erl_lookup_#{System.unique_integer([:positive])}"

      assert {:ok, block} = Client.impl().recall(group_id, "Susu", lookup, query)

      lower = String.downcase(block)

      assert Enum.any?(lesson_terms, &String.contains?(lower, &1)),
             "expected recall to surface the ERL lesson about rescheduling the conflicting job; got: #{block}"
    end
  end

end
