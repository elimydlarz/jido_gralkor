defmodule Gralkor.Client.Native do
  @moduledoc """
  Production `Gralkor.Client` implementation. In-process — no HTTP — talks
  to graphiti via `Gralkor.GraphitiPool` (Pythonx-backed).

  See `test-trees/unit/gralkor-client-native_TEST_TREES.md`.
  """

  @behaviour Gralkor.Client

  alias Gralkor.CaptureBuffer
  alias Gralkor.Client
  alias Gralkor.DefaultOntology
  alias Gralkor.Format
  alias Gralkor.GraphitiPool
  alias Gralkor.Ingest
  alias Gralkor.Recall

  # ── Client behaviour ────────────────────────────────────────

  @impl Gralkor.Client
  def recall(group_id, agent_name, session_id, query) do
    raise_if_blank!(:agent_name, agent_name)

    opts = [search_fn: search_fn()]

    opts =
      case Application.get_env(:jido_gralkor, :recall_deadline_ms) do
        nil ->
          opts

        ms when is_integer(ms) and ms > 0 ->
          Keyword.put(opts, :deadline_ms, ms)

        invalid ->
          raise ArgumentError,
                "Gralkor.Client.Native: recall_deadline_ms must be a positive integer, got #{inspect(invalid)}"
      end

    Recall.recall(group_id, agent_name, session_id, query, opts)
  end

  @impl Gralkor.Client
  def capture(session_id, group_id, agent_name, user_name, msgs) do
    raise_if_blank!(:session_id, session_id)
    raise_if_blank!(:agent_name, agent_name)
    raise_if_blank!(:user_name, user_name)

    # Capture is silent per-turn — what actually lands in memory is logged at
    # flush time instead (see `build_flush_callback/2`, gated on the same :test
    # flag). Logging every buffered turn here just floods the consumer's logs.
    CaptureBuffer.append(
      session_id,
      group_id,
      agent_name,
      user_name,
      DefaultOntology,
      msgs
    )
  end

  @impl Gralkor.Client
  def capture(session_id, operator_id, agent_name, user_name, msgs, lens) do
    raise_if_blank!(:session_id, session_id)
    raise_if_blank!(:agent_name, agent_name)
    raise_if_blank!(:user_name, user_name)

    CaptureBuffer.append_lens(
      session_id,
      operator_id,
      agent_name,
      user_name,
      lens,
      msgs
    )
  end

  @impl Gralkor.Client
  def capture(session_id, operator_id, agent_name, user_name, msgs, lens, additional_lenses) do
    capture(session_id, operator_id, agent_name, user_name, msgs, lens, additional_lenses, %{})
  end

  @impl Gralkor.Client
  def capture(
        session_id,
        operator_id,
        agent_name,
        user_name,
        msgs,
        lens,
        additional_lenses,
        reflection_context
      ) do
    raise_if_blank!(:session_id, session_id)
    raise_if_blank!(:agent_name, agent_name)
    raise_if_blank!(:user_name, user_name)

    CaptureBuffer.append_lenses(
      session_id,
      operator_id,
      agent_name,
      user_name,
      [lens | additional_lenses],
      msgs,
      reflection_context
    )
  end

  @impl Gralkor.Client
  def flush(session_id) do
    raise_if_blank!(:session_id, session_id)
    CaptureBuffer.flush(session_id)
  end

  @impl Gralkor.Client
  def flush_and_await(session_id, timeout_ms) do
    raise_if_blank!(:session_id, session_id)

    unless is_integer(timeout_ms) and timeout_ms > 0 do
      raise ArgumentError,
            "Gralkor.Client.Native: timeout_ms must be a positive integer, got #{inspect(timeout_ms)}"
    end

    CaptureBuffer.flush_and_await(session_id, timeout_ms)
  end

  @impl Gralkor.Client
  def memory_add(group_id, content, source_description) do
    memory_add(group_id, content, source_description, :document)
  end

  @impl Gralkor.Client
  def memory_add(group_id, content, source_description, source_kind) do
    Ingest.validate_source!(source_kind, content)
    source = source_description || "manual"
    episode_body = Ingest.encode_content!(source_kind, content)

    case GraphitiPool.add_episode(
           GraphitiPool,
           group_id,
           episode_body,
           source,
           DefaultOntology,
           source_kind: source_kind
         ) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  @impl Gralkor.Client
  def build_indices, do: GraphitiPool.build_indices()

  @impl Gralkor.Client
  def build_communities(group_id) do
    sanitized = Client.sanitize_group_id(group_id)
    GraphitiPool.build_communities(sanitized)
  end

  # ── Wiring ──────────────────────────────────────────────────

  defp search_fn do
    fn group_id, query, max_results ->
      case GraphitiPool.search(group_id, query, max_results) do
        {:ok, raw_facts} -> {:ok, Enum.map(raw_facts, &Format.format_fact/1)}
        {:error, _} = err -> err
      end
    end
  end

  defp raise_if_blank!(field, value) when is_binary(value) do
    if String.trim(value) == "" do
      raise ArgumentError,
            "Gralkor.Client.Native: #{field} must be a non-blank string, got #{inspect(value)}"
    end

    :ok
  end

  defp raise_if_blank!(field, value) do
    raise ArgumentError,
          "Gralkor.Client.Native: #{field} must be a non-blank string, got #{inspect(value)}"
  end
end
