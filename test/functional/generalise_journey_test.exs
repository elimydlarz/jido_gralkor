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
           llm_model: Gralkor.Config.llm_model(),
           embedder_model: Gralkor.Config.embedder_model(),
           warmup: false
         ]}
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)

    :ok
  end

  defp memories_until(_group_id, _query, 0), do: []

  defp memories_until(group_id, query, budget_ms) do
    case memories(group_id, query) do
      [] ->
        Process.sleep(3_000)
        memories_until(group_id, query, max(budget_ms - 3_000, 0))

      found ->
        found
    end
  end

  # A generalisation naming one subject is extracted as a node with no edge, so
  # what the group can surface for a query is its facts and its nodes together.
  defp memories(group_id, query) do
    {:ok, edges} = GraphitiPool.search(group_id, query, 5)
    {:ok, nodes} = GraphitiPool.search_nodes(GraphitiPool, group_id, query, 5)

    Enum.map(edges, & &1.fact) ++
      Enum.map(nodes, fn node -> "#{node.name} — #{node.summary}" end)
  end

  # Says whether a group that surfaced nothing is empty (the write never landed)
  # or holds an episode nothing was extracted from.
  defp graph_contents(group_id) do
    instance = GraphitiPool.for(group_id)

    {raw, _} =
      Pythonx.eval(
        """
        import asyncio
        records, _, _ = asyncio._gralkor_run(
            g.driver.execute_query("MATCH (n) RETURN labels(n) AS labels, n.name AS name, n.group_id AS group_id")
        )
        [f"{r['labels']} name={r['name']} group_id={r['group_id']}" for r in records]
        """,
        %{"g" => instance}
      )

    raw |> Pythonx.decode() |> Enum.map(&to_string/1)
  end

  describe "ex-generalise-journey > after flush with generalise_fn" do
    test "the generalise pipeline saves generalisations to the _gen group" do
      group_id = "gen_after_flush_#{System.unique_integer([:positive])}"
      gen_group_id = "#{group_id}_gen"
      test_pid = self()

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
              result =
                GraphitiPool.add_episode(
                  Gralkor.GraphitiPool,
                  gen_group_id,
                  content,
                  source,
                  ontology,
                  opts
                )

              send(test_pid, {:generalisation_written, result})
              result
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

      assert_receive {:generalisation_written, :ok}, 120_000

      # Wait for graphiti to re-index the written generalisation
      found = memories_until(gen_group_id, "dark mode", 40_000)

      assert found != [],
             "expected the _gen group to surface the written generalisation; got nothing"

      text = Enum.join(found, "\n")

      assert text =~ "dark mode",
             "expected search results to mention dark mode; got: #{text}"
    end
  end

  describe "ex-generalise-journey > direct add_episode to _gen group" do
    test "a generalisation stored via add_episode is findable via search" do
      group_id = "gen_direct_#{System.unique_integer([:positive])}"
      gen_group_id = "#{group_id}_gen"

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
          gen_group_id,
          body,
          "generalisation",
          nil,
          []
        )

      found = memories_until(gen_group_id, "standing desk", 60_000)
      assert found != [], "expected the _gen group to surface the stored generalisation"

      text = Enum.join(found, "\n")

      assert text =~ "standing" or text =~ "desk",
             "expected search results to mention the generalisation; got: #{text}"
    end
  end
end
