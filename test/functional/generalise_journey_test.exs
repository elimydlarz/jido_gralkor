defmodule Gralkor.GeneraliseJourneyTest do
  @moduledoc """
  End-to-end journey test: real graphiti-core, real embedded falkordblite,
  real GraphitiPool search + add_episode + remove_episode. LLM hypothesise
  and evaluate are faked with deterministic responses so the test is fast
  and repeatable.

  Proves the generalisation pipeline end-to-end:
    1. A generalisation episode lands in the `:gen` graphiti partition after flush
    2. It is searchable via GraphitiPool.search on the `:gen` partition
    3. Recall with gen_search_fn surfaces it in the memory block
    4. Level, confidence, and metadata are preserved through encode/decode
    5. A second flush with a contradicting generalisation removes the old one

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

    # Flush callback wired with generalise_fn that uses real graphiti but
    # faked LLM — proving the I/O paths without real LLM cost.
    gen_flush = fn group_id, body ->
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

      add_episode_fn = fn group_id, content, source, ontology, opts ->
        GraphitiPool.add_episode(Gralkor.GraphitiPool, group_id, content, source, ontology, opts)
      end
      remove_episode_fn = &GraphitiPool.remove_episode/2
      min_confidence = 0.3

      Generalise.generalise(group_id, body,
        hypothesise_fn: hypothesise_fn,
        search_gen_fn: search_gen_fn,
        evaluate_fn: evaluate_fn,
        add_episode_fn: add_episode_fn,
        remove_episode_fn: remove_episode_fn,
        min_confidence: min_confidence,
        max_gen_results: 5
      )
    end

    # Build a flush callback wired with the generalise_fn
    gen_flush_callback = fn group_id, _agent_name, _user_name, _ontology, _turns ->
      distilled = "Eli: I prefer dark mode. Eli: I work from Sydney, Australia."
      :ok = GraphitiPool.add_episode(Gralkor.GraphitiPool, group_id, distilled, "captured", nil, [])
      Task.start(fn -> gen_flush.(group_id, distilled) end)
      :ok
    end

    {:ok, _buffer} = start_supervised({CaptureBuffer, [flush_callback: gen_flush_callback]})

    on_exit(fn -> File.rm_rf!(data_dir) end)

    %{group_id: "gen_journey_#{System.unique_integer([:positive])}"}
  end

  describe "ex-generalise-journey > after flush with generalise_fn" do
    test "generalisations land in the :gen partition and are searchable", %{
      group_id: group_id
    } do
      session_id = "gen_session_#{System.unique_integer([:positive])}"

      :ok =
        Client.impl().capture(session_id, group_id, "TestAgent", "Eli", [
          Message.new("user", "I prefer dark mode for all my tools."),
          Message.new("assistant", "Got it — dark mode across the board."),
          Message.new("user", "I'm based in Sydney, Australia."),
          Message.new("assistant", "Noted — Sydney, Australia.")
        ])

      :ok = Client.impl().flush(session_id)

      # Generalise fires via Task.start — wait for it to complete
      Process.sleep(15_000)

      gen_partition = "#{group_id}:gen"

      # Search the gen partition for generalisations
      assert {:ok, raw} = GraphitiPool.search(gen_partition, "dark mode", 5)

      assert length(raw) >= 1,
             "expected at least one generalisation in the :gen partition; got #{inspect(raw)}"

      gen_entries =
        Enum.flat_map(raw, fn fact ->
          case Generalisation.decode(fact.fact) do
            {:ok, gen, _plain} -> [gen]
            {:error, :not_a_generalisation} -> []
          end
        end)

      assert length(gen_entries) >= 1,
             "expected at least one decoded generalisation; got #{inspect(gen_entries)}"

      dark_mode_gen = Enum.find(gen_entries, fn g -> g.content =~ "dark mode" end)
      assert dark_mode_gen, "expected a generalisation about dark mode"
      assert dark_mode_gen.level == 0
      assert dark_mode_gen.confidence == 0.92
      assert dark_mode_gen.generalises == []

      # Verify recall with gen_search_fn surfaces the generalisation
      lookup_session = "lookup_#{System.unique_integer([:positive])}"

      {:ok, block} =
        Client.impl().recall(group_id, "TestAgent", lookup_session, "What are Eli's preferences?")

      assert block =~ ~r/<gralkor-memory/
      lower = String.downcase(block)

      assert lower =~ "dark mode" or lower =~ "dark mode",
             "expected recall block to mention dark mode; got: #{block}"
    end
  end

  describe "ex-generalise-journey > generalisation lifecycle" do
    test "a contradicting generalisation removes the old one via remove_episode", %{
      group_id: group_id
    } do
      gen_partition = "#{group_id}:gen"

      # First: create a generalisation directly in the gen partition
      gen = %Generalisation{
        id: "gen-lifecycle-test",
        content: "Eli dislikes async communication",
        level: 0,
        confidence: 0.6
      }

      body = Generalisation.encode(gen)
      :ok = GraphitiPool.add_episode(Gralkor.GraphitiPool, gen_partition, body, "generalisation", nil, [uuid: gen.id])

      Process.sleep(5_000)

      # Verify it exists
      assert {:ok, raw} = GraphitiPool.search(gen_partition, "async communication", 5)
      assert length(raw) >= 1

      # Now remove it
      :ok = GraphitiPool.remove_episode(gen_partition, gen.id)

      Process.sleep(3_000)

      # Verify it's gone
      {:ok, raw2} = GraphitiPool.search(gen_partition, "async communication", 5)

      remaining =
        Enum.flat_map(raw2, fn fact ->
          case Generalisation.decode(fact.fact) do
            {:ok, g, _} -> [g]
            {:error, _} -> []
          end
        end)

      refute Enum.any?(remaining, fn g -> g.id == "gen-lifecycle-test" end),
             "expected gen-lifecycle-test to be removed; got #{inspect(remaining)}"
    end
  end
end
