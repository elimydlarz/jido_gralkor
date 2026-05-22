defmodule Gralkor.JidoMemoryJourneyTest do
  @moduledoc """
  End-to-end functional test: real PythonX runtime, real graphiti-core, real
  embedded falkordblite, real Gemini via req_llm and via graphiti's bundled
  clients. Reads `GOOGLE_API_KEY` from `.env` (loaded by `test_helper.exs`).

  Reifies the `jido-memory-journey` tree.
  """

  use ExUnit.Case, async: false

  alias Gralkor.CaptureBuffer
  alias Gralkor.Client
  alias Gralkor.Client.Native
  alias Gralkor.Config
  alias Gralkor.Distill
  alias Gralkor.GraphitiPool
  alias Gralkor.Message

  @moduletag :functional
  @moduletag timeout: 300_000

  setup_all do
    if System.get_env("GOOGLE_API_KEY") in [nil, ""] do
      {:skip, "GOOGLE_API_KEY not set; copy .env.example to .env"}
    else
      # Real Gemini calls + interpret can run 10-15s; production keeps the
      # 12s deadline because that's the consumer's tolerance, but functional
      # tests assert semantic correctness, not latency.
      Application.put_env(:gralkor_ex, :recall_deadline_ms, 60_000)
      on_exit(fn -> Application.delete_env(:gralkor_ex, :recall_deadline_ms) end)

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
             llm_model: Config.llm_model(),
             embedder_model: Config.embedder_model(),
             interpret_fn: Native.interpret_callback(),
             warmup: false
           ]}
        )

      flush_callback = fn group_id, agent_name, user_name, turns ->
        body = Distill.format_transcript(turns, Native.distill_callback(), agent_name, user_name)

        if body == "" do
          :ok
        else
          GraphitiPool.add_episode(group_id, body, "captured")
        end
      end

      {:ok, _buffer} = start_supervised({CaptureBuffer, [flush_callback: flush_callback]})

      on_exit(fn -> File.rm_rf!(data_dir) end)

      %{group_id: "journey_#{System.unique_integer([:positive])}"}
    end
  end

  describe "jido-memory-journey > round-trip" do
    test "memory_add stores a fact, recall surfaces it under the same group_id", %{
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
          Message.new("assistant", "Noted — Eli's favourite colour is teal and Eli drives a blue Subaru Outback.")
        ])

      :ok = Client.impl().flush(session_id)

      # Give the buffer flush + distill + graphiti add_episode some time to land.
      Process.sleep(45_000)

      lookup_session = "lookup_#{System.unique_integer([:positive])}"

      assert {:ok, block} =
               Client.impl().recall(group_id, "TestAgent", lookup_session, "What car does Eli drive?")

      lower = String.downcase(block)

      assert lower =~ "subaru" or lower =~ "outback",
             "expected recall to surface a fact about the car; got: #{block}"
    end
  end
end
