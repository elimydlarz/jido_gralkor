defmodule Gralkor.GeneraliseJourneyTest do
  @moduledoc """
  End-to-end journey test: real graphiti-core, real embedded falkordblite,
  real GraphitiPool search + add_episode. LLM hypothesise and evaluate are
  faked with deterministic responses so the test is fast and repeatable.

  Proves the generalisation pipeline end-to-end:
    1. A generalisation episode lands in the `_gen` graphiti partition after flush
    2. It is searchable via GraphitiPool.search on the `_gen` partition
    3. The generalisation's plain content appears in extracted edge facts
    4. A separate generalisation added directly to the `_gen` partition is findable

  Reifies the `ex-generalise-journey` tree.
  """

  use ExUnit.Case, async: false

  alias Gralkor.CaptureBuffer
  alias Gralkor.Client
  alias Gralkor.Generalisation
  alias Gralkor.Generalise
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
      Path.join(System.tmp_dir!(), "gralkor_gen_journey_#{System.unique_integer([:positive])}")

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
           warmup: false
         ]}
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)

    :ok
  end

  defp build_gen_flush_callback do
    fn group_id, _agent_name, _user_name, _ontology, _turns ->
      distilled = "Eli: I prefer dark mode. Eli: I work from Sydney, Australia."

      :ok = GraphitiPool.add_episode(Gralkor.GraphitiPool, group_id, distilled, "captured", nil, [])

      hypothesise_fn = fn _prompt ->
        {:ok, [
          %{content: "Eli consistently prefers dark mode across all tools", confidence: 0.92},
          %{content: "Eli works from Sydney, Australia", confidence: 0.88}
        ]}
      end

      search_gen_fn = fn partition, query, max_results ->
        case GraphitiPool.search(partition, query, max_results) do
          {:ok, raw} -> {:ok, Enum.map(raw, &Map.get(&1, :fact))}
          {:error, _} = err -> err
        end
      end

      evaluate_fn = fn _prompt ->
        {:ok, [
          %{
            hypothesis_index: 0,
            action: "save",
            confidence: 0.92,
            content: "Eli consistently prefers dark mode across all tools"
          },
          %{
            hypothesis_index: 1,
            action: "save",
            confidence: 0.88,
            content: "Eli works from Sydney, Australia"
          }
        ]}
      end

      gen_partition = "#{group_id}_gen"

      Task.start(fn ->
        Generalise.generalise(group_id, distilled,
          hypothesise_fn: hypothesise_fn,
          search_gen_fn: search_gen_fn,
          evaluate_fn: evaluate_fn,
          add_episode_fn: fn gid, content, source, ontology, opts ->
            GraphitiPool.add_episode(Gralkor.GraphitiPool, gen_partition, content, source, ontology, opts)
          end,
          remove_episode_fn: fn gid, uuid -> GraphitiPool.remove_episode(gen_partition, uuid) end,
          min_confidence: 0.3,
          max_gen_results: 5
        )
      end)

      :ok
    end
  end

  defp search_until(_partition, _query, _min, 0) do
    []
  end

  defp search_until(partition, query, min, budget_ms) do
    case GraphitiPool.search(partition, query, 5) do
      {:ok, raw} when length(raw) >= min -> raw
      _ ->
        Process.sleep(3_000)
        search_until(partition, query, min, max(budget_ms - 3_000, 0))
    end
  end

  describe "ex-generalise-journey > after flush with generalise_fn" do
    test "generalisations land in the _gen partition and are searchable" do
      group_id = "gen_journey_#{System.unique_integer([:positive])}"

      # Wire a flush callback that runs the generalise pipeline
      gen_flush_callback = build_gen_flush_callback()
      {:ok, _buffer} = start_supervised({CaptureBuffer, [flush_callback: gen_flush_callback]})

      session_id = "gen_session_#{System.unique_integer([:positive])}"

      :ok =
        Client.impl().capture(session_id, group_id, "TestAgent", "Eli", [
          Message.new("user", "I prefer dark mode for all my tools."),
          Message.new("assistant", "Got it — dark mode across the board."),
          Message.new("user", "I'm based in Sydney, Australia."),
          Message.new("assistant", "Noted — Sydney, Australia.")
        ])

      :ok = Client.impl().flush(session_id)

      gen_partition = "#{group_id}_gen"
      raw = search_until(gen_partition, "dark mode", 1, 40_000)

      assert length(raw) >= 1,
             "expected at least one fact in the _gen partition; got #{inspect(raw)}"

      facts_text = Enum.map(raw, &Map.get(&1, :fact)) |> Enum.join("\n")
      assert facts_text =~ "dark mode",
             "expected search results to mention dark mode; got: #{facts_text}"

      # Verify recall finds the generalisation content
      lookup_session = "lookup_#{System.unique_integer([:positive])}"

      {:ok, block} =
        Client.impl().recall(group_id, "TestAgent", lookup_session, "What are Eli's preferences?")

      assert block =~ ~r/<gralkor-memory/
      assert String.downcase(block) =~ "dark mode",
             "expected recall block to mention dark mode; got: #{block}"
    end
  end

  describe "ex-generalise-journey > generalisation lifecycle" do
    test "a generalisation stored via add_episode is findable via search" do
      group_id = "gen_lifecycle_#{System.unique_integer([:positive])}"
      gen_partition = "#{group_id}_gen"

      # Force construction of the _gen partition's graphiti instance so
      # indices are built before searching.
      GraphitiPool.for(Gralkor.GraphitiPool, gen_partition)
      Process.sleep(3_000)

      gen = %Generalisation{
        id: "gen-journey-add",
        content: "Eli consistently arrives at meetings 5 minutes early",
        level: 0,
        confidence: 0.75
      }

      body = Generalisation.encode(gen)
      :ok = GraphitiPool.add_episode(Gralkor.GraphitiPool, gen_partition, body, "generalisation", nil, [])

      raw = search_until(gen_partition, "meetings early", 1, 40_000)
      assert length(raw) >= 1, "expected at least one search result; got #{inspect(raw)}"

      facts_text = Enum.map(raw, &Map.get(&1, :fact)) |> Enum.join("\n")
      assert facts_text =~ "meetings" or facts_text =~ "early",
             "expected search results to mention the generalisation; got: #{facts_text}"
    end
  end
end
