defmodule Gralkor.Client.Native do
  @moduledoc """
  Production `Gralkor.Client` implementation. In-process — no HTTP — talks
  to graphiti via `Gralkor.GraphitiPool` (Pythonx-backed).

  See `test-trees/unit/gralkor-client-native_TEST_TREES.md`.
  """

  @behaviour Gralkor.Client

  alias Gralkor.CaptureBuffer
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
  def capture(runtime_owner, %Gralkor.Capture{} = request) do
    routes = Gralkor.Capture.resolve!(runtime_owner, request)
    CaptureBuffer.append_capture(runtime_owner, request, routes)
  end

  for arity <- [5, 6, 7, 8] do
    arguments = Macro.generate_arguments(arity, __MODULE__)

    def capture(unquote_splicing(arguments)) do
      raise ArgumentError,
            "positional capture/#{unquote(arity)} is retired; use Gralkor.Client.capture(runtime_owner, %Gralkor.Capture{route: {:direct, destination} | {:lenses, names}})"
    end
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
           source_kind: source_kind,
           writer: :direct
         ) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  @impl Gralkor.Client
  def build_indices, do: GraphitiPool.build_indices()

  @impl Gralkor.Client
  def build_communities(group_id) do
    GraphitiPool.build_communities(group_id)
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
