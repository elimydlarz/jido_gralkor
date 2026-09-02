defmodule Gralkor.Recall do
  @moduledoc """
  Orchestrate one recall call: search the graph and wrap the returned facts in
  a `<gralkor-memory>` block.

  Pure orchestration — the search dependency is passed as a function in
  `opts`. Production wiring lives in `Gralkor.Client.Native`.

  See `test-trees/unit/recall_TEST_TREES.md`.
  """

  require Logger

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

  @type opts :: [
          search_fn: search_fn(),
          max_results: pos_integer(),
          deadline_ms: pos_integer()
        ]

  @spec recall(group_id(), String.t(), session_id(), String.t(), opts()) ::
          {:ok, String.t()} | {:error, :recall_deadline_expired | term()}
  def recall(group_id, agent_name, session_id, query, opts)
      when is_binary(group_id) and is_binary(query) and is_list(opts) do
    raise_if_blank_agent!(agent_name)
    max_results = Keyword.get(opts, :max_results, @default_max_results)
    deadline_ms = Keyword.get(opts, :deadline_ms, @default_deadline_ms)

    log_call(session_id, group_id, query, max_results)
    if test_mode?(), do: Logger.info("[gralkor] [test] recall query: #{query}")

    task =
      Task.async(fn ->
        {:result, do_recall(group_id, query, max_results, opts)}
      end)

    case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:result, {:error, reason}}} ->
        {:error, reason}

      {:ok, {:result, result}} ->
        log_result(result)

        if test_mode?() and result.n_facts > 0,
          do: Logger.info("[gralkor] [test] recall block: #{result.block}")

        {:ok, result.block}

      nil ->
        Logger.warning(
          "[gralkor] recall deadline expired — session:#{session_id} group:#{group_id} after:#{deadline_ms}ms"
        )

        {:error, :recall_deadline_expired}
    end
  end

  # ── internal ────────────────────────────────────────────────

  defp do_recall(group_id, query, max_results, opts) do
    search_fn = Keyword.fetch!(opts, :search_fn)

    t0 = System.monotonic_time(:millisecond)
    {search_result, search_ms} = time(fn -> search_fn.(group_id, query, max_results) end)

    case search_result do
      {:error, reason} ->
        {:error, reason}

      {:ok, facts} when is_list(facts) ->
        {body, n_facts} = present(facts)

        %{
          block: wrap(body),
          n_facts: n_facts,
          search_ms: search_ms,
          total_ms: System.monotonic_time(:millisecond) - t0
        }
    end
  end

  defp present([]), do: {@no_facts_body, 0}
  defp present(facts), do: {Enum.join(facts, "\n"), length(facts)}

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
      "[gralkor] recall result — #{result.n_facts} facts blockChars:#{String.length(result.block)} #{result.total_ms}ms (search:#{result.search_ms})"
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
