defmodule Gralkor.Client.Native do
  @moduledoc """
  Production `Gralkor.Client` implementation. In-process — no HTTP — talks
  to graphiti via `Gralkor.GraphitiPool` (Pythonx-backed) and to the LLM via
  `req_llm` (Elixir-side, used by `Gralkor.Distill` and `Gralkor.Interpret`).

  See `test-trees/unit/gralkor-client-native_TEST_TREES.md`.
  """

  @behaviour Gralkor.Client

  alias Gralkor.CaptureBuffer
  alias Gralkor.Client
  alias Gralkor.Config
  alias Gralkor.Format
  alias Gralkor.GraphitiPool
  alias Gralkor.Interpret
  alias Gralkor.Recall

  # ── Client behaviour ────────────────────────────────────────

  @impl Gralkor.Client
  def recall(group_id, agent_name, session_id, query) do
    raise_if_blank!(:agent_name, agent_name)

    opts = [
      search_fn: search_fn(),
      interpret_fn: interpret_fn(),
      turns_fn: turns_fn()
    ]

    opts =
      case Application.get_env(:jido_gralkor, :recall_deadline_ms) do
        nil -> opts
        ms when is_integer(ms) -> Keyword.put(opts, :deadline_ms, ms)
      end

    opts =
      case Application.get_env(:jido_gralkor, :interpret_max_output_tokens) do
        nil ->
          opts

        budget when is_integer(budget) and budget > 0 ->
          Keyword.put(opts, :output_token_budget, budget)

        other ->
          raise ArgumentError,
                "Gralkor.Client.Native: :jido_gralkor, :interpret_max_output_tokens must be a positive integer, got #{inspect(other)}"
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
      Config.ontology(),
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
    memory_add(group_id, content, source_description, Config.ontology())
  end

  @impl Gralkor.Client
  def memory_add(group_id, content, source_description, ontology) do
    raise_unless_ontology_or_nil!(ontology)
    source = source_description || "manual"

    case GraphitiPool.add_episode(group_id, content, source, ontology) do
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

  defp interpret_fn do
    model = Config.llm_model()
    schema = Interpret.interpret_schema()

    fn prompt, output_token_budget ->
      options = interpret_output_token_options(model.provider, output_token_budget)

      case ReqLLM.generate_object(model, prompt, schema, options) do
        {:ok, response} ->
          object = ReqLLM.Response.object(response)
          interpret_relevant_facts(object)

        {:error, _} = err ->
          err
      end
    end
  end

  @doc false
  def interpret_callback, do: interpret_fn()

  @doc false
  def interpret_relevant_facts(object) when is_map(object) do
    {:ok, Map.get(object, :relevantFacts) || Map.get(object, "relevantFacts")}
  end

  @doc false
  @spec interpret_output_token_options(:openai | :google, pos_integer()) :: keyword()
  def interpret_output_token_options(:openai, output_token_budget),
    do: [max_completion_tokens: output_token_budget]

  def interpret_output_token_options(:google, output_token_budget),
    do: [max_tokens: output_token_budget]

  defp turns_fn, do: &CaptureBuffer.turns_for/1

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

  defp raise_unless_ontology_or_nil!(nil), do: :ok

  defp raise_unless_ontology_or_nil!(module) when is_atom(module) do
    if function_exported?(module, :__ontology__, 0) or
         (Code.ensure_loaded?(module) and function_exported?(module, :__ontology__, 0)) do
      :ok
    else
      raise ArgumentError,
            "Gralkor.Client.Native: ontology must be a module declared via `use Gralkor.Ontology`, got #{inspect(module)}"
    end
  end

  defp raise_unless_ontology_or_nil!(other) do
    raise ArgumentError,
          "Gralkor.Client.Native: ontology must be a module or nil, got #{inspect(other)}"
  end

end
