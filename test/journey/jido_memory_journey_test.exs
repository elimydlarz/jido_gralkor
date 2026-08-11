defmodule Gralkor.JidoMemoryJourneyTest do
  @moduledoc """
  End-to-end journey test: real PythonX runtime, real graphiti-core, real
  embedded falkordblite. Both sides follow the configured inference roles —
  the Elixir side (distill, interpret, reflect) through `Gralkor.Config.llm_model/0`
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
  alias Gralkor.Reflection.Registry
  alias Gralkor.Search

  @moduletag :journey
  @moduletag timeout: 300_000

  defmodule JourneyOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Memory do
      field(:content, :string, required: true)
    end
  end

  setup_all do
    Application.put_env(:jido_gralkor, :recall_deadline_ms, 60_000)
    on_exit(fn -> Application.delete_env(:jido_gralkor, :recall_deadline_ms) end)

    original_client = Application.get_env(:jido_gralkor, :client)
    original_lenses = Application.get_env(:jido_gralkor, :lenses)
    original_destinations = Application.get_env(:jido_gralkor, :destinations)
    Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)

    Application.put_env(:jido_gralkor, :destinations, [
      [name: "observations", address: "operator/observations", ontology: JourneyOntology]
    ])

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "observations",
        destination: "observations",
        ingestion: Gralkor.Lens.Ingestion.Store
      ]
    ])

    on_exit(fn ->
      case original_client do
        nil -> Application.delete_env(:jido_gralkor, :client)
        mod -> Application.put_env(:jido_gralkor, :client, mod)
      end

      case original_lenses do
        nil -> Application.delete_env(:jido_gralkor, :lenses)
        lenses -> Application.put_env(:jido_gralkor, :lenses, lenses)
      end

      case original_destinations do
        nil -> Application.delete_env(:jido_gralkor, :destinations)
        destinations -> Application.put_env(:jido_gralkor, :destinations, destinations)
      end
    end)

    data_dir =
      Path.join(System.tmp_dir!(), "gralkor_journey_#{System.unique_integer([:positive])}")

    original_data_dir = System.get_env("GRALKOR_DATA_DIR")
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

    flush_callback = App.build_flush_callback({:embedded, data_dir})

    {:ok, _buffer} =
      start_supervised(
        {CaptureBuffer,
         [
           flush_callback: flush_callback,
           lens_flush_callback: App.build_lens_flush_callback(),
           reflections: Registry.configured!()
         ]}
      )

    on_exit(fn ->
      File.rm_rf!(data_dir)

      case original_data_dir do
        nil -> System.delete_env("GRALKOR_DATA_DIR")
        value -> System.put_env("GRALKOR_DATA_DIR", value)
      end
    end)

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
          "manual"
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

  describe "when information is ingested before a declared Reflection runs" do
    test "then the Reflection artefact survives destination storage and full recall", %{
      group_id: group_id
    } do
      session_id = "reflection_#{System.unique_integer([:positive])}"

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
          ],
          "observations",
          [],
          %{tools: [], tool_context: %{session_id: session_id}}
        )

      :ok = Client.impl().flush_and_await(session_id, 60_000)

      search = %Search{
        operator_id: group_id,
        query: "backup vacuum scheduling conflict",
        destinations: ["experiential-learning"],
        result_type: :artefacts,
        max_results: 10
      }

      assert {:ok, [%{artefact: artefact} | _]} =
               eventually_search_reflection(search, 120_000)

      assert artefact.reflection == "erl"
      assert is_binary(artefact.payload["problem_kind"])
      assert is_binary(artefact.payload["approach"])
      assert is_boolean(artefact.payload["success"])
      assert is_binary(artefact.payload["lesson"])
      assert artefact.evidence_ids != []
    end
  end

  defp eventually_search_reflection(_search, budget_ms) when budget_ms <= 0, do: {:ok, []}

  defp eventually_search_reflection(search, budget_ms) do
    case Client.search(search) do
      {:ok, []} ->
        Process.sleep(1_000)
        eventually_search_reflection(search, budget_ms - 1_000)

      result ->
        result
    end
  end
end
