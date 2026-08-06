defmodule Gralkor.Recall do
  @moduledoc """
  Orchestrate one recall call: search the graph, interpret the hits against
  the buffered conversation, wrap the result in a `<gralkor-memory>` block.

  Pure orchestration — all dependencies (search, interpret LLM call, turns
  source) are passed as functions in `opts`. Production wiring lives in
  `Gralkor.Client.Native`.

  See `test-trees/unit/recall_TEST_TREES.md`.
  """

  require Logger

  alias Gralkor.Client
  alias Gralkor.Interpret
  alias Gralkor.Message

  @memory_envelope_open ~s(<gralkor-memory trust="untrusted">)
  @memory_envelope_close "</gralkor-memory>"
  @further_querying_instruction "Search memory (up to 3 times, diverse queries) if you need more detail."
  @no_facts_body "No relevant memories found."
  @default_max_results 10
  @default_deadline_ms 12_000

  @type group_id :: String.t()
  @type session_id :: String.t() | nil
  @type search_fn ::
          (group_id(), query :: String.t(), max :: pos_integer() ->
             {:ok, [String.t()]} | {:error, term()})
  @type interpret_fn ::
          (String.t(), pos_integer() -> {:ok, [String.t()]} | {:error, term()})
  @type turns_fn :: (String.t() -> [[Message.t()]])

  @type opts :: [
          search_fn: search_fn(),
          gen_search_fn: search_fn(),
          learning_search_fn: search_fn(),
          interpret_fn: interpret_fn(),
          turns_fn: turns_fn(),
          max_results: pos_integer(),
          deadline_ms: pos_integer(),
          output_token_budget: pos_integer()
        ]

  @spec recall(group_id(), String.t(), session_id(), String.t(), opts()) ::
          {:ok, String.t()} | {:error, :recall_deadline_expired | term()}
  def recall(group_id, agent_name, session_id, query, opts)
      when is_binary(group_id) and is_binary(query) and is_list(opts) do
    raise_if_blank_agent!(agent_name)
    sanitized = Client.sanitize_group_id(group_id)
    max_results = Keyword.get(opts, :max_results, @default_max_results)
    deadline_ms = Keyword.get(opts, :deadline_ms, @default_deadline_ms)

    log_call(session_id, sanitized, query, max_results)
    if test_mode?(), do: Logger.info("[gralkor] [test] recall query: #{query}")

    task =
      Task.async(fn ->
        do_recall(sanitized, agent_name, session_id, query, max_results, opts)
      end)

    case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, result} ->
        log_result(result)

        if test_mode?() and result.n_facts > 0,
          do: Logger.info("[gralkor] [test] recall block: #{result.block}")

        {:ok, result.block}

      nil ->
        Logger.warning(
          "[gralkor] recall deadline expired — session:#{session_id} group:#{sanitized} after:#{deadline_ms}ms"
        )

        {:error, :recall_deadline_expired}
    end
  end

  # ── internal ────────────────────────────────────────────────

  defp do_recall(sanitized_group, agent_name, session_id, query, max_results, opts) do
    search_fn = Keyword.fetch!(opts, :search_fn)
    gen_search_fn = Keyword.get(opts, :gen_search_fn)
    learning_search_fn = Keyword.get(opts, :learning_search_fn)
    interpret_fn = Keyword.fetch!(opts, :interpret_fn)
    turns_fn = Keyword.fetch!(opts, :turns_fn)

    t0 = System.monotonic_time(:millisecond)
    conversation = load_conversation(session_id, turns_fn)

    aux_max = max(div(max_results, 3), 1)

    # The main search is required; gen search and the learning search are
    # optional auxiliaries — each runs in parallel and degrades to [] on
    # failure or timeout, so recall always proceeds on the regular facts.
    # The learning search is seeded with the RAW user query (no LLM
    # classification) and is expected to bake in the
    # SearchFilters(node_labels: ["Learning"]) filter at the client wiring
    # boundary (Gralkor.Client.Native), so only Learning-typed episodes are
    # returned.
    main_task = Task.async(fn -> search_fn.(sanitized_group, query, max_results) end)

    gen_task =
      if gen_search_fn do
        Task.async(fn -> gen_search_fn.(sanitized_group, query, aux_max) end)
      end

    learning_task =
      if learning_search_fn do
        Task.async(fn -> learning_search_fn.(sanitized_group, query, aux_max) end)
      end

    {search_result, search_ms} = time(fn -> Task.await(main_task, :infinity) end)

    case search_result do
      {:error, reason} ->
        shutdown_aux(gen_task)
        shutdown_aux(learning_task)
        {:error, reason}

      {:ok, facts} when is_list(facts) ->
        combined =
          facts ++
            await_aux(gen_task, "gen search") ++
            await_aux(learning_task, "learning search")

        {body, n_facts, interpret_ms} =
          interpret_combined(combined, conversation, query, interpret_fn, agent_name, opts)

        %{
          block: wrap(body),
          n_facts: n_facts,
          search_ms: search_ms,
          interpret_ms: interpret_ms,
          total_ms: System.monotonic_time(:millisecond) - t0
        }
    end
  end

  defp shutdown_aux(nil), do: :ok
  defp shutdown_aux(task), do: Task.shutdown(task, :brutal_kill)

  defp await_aux(nil, _label), do: []

  defp await_aux(task, label) do
    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, facts}} when is_list(facts) ->
        if test_mode?(),
          do:
            Logger.info(
              "[gralkor] [test] recall #{label} — #{length(facts)} result(s): #{inspect(facts)}"
            )

        facts

      other ->
        Logger.warning("[gralkor] recall #{label} failed: #{inspect(other)}")
        []
    end
  end

  defp interpret_combined([], _conversation, _query, _interpret_fn, _agent_name, _opts),
    do: {@no_facts_body, 0, 0}

  defp interpret_combined(facts, conversation, query, interpret_fn, agent_name, opts) do
    facts_text = format_facts(facts)

    interpret_opts =
      case Keyword.fetch(opts, :output_token_budget) do
        {:ok, budget} -> [output_token_budget: budget]
        :error -> []
      end

    {relevant, ms} =
      time(fn ->
        Interpret.interpret_facts(
          conversation,
          query,
          facts_text,
          interpret_fn,
          agent_name,
          interpret_opts
        )
      end)

    case relevant do
      [] -> {@no_facts_body, 0, ms}
      list -> {Enum.join(list, "\n"), length(list), ms}
    end
  end

  defp load_conversation(nil, _turns_fn), do: []

  defp load_conversation(session_id, turns_fn) do
    session_id |> turns_fn.() |> List.flatten()
  end

  defp format_facts(facts), do: Enum.join(facts, "\n")

  defp wrap(body) do
    @memory_envelope_open <>
      "\n" <>
      body <>
      "\n\n" <>
      @further_querying_instruction <>
      "\n" <>
      @memory_envelope_close
  end

  defp time(fun) do
    t0 = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - t0}
  end

  defp log_call(session_id, group, query, max) do
    Logger.info(
      "[gralkor] recall — session:#{session_id} group:#{group} queryChars:#{String.length(query)} max:#{max}"
    )
  end

  defp log_result(result) do
    Logger.info(
      "[gralkor] recall result — #{result.n_facts} facts blockChars:#{String.length(result.block)} #{result.total_ms}ms (search:#{result.search_ms} interpret:#{result.interpret_ms})"
    )
  end

  defp test_mode?, do: Application.get_env(:jido_gralkor, :test, false)

  defp raise_if_blank_agent!(name) when is_binary(name) do
    if String.trim(name) == "" do
      raise ArgumentError, "agent_name must be a non-blank string, got #{inspect(name)}"
    end

    :ok
  end

  defp raise_if_blank_agent!(other) do
    raise ArgumentError, "agent_name must be a non-blank string, got #{inspect(other)}"
  end
end
