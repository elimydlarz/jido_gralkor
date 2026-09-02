defmodule Gralkor.CaptureBuffer do
  @moduledoc """
  In-flight conversation buffer keyed by `session_id`.

  Holds turns until an explicit flush — session lifetime is owned by the
  consumer; there is no idle-flush policy. On `flush/1` (or shutdown via
  `flush_all/0` from `terminate/2`), the buffered turns are handed to the
  configured `flush_callback` with retry: server-internal failures get the
  configured backoff (default 1s/2s/4s); contract errors (4xx) and
  upstream-LLM errors drop without retry.

  See `test-trees/unit/capture-buffer_TEST_TREES.md`.
  """

  use GenServer

  require Logger

  @default_retries [1_000, 2_000, 4_000]
  # ── Public API ──────────────────────────────────────────────

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: :infinity}
  end

  @doc """
  Append one turn (a list of `Gralkor.Message`) to the session's buffer.

  `agent_name` is required and non-blank — it is bound on first append for
  the session and any later append with a different `agent_name`,
  `user_name`, or `group_id` raises `ArgumentError`.

  `user_name` is required and non-blank — used at flush time to label
  user lines in the rendered transcript so graphiti's entity extraction
  produces a named user node rather than collapsing every user into a
  generic "User" entity.
  """
  def append(session_id, group_id, agent_name, user_name, ontology, msgs)
      when is_binary(session_id) and is_binary(group_id) and is_list(msgs) do
    raise_if_blank!(:agent_name, agent_name)
    raise_if_blank!(:user_name, user_name)

    case GenServer.call(
           __MODULE__,
           {:append, session_id, group_id, agent_name, user_name, ontology, msgs}
         ) do
      :ok ->
        :ok

      {:group_mismatch, group_id, other_group} ->
        raise ArgumentError,
              "session #{inspect(session_id)} is bound to group #{inspect(other_group)}; " <>
                "refusing to append under group #{inspect(group_id)}"

      {:agent_mismatch, new_agent, bound_agent} ->
        raise ArgumentError,
              "session #{inspect(session_id)} is bound to agent #{inspect(bound_agent)}; " <>
                "refusing to append under agent #{inspect(new_agent)}"

      {:user_mismatch, new_user, bound_user} ->
        raise ArgumentError,
              "session #{inspect(session_id)} is bound to user #{inspect(bound_user)}; " <>
                "refusing to append under user #{inspect(new_user)}"

      {:ontology_mismatch, new_ontology, bound_ontology} ->
        raise ArgumentError,
              "session #{inspect(session_id)} is bound to ontology #{inspect(bound_ontology)}; " <>
                "refusing to append under ontology #{inspect(new_ontology)}"

      {:capture_mode_mismatch, :lens, :legacy} ->
        raise ArgumentError,
              "session #{inspect(session_id)} already holds Lens-selected turns; " <>
                "refusing to append without a Lens"
    end
  end

  def append_lens(session_id, operator_id, agent_name, user_name, lens, msgs)
      when is_binary(session_id) and is_list(msgs) do
    append_lenses(session_id, operator_id, agent_name, user_name, [lens], msgs)
  end

  def append_lenses(session_id, operator_id, agent_name, user_name, lenses, msgs)
      when is_binary(session_id) and is_list(lenses) and
             is_list(msgs) do
    raise_if_blank!(:operator_id, operator_id)
    raise_if_blank!(:agent_name, agent_name)
    raise_if_blank!(:user_name, user_name)

    if lenses == [], do: raise(ArgumentError, "lenses must be a non-empty list")
    Enum.each(lenses, &raise_if_blank!(:lens, &1))

    case GenServer.call(
           __MODULE__,
           {:append_lenses, session_id, operator_id, agent_name, user_name, lenses, msgs}
         ) do
      :ok ->
        :ok

      {:operator_mismatch, new_operator, bound_operator} ->
        raise ArgumentError,
              "session #{inspect(session_id)} is bound to operator #{inspect(bound_operator)}; " <>
                "refusing to append under operator #{inspect(new_operator)}"

      {:agent_mismatch, new_agent, bound_agent} ->
        raise ArgumentError,
              "session #{inspect(session_id)} is bound to agent #{inspect(bound_agent)}; " <>
                "refusing to append under agent #{inspect(new_agent)}"

      {:user_mismatch, new_user, bound_user} ->
        raise ArgumentError,
              "session #{inspect(session_id)} is bound to user #{inspect(bound_user)}; " <>
                "refusing to append under user #{inspect(new_user)}"

      {:capture_mode_mismatch, :legacy, :lens} ->
        raise ArgumentError,
              "session #{inspect(session_id)} already holds turns without a Lens; " <>
                "refusing to append a Lens-selected turn"
    end
  end

  @doc "Return the buffered turns for `session_id`, or `[]` if none."
  def turns_for(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:turns_for, session_id})
  end

  @doc "Schedule a retry-backed flush of the session's turns. Returns `:ok` immediately."
  def flush(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:flush, session_id})
  end

  @doc """
  Synchronously flush the session's turns and wait for completion.

  Returns `:ok` only after the flush callback has finished — for the Native
  adapter this means the episode is queryable via `recall/4` (graphiti's
  `add_episode` is sync through embed + persist). Returns `{:error, :timeout}`
  if the configured retry budget (1s/2s/4s plus the flush's own latency)
  exceeds `timeout_ms`; the buffered turns are still available to flush again.
  """
  def flush_and_await(session_id, timeout_ms)
      when is_binary(session_id) and is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(__MODULE__, {:flush_and_await, session_id, timeout_ms}, :infinity)
  end

  @doc "Flush every buffered session and await each. Used at shutdown."
  def flush_all do
    GenServer.call(__MODULE__, :flush_all, :infinity)
  end

  # ── GenServer ──────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       entries: %{},
       lens_entries: %{},
       flush_callback: Keyword.fetch!(opts, :flush_callback),
       lens_flush_callback: Keyword.get(opts, :lens_flush_callback),
       flush_workers: %{},
       retries: Keyword.get(opts, :retries, @default_retries)
     }}
  end

  @impl true
  def handle_call(
        {:append, session_id, group_id, agent_name, user_name, ontology, msgs},
        _from,
        state
      ) do
    case {Map.has_key?(state.lens_entries, session_id), Map.get(state.entries, session_id)} do
      {true, _entry} ->
        {:reply, {:capture_mode_mismatch, :lens, :legacy}, state}

      {false, nil} ->
        entries =
          Map.put(
            state.entries,
            session_id,
            {group_id, agent_name, user_name, ontology, [msgs]}
          )

        {:reply, :ok, %{state | entries: entries}}

      {false, {^group_id, ^agent_name, ^user_name, ^ontology, turns}} ->
        entries =
          Map.put(
            state.entries,
            session_id,
            {group_id, agent_name, user_name, ontology, turns ++ [msgs]}
          )

        {:reply, :ok, %{state | entries: entries}}

      {false, {other_group, _bound_agent, _bound_user, _bound_ontology, _turns}}
      when other_group != group_id ->
        {:reply, {:group_mismatch, group_id, other_group}, state}

      {false, {^group_id, bound_agent, _bound_user, _bound_ontology, _turns}}
      when bound_agent != agent_name ->
        {:reply, {:agent_mismatch, agent_name, bound_agent}, state}

      {false, {^group_id, ^agent_name, bound_user, _bound_ontology, _turns}}
      when bound_user != user_name ->
        {:reply, {:user_mismatch, user_name, bound_user}, state}

      {false, {^group_id, ^agent_name, ^user_name, bound_ontology, _turns}} ->
        {:reply, {:ontology_mismatch, ontology, bound_ontology}, state}
    end
  end

  def handle_call(
        {:append_lenses, session_id, operator_id, agent_name, user_name, lenses, msgs},
        _from,
        state
      ) do
    case {Map.has_key?(state.entries, session_id), Map.get(state.lens_entries, session_id)} do
      {true, _entry} ->
        {:reply, {:capture_mode_mismatch, :legacy, :lens}, state}

      {false, nil} ->
        entry = %{
          operator_id: operator_id,
          agent_name: agent_name,
          user_name: user_name,
          turns: [msgs],
          lens_order: Enum.uniq(lenses),
          batches: Map.new(Enum.uniq(lenses), &{&1, [msgs]}),
          ingestion_id: ingestion_id(session_id)
        }

        {:reply, :ok, %{state | lens_entries: Map.put(state.lens_entries, session_id, entry)}}

      {false,
       %{operator_id: ^operator_id, agent_name: ^agent_name, user_name: ^user_name} = entry} ->
        new_lenses = Enum.reject(Enum.uniq(lenses), &Map.has_key?(entry.batches, &1))

        batches =
          Enum.reduce(Enum.uniq(lenses), entry.batches, fn lens, batches ->
            Map.update(batches, lens, [msgs], &(&1 ++ [msgs]))
          end)

        entry = %{
          entry
          | turns: entry.turns ++ [msgs],
            lens_order: entry.lens_order ++ new_lenses,
            batches: batches
        }

        {:reply, :ok, %{state | lens_entries: Map.put(state.lens_entries, session_id, entry)}}

      {false, %{operator_id: bound_operator}} when bound_operator != operator_id ->
        {:reply, {:operator_mismatch, operator_id, bound_operator}, state}

      {false, %{agent_name: bound_agent}} when bound_agent != agent_name ->
        {:reply, {:agent_mismatch, agent_name, bound_agent}, state}

      {false, %{user_name: bound_user}} ->
        {:reply, {:user_mismatch, user_name, bound_user}, state}
    end
  end

  def handle_call({:turns_for, session_id}, _from, state) do
    case Map.get(state.entries, session_id) do
      nil ->
        turns =
          case Map.get(state.lens_entries, session_id) do
            nil -> []
            entry -> entry.turns
          end

        {:reply, turns, state}

      {_group, _agent, _user, _ontology, turns} ->
        {:reply, turns, state}
    end
  end

  def handle_call({:flush, session_id}, _from, state) do
    case Map.pop(state.lens_entries, session_id) do
      {nil, _lens_entries} ->
        flush_legacy(session_id, state)

      {entry, lens_entries} ->
        Logger.info(
          "[gralkor] flush scheduled — session:#{session_id} turns:#{length(entry.turns)}"
        )

        task =
          Task.async(fn ->
            do_flush_lenses(entry, state.lens_flush_callback, state.retries)
          end)

        {:reply, :ok,
         %{
           state
           | lens_entries: lens_entries,
             flush_workers: Map.put(state.flush_workers, task.ref, task)
         }}
    end
  end

  def handle_call({:flush_and_await, session_id, timeout_ms}, _from, state) do
    case Map.pop(state.lens_entries, session_id) do
      {nil, _lens_entries} ->
        flush_legacy_and_await(session_id, timeout_ms, state)

      {entry, lens_entries} ->
        Logger.info(
          "[gralkor] flush_and_await — session:#{session_id} turns:#{length(entry.turns)} timeout_ms:#{timeout_ms}"
        )

        task =
          Task.async(fn ->
            do_flush_lenses(entry, state.lens_flush_callback, state.retries)
          end)

        case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, :ok} ->
            Logger.info("[gralkor] flush_and_await done — session:#{session_id} outcome:ok")
            {:reply, :ok, %{state | lens_entries: lens_entries}}

          {:ok, {:error, reason}} ->
            Logger.warning(
              "[gralkor] flush_and_await done — session:#{session_id} outcome:error reason:#{inspect(reason)}"
            )

            {:reply, {:error, reason}, %{state | lens_entries: lens_entries}}

          nil ->
            Logger.warning("[gralkor] flush_and_await timeout — session:#{session_id}")
            {:reply, {:error, :timeout}, state}
        end
    end
  end

  def handle_call(:flush_all, _from, state) do
    await_flush_workers(state.flush_workers)

    legacy_tasks =
      for {_session_id, {group, agent, user, ontology, turns}} <- state.entries do
        Task.async(fn ->
          do_flush(group, agent, user, ontology, turns, state.flush_callback, state.retries)
        end)
      end

    lens_tasks =
      for {_session_id, entry} <- state.lens_entries do
        Task.async(fn ->
          do_flush_lenses(entry, state.lens_flush_callback, state.retries)
        end)
      end

    Task.await_many(legacy_tasks ++ lens_tasks, :infinity)
    {:reply, :ok, %{state | entries: %{}, lens_entries: %{}, flush_workers: %{}}}
  end

  @impl true
  def handle_info({reference, _outcome}, state) when is_reference(reference) do
    case Map.pop(state.flush_workers, reference) do
      {nil, _workers} ->
        Logger.error(
          "#{__MODULE__} received unexpected task result in handle_info/2: #{inspect(reference)}"
        )

        {:noreply, state}

      {_task, workers} ->
        Process.demonitor(reference, [:flush])
        {:noreply, %{state | flush_workers: workers}}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    case Map.pop(state.flush_workers, reference) do
      {nil, _workers} ->
        {:noreply, state}

      {_task, workers} ->
        Logger.error("[gralkor] capture flush worker exited — #{inspect(reason)}")
        {:noreply, %{state | flush_workers: workers}}
    end
  end

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.error("#{__MODULE__} received unexpected message in handle_info/2: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    await_flush_workers(state.flush_workers)

    for {_session_id, {group, agent, user, ontology, turns}} <- state.entries do
      do_flush(group, agent, user, ontology, turns, state.flush_callback, state.retries)
    end

    for {_session_id, entry} <- state.lens_entries do
      do_flush_lenses(entry, state.lens_flush_callback, state.retries)
    end

    :ok
  end

  # ── Flush worker ────────────────────────────────────────────

  defp flush_legacy(session_id, state) do
    case Map.pop(state.entries, session_id) do
      {nil, _entries} ->
        Logger.info("[gralkor] flush — session:#{session_id} empty")
        {:reply, :ok, state}

      {{group, agent, user, ontology, turns}, entries} ->
        Logger.info("[gralkor] flush scheduled — session:#{session_id} turns:#{length(turns)}")

        task =
          Task.async(fn ->
            do_flush(group, agent, user, ontology, turns, state.flush_callback, state.retries)
          end)

        {:reply, :ok,
         %{
           state
           | entries: entries,
             flush_workers: Map.put(state.flush_workers, task.ref, task)
         }}
    end
  end

  defp flush_legacy_and_await(session_id, timeout_ms, state) do
    case Map.pop(state.entries, session_id) do
      {nil, _entries} ->
        Logger.info("[gralkor] flush_and_await — session:#{session_id} empty")
        {:reply, :ok, state}

      {{group, agent, user, ontology, turns}, entries} ->
        Logger.info(
          "[gralkor] flush_and_await — session:#{session_id} turns:#{length(turns)} timeout_ms:#{timeout_ms}"
        )

        task =
          Task.async(fn ->
            do_flush(group, agent, user, ontology, turns, state.flush_callback, state.retries)
          end)

        case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, :ok} ->
            Logger.info("[gralkor] flush_and_await done — session:#{session_id} outcome:ok")
            {:reply, :ok, %{state | entries: entries}}

          {:ok, {:error, reason}} ->
            Logger.warning(
              "[gralkor] flush_and_await done — session:#{session_id} outcome:error reason:#{inspect(reason)}"
            )

            {:reply, {:error, reason}, %{state | entries: entries}}

          nil ->
            Logger.warning("[gralkor] flush_and_await timeout — session:#{session_id}")

            {:reply, {:error, :timeout},
             %{
               state
               | entries: Map.put(entries, session_id, {group, agent, user, ontology, turns})
             }}
        end
    end
  end

  defp do_flush(group, agent, user, ontology, turns, cb, retries) do
    do_flush(
      group,
      agent,
      user,
      ontology,
      turns,
      cb,
      retries,
      System.monotonic_time(:millisecond)
    )
  end

  defp do_flush_lenses(entry, callback, retries) when is_function(callback) do
    first_error =
      Enum.reduce(entry.lens_order, nil, fn lens, first_error ->
        turns = Map.fetch!(entry.batches, lens)

        invoke = fn operator_id, agent_name, user_name, lens_name, lens_turns ->
          invoke_lens_callback(
            callback,
            operator_id,
            agent_name,
            user_name,
            lens_name,
            lens_turns,
            entry.ingestion_id
          )
        end

        case do_flush(
               entry.operator_id,
               entry.agent_name,
               entry.user_name,
               lens,
               turns,
               invoke,
               retries
             ) do
          {:ok, _result} ->
            first_error

          :ok ->
            first_error

          {:error, _reason} = error ->
            first_error || error
        end
      end)

    case first_error do
      nil ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp do_flush(group, agent, user, ontology, turns, cb, retries, t0) do
    case safe_invoke(cb, group, agent, user, ontology, turns) do
      :ok ->
        elapsed = System.monotonic_time(:millisecond) - t0
        Logger.info("[gralkor] capture flushed — turns:#{length(turns)} elapsed:#{elapsed}ms")
        :ok

      {:ok, result} ->
        elapsed = System.monotonic_time(:millisecond) - t0
        Logger.info("[gralkor] capture flushed — turns:#{length(turns)} elapsed:#{elapsed}ms")
        {:ok, result}

      {:error, :capture_client_4xx} = err ->
        Logger.warning("[gralkor] capture dropped (4xx)")
        err

      {:error, {:upstream_llm, _}} = err ->
        Logger.warning("[gralkor] capture dropped (upstream error)")
        err

      {:error, _reason} ->
        retry(group, agent, user, ontology, turns, cb, retries, t0)

      {:exception, exception, stacktrace} ->
        Logger.warning(
          "[gralkor] capture flush raised — retrying. " <>
            Exception.format(:error, exception, stacktrace)
        )

        retry(group, agent, user, ontology, turns, cb, retries, t0)
    end
  end

  defp safe_invoke(cb, group, agent, user, ontology, turns) do
    try do
      case cb.(group, agent, user, ontology, turns) do
        :ok -> :ok
        {:ok, _result} = ok -> ok
        {:error, _reason} = error -> error
        other -> {:error, {:unexpected_callback_result, other}}
      end
    rescue
      e -> {:exception, e, __STACKTRACE__}
    catch
      kind, reason -> {:error, {:caught_callback_outcome, kind, reason}}
    end
  end

  defp retry(_group, _agent, _user, _ontology, _turns, _cb, [], _t0) do
    Logger.error("[gralkor] capture exhausted")
    {:error, :exhausted}
  end

  defp retry(group, agent, user, ontology, turns, cb, [delay | rest], t0) do
    Process.sleep(delay)
    do_flush(group, agent, user, ontology, turns, cb, rest, t0)
  end

  defp raise_if_blank!(field, name) when is_binary(name) do
    if String.trim(name) == "" do
      raise ArgumentError, "#{field} must be a non-blank string, got #{inspect(name)}"
    end

    :ok
  end

  defp raise_if_blank!(field, other) do
    raise ArgumentError, "#{field} must be a non-blank string, got #{inspect(other)}"
  end

  defp await_flush_workers(workers) do
    workers
    |> Map.values()
    |> Enum.each(fn task ->
      case Task.yield(task, :infinity) do
        {:ok, _outcome} ->
          :ok

        {:exit, reason} ->
          Logger.error("[gralkor] capture flush worker exited — #{inspect(reason)}")
      end
    end)
  end

  defp invoke_lens_callback(
         callback,
         operator_id,
         agent_name,
         user_name,
         lens,
         turns,
         ingestion_id
       ) do
    cond do
      is_function(callback, 6) ->
        callback.(operator_id, agent_name, user_name, lens, turns, ingestion_id)

      is_function(callback, 5) ->
        callback.(operator_id, agent_name, user_name, lens, turns)

      true ->
        {:error, {:invalid_lens_flush_callback, callback}}
    end
  end

  defp ingestion_id(session_id) do
    "#{session_id}:#{collision_resistant_token()}"
  end

  defp collision_resistant_token do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
