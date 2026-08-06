defmodule JidoGralkor.ContextRotator do
  @moduledoc """
  Memory consolidation for a long-lived Jido agent.

  Rotation = flush the active Gralkor session to long-term memory, then
  install a fresh `Jido.Thread` on the agent (so the next turn runs under
  a new `session_id`) and replace the ReAct strategy's projected context
  with a compacted version (system prompt + summary of pre-rotation turns
  + the most recent N turns verbatim). The agent process is never stopped
  — any async work it supervises survives.

  Consumers call `rotate_now/2` directly to trigger a rotation (e.g. on
  a `/new` chat command). For periodic rotation, wrap `rotate_now/2` in
  a timer loop (a separate GenServer in the consumer, or a Jido sensor).

  This module talks to the AgentServer through `Jido.AgentServer.call/3`
  and `Jido.AgentServer.cast/2` so all state mutations happen inside the
  agent's own process — no parallel state in this module.
  """

  require Logger

  alias Gralkor.Client
  alias Jido.Thread

  @default_flush_timeout_ms 30_000
  @default_keep_last_n 4

  @type opts :: [
          flush_timeout_ms: pos_integer(),
          keep_last_n: non_neg_integer()
        ]

  @doc """
  Rotate the agent's active session immediately.

  On success: the buffered turns are flushed to long-term memory and a
  fresh Jido thread is installed (new session id). The rotated thread is
  seeded with two slices:

    1. The most recent `:keep_last_n` entries that existed BEFORE the
       flush — for short-range conversational continuity (these are
       in long-term memory now; we keep them for the LLM's immediate
       working set).
    2. Any thread entries appended DURING the flush — those represent
       turns that weren't part of the just-flushed batch (an in-flight
       turn arriving while the rotation was running). They're preserved
       so the rotator never drops un-captured work.

  Entries that existed pre-flush and aren't in the `:keep_last_n` tail
  are dropped from the in-memory context — they've been moved to
  long-term memory, recall is the path back.

  Returns `:ok` on success, `{:error, reason}` if the flush fails (in
  which case the active thread and session id are unchanged so the next
  attempt sees the same buffer).

  Options:

    * `:flush_timeout_ms` — timeout passed to `Gralkor.Client.flush_and_await/2`.
      Default `#{@default_flush_timeout_ms}`.
    * `:keep_last_n` — number of most-recent pre-flush entries to retain
      in the rotated thread for continuity. Default
      `#{@default_keep_last_n}`. Pass `0` to drop everything that was
      flushed (preserving only in-flight entries).

  When the agent has no committed thread yet, returns `:ok` without any
  side effects.
  """
  @spec rotate_now(pid(), opts()) :: :ok | {:error, term()}
  def rotate_now(agent_pid, opts \\ []) when is_pid(agent_pid) do
    flush_timeout_ms = Keyword.get(opts, :flush_timeout_ms, @default_flush_timeout_ms)
    keep_last_n = Keyword.get(opts, :keep_last_n, @default_keep_last_n)
    before_install_fn = Keyword.get(opts, :before_install_fn, fn -> :ok end)

    case fetch_thread(agent_pid) do
      {:ok, nil} ->
        :ok

      {:error, reason} ->
        {:error, {:state_read_failed, reason}}

      {:ok, %{id: session_id, entries: pre_flush_entries}} ->
        case safe_flush_and_await(session_id, flush_timeout_ms) do
          :ok ->
            new_session_id = mint_session_id()
            retained_count = length(retain_tail(pre_flush_entries, keep_last_n))
            before_install_fn.()

            case swap_thread(
                   agent_pid,
                   new_session_id,
                   pre_flush_entries,
                   keep_last_n
                 ) do
              {:ok, seed_count} ->
                Logger.info(
                  "[jido_gralkor] context rotated — session:#{session_id}→#{new_session_id} kept:#{retained_count} inflight:#{seed_count - retained_count}"
                )

                :ok

              {:error, reason} ->
                Logger.warning(
                  "[jido_gralkor] context rotator failed to swap thread — session:#{session_id} reason:#{inspect(reason)}"
                )

                {:error, reason}
            end

          {:error, reason} ->
            Logger.warning(
              "[jido_gralkor] context rotator flush failed — session:#{session_id} reason:#{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  defp safe_flush_and_await(session_id, timeout_ms) do
    Client.impl().flush_and_await(session_id, timeout_ms)
  catch
    :exit, reason -> {:error, {:flush_exit, reason}}
  end

  @doc false
  # Pure helper exposed for tests. Computes the rotated thread's seed:
  # the most-recent `keep_last_n` of the pre-flush entries (continuity for
  # what was just moved to long-term memory) followed by any entries
  # appended to the thread during the flush (in-flight turns that weren't
  # part of the just-flushed batch, so they must be preserved).
  @spec compute_seed([map()], [map()], non_neg_integer()) :: [map()]
  def compute_seed(pre_flush_entries, current_entries, keep_last_n) do
    retain_tail(pre_flush_entries, keep_last_n) ++
      new_inflight(pre_flush_entries, current_entries)
  end

  defp new_inflight(pre_flush_entries, current_entries) do
    max_pre_seq = max_seq(pre_flush_entries)

    Enum.filter(current_entries, fn entry ->
      seq = entry_seq(entry)
      is_integer(seq) and seq > max_pre_seq
    end)
  end

  defp max_seq([]), do: -1

  defp max_seq(entries) do
    entries
    |> Enum.map(&entry_seq/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> -1 end)
  end

  defp entry_seq(%{seq: seq}), do: seq
  defp entry_seq(_), do: nil

  defp fetch_thread(agent_pid) do
    case Jido.AgentServer.state(agent_pid) do
      {:ok, server_state} ->
        thread =
          case server_state.agent.state[:__thread__] do
            %Thread{} = thread -> thread
            %{id: id, entries: entries} when is_binary(id) -> %{id: id, entries: entries}
            _ -> nil
          end

        {:ok, thread}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp retain_tail(_entries, 0), do: []

  defp retain_tail(entries, n) when is_list(entries) and is_integer(n) and n > 0 do
    Enum.take(entries, -n)
  end

  defp swap_thread(agent_pid, new_session_id, pre_flush_entries, keep_last_n)
       when is_pid(agent_pid) do
    try do
      updated_state =
        :sys.replace_state(agent_pid, fn server_state ->
          case server_state.agent.state[:__thread__] do
            %{entries: current_entries} when is_list(current_entries) ->
              seed = compute_seed(pre_flush_entries, current_entries, keep_last_n)
              seeded = build_seeded_thread(new_session_id, seed)
              agent = server_state.agent
              agent = %{agent | state: Map.put(agent.state, :__thread__, seeded)}
              %{server_state | agent: agent}

            _other ->
              server_state
          end
        end)

      case updated_state.agent.state[:__thread__] do
        %{id: ^new_session_id, entries: entries} -> {:ok, length(entries)}
        _other -> {:error, :thread_missing_after_flush}
      end
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp build_seeded_thread(new_session_id, []), do: Thread.new(id: new_session_id)

  defp build_seeded_thread(new_session_id, entries) do
    Thread.append(Thread.new(id: new_session_id), entries)
  end

  defp mint_session_id, do: Jido.Util.generate_id()
end
