defmodule Gralkor.GeneraliseJourneyTest do
  @moduledoc """
  End-to-end journey test: real graphiti-core, real embedded falkordblite,
  real GraphitiPool search + add_episode. LLM hypothesise and evaluate are
  faked with deterministic responses so the test is fast and repeatable.

  Proves:
    1. The generalise pipeline runs after flush and saves episodes to a
       `_gen` graphiti group
    2. The generalisation content is searchable via GraphitiPool.search
       against the `_gen` group
    3. A generalisation added directly to the `_gen` group via
       add_episode is findable via search

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

  defp search_until(_partition, _query, _min, 0) do
    []
  end

  defp search_until(group, query, min, budget_ms) do
    case GraphitiPool.search(group, query, 5) do
      {:ok, raw} when length(raw) >= min ->
        raw

      _ ->
        Process.sleep(3_000)
        search_until(group, query, min, max(budget_ms - 3_000, 0))
    end
  end

  describe "ex-generalise-journey > after flush with generalise_fn" do
    test "the generalise pipeline saves generalisations to the _gen group" do
      group_id = "gen_after_flush_#{System.unique_integer([:positive])}"
      gen_partition = "#{group_id}_gen"

      # Inline flush callback: distill and generalise in one step
      gen_flush_callback = fn gid, _agent_name, _user_name, _ontology, _turns ->
        distilled = "Eli: I prefer dark mode. Eli: I work from Sydney, Australia."
        :ok = GraphitiPool.add_episode(Gralkor.GraphitiPool, gid, distilled, "captured", nil, [])

        hypothesise_fn = fn _prompt ->
          {:ok, [%{content: "Eli consistently prefers dark mode", confidence: 0.92}]}
        end

        search_gen_fn = fn part, query, max_results ->
          case GraphitiPool.search(part, query, max_results) do
            {:ok, raw} -> {:ok, Enum.map(raw, &Map.get(&1, :fact))}
            {:error, _} = err -> err
          end
        end

        evaluate_fn = fn _prompt ->
          {:ok,
           [
             %{
               hypothesis_index: 0,
               action: "save",
               confidence: 0.92,
               content: "Eli consistently prefers dark mode"
             }
           ]}
        end

        Task.start(fn ->
          Generalise.generalise(gid, distilled,
            hypothesise_fn: hypothesise_fn,
            search_gen_fn: search_gen_fn,
            evaluate_fn: evaluate_fn,
            add_episode_fn: fn _gid, content, source, ontology, opts ->
              GraphitiPool.add_episode(
                Gralkor.GraphitiPool,
                gen_partition,
                content,
                source,
                ontology,
                opts
              )
            end,
            remove_episode_fn: fn _gid, uuid ->
              GraphitiPool.remove_episode(gen_partition, uuid)
            end,
            min_confidence: 0.3,
            max_gen_results: 5
          )
        end)

        :ok
      end

      {:ok, _buffer} = start_supervised({CaptureBuffer, [flush_callback: gen_flush_callback]})

      session_id = "gen_session_#{System.unique_integer([:positive])}"

      :ok =
        Client.impl().capture(session_id, group_id, "TestAgent", "Eli", [
          Message.new("user", "I prefer dark mode for all my tools."),
          Message.new("assistant", "Got it — dark mode across the board.")
        ])

      :ok = Client.impl().flush(session_id)

      # Wait for generalise to complete and graphiti to re-index
      raw = search_until(gen_partition, "dark mode", 1, 40_000)

      assert length(raw) >= 1,
             "expected at least one fact in the _gen group; got #{inspect(raw)}"

      facts_text = Enum.map(raw, &Map.get(&1, :fact)) |> Enum.join("\n")

      assert facts_text =~ "dark mode",
             "expected search results to mention dark mode; got: #{facts_text}"
    end
  end

  describe "ex-generalise-journey > direct add_episode to _gen group" do
    test "a generalisation stored via add_episode is findable via search" do
      group_id = "gen_direct_#{System.unique_integer([:positive])}"
      gen_partition = "#{group_id}_gen"

      gen = %Generalisation{
        id: "gen-direct-add",
        content: "Eli uses a standing desk and prefers it over sitting",
        level: 0,
        confidence: 0.8
      }

      body = Generalisation.encode(gen)

      :ok =
        GraphitiPool.add_episode(
          Gralkor.GraphitiPool,
          gen_partition,
          body,
          "generalisation",
          nil,
          []
        )

      raw = search_until(gen_partition, "standing desk", 1, 60_000)
      assert length(raw) >= 1, "expected at least one search result; got #{inspect(raw)}"

      facts_text = Enum.map(raw, &Map.get(&1, :fact)) |> Enum.join("\n")

      assert facts_text =~ "standing" or facts_text =~ "desk",
             "expected search results to mention the generalisation; got: #{facts_text}"
    end
  end
end
