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
  alias Gralkor.Generalise
  alias Gralkor.Generalisation
  alias Gralkor.GraphitiPool
  alias Gralkor.Interpret
  alias Gralkor.Learn
  alias Gralkor.Recall

  # ── Client behaviour ────────────────────────────────────────

  @impl Gralkor.Client
  def recall(group_id, agent_name, session_id, query) do
    raise_if_blank!(:agent_name, agent_name)

    opts = [
      search_fn: search_fn(),
      gen_search_fn: gen_recall_search_fn(),
      # ERL recall (§1) runs unconditionally on every recall — no flag, no LLM
      # classification. The learning search is seeded with the raw user query
      # and bakes in SearchFilters(node_labels: ["Learning"]) so only the
      # plugin's Learning custom-entity episodes are returned (ex-learning-entity).
      learning_search_fn: learning_search_fn(),
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
    raise_if_blank!(:session_id, session_id)
    raise_if_blank!(:agent_name, agent_name)
    raise_if_blank!(:user_name, user_name)

    CaptureBuffer.append_lenses(
      session_id,
      operator_id,
      agent_name,
      user_name,
      [lens | additional_lenses],
      msgs
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

  @impl Gralkor.Client
  def generalise(group_id, transcript) do
    opts = [
      hypothesise_fn: hypothesise_gen_fn(),
      evaluate_fn: evaluate_gen_fn(),
      search_gen_fn: search_gen_fn(),
      ontology: Config.ontology(),
      add_episode_fn: fn group_id, content, source, ontology, opts ->
        GraphitiPool.add_episode(Gralkor.GraphitiPool, group_id, content, source, ontology, opts)
      end
    ]

    Generalise.generalise(group_id, transcript, opts)
  end

  @impl Gralkor.Client
  def search_generalisations(group_id, query, max_results) do
    sanitized = Client.sanitize_group_id(group_id)
    gen_group_id = "#{sanitized}_gen"

    case GraphitiPool.search_episodes(GraphitiPool, gen_group_id, query, max_results) do
      {:ok, episodes} ->
        gens =
          Enum.flat_map(episodes, fn episode ->
            case Generalisation.decode(episode.content) do
              {:ok, gen, _plain} -> [gen]
              {:error, :not_a_generalisation} -> []
            end
          end)

        {:ok, gens}

      {:error, _} = err ->
        err
    end
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
          {:ok, Map.get(object, :relevantFacts) || Map.get(object, "relevantFacts") || []}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Turn one turn into a `Gralkor.AgentLearning` via the configured LLM. Wired
  into the CaptureBuffer flush callback as the `learn_fn` dep — the flush path
  calls it for every captured turn (learning is unconditional).
  """
  def learn(turn, agent_name, user_name) do
    Learn.learn(turn, learn_llm_fn(), agent_name, user_name)
  end

  defp learn_llm_fn do
    model = Config.llm_model()
    schema = Learn.learn_schema()

    fn prompt ->
      case ReqLLM.generate_object(model, prompt, schema) do
        {:ok, response} -> {:ok, ReqLLM.Response.object(response)}
        {:error, _} = err -> err
      end
    end
  end

  # ERL recall (§1): the learning search uses graphiti NODE search filtered to
  # the plugin's Learning custom-entity nodes (node_labels: ["Learning"]), seeded
  # with the raw user query. Node search — not edge search — because a Learning is
  # a custom-entity NODE; edge search's node_labels filter matches edges by
  # endpoint and misses standalone Learning nodes. Unconditional on every recall
  # (see ex-recall > orchestration > learning search). Degrades to [] on failure;
  # Recall.await_aux owns the 5s yield + the [:ok, facts] shape.
  defp learning_search_fn do
    fn group_id, query, max_results ->
      case GraphitiPool.search_nodes(GraphitiPool, group_id, query, max_results,
             node_labels: ["Learning"]
           ) do
        {:ok, nodes} -> {:ok, Enum.map(nodes, &format_learning_node/1)}
        {:error, _} = err -> err
      end
    end
  end

  defp format_learning_node(%{name: name, summary: summary, attributes: attrs}) do
    detail =
      ["lesson", "approach", "problem_kind"]
      |> Enum.map(fn k -> {k, Map.get(attrs, k)} end)
      |> Enum.reject(fn {_k, v} -> v in [nil, "", "None"] end)
      |> Enum.map_join("; ", fn {k, v} -> "#{k}: #{v}" end)

    body = if summary in [nil, ""], do: name, else: summary

    case detail do
      "" -> "- learning — #{body}"
      _ -> "- learning — #{body} (#{detail})"
    end
  end

  @doc false
  def interpret_callback, do: interpret_fn()

  @doc false
  @spec interpret_output_token_options(:openai | :google, pos_integer()) :: keyword()
  def interpret_output_token_options(:openai, output_token_budget),
    do: [max_completion_tokens: output_token_budget]

  def interpret_output_token_options(:google, output_token_budget),
    do: [max_tokens: output_token_budget]

  defp turns_fn, do: &CaptureBuffer.turns_for/1

  defp hypothesise_gen_fn do
    model = Config.llm_model()
    schema = Generalise.hypothesise_schema()

    fn prompt ->
      case ReqLLM.generate_object(model, prompt, schema) do
        {:ok, response} ->
          object = ReqLLM.Response.object(response)

          candidates =
            Map.get(object, :generalisations) || Map.get(object, "generalisations") || []

          {:ok, candidates}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc false
  def generalise_hypothesise_callback, do: hypothesise_gen_fn()

  defp evaluate_gen_fn do
    model = Config.llm_model()
    schema = Generalise.evaluate_schema()

    fn prompt ->
      case ReqLLM.generate_object(model, prompt, schema) do
        {:ok, response} ->
          object = ReqLLM.Response.object(response)
          decisions = Map.get(object, :decisions) || Map.get(object, "decisions") || []
          {:ok, decisions}

        {:error, _} = err ->
          err
      end
    end
  end

  defp search_gen_fn do
    fn gen_group_id, query, max_results ->
      case GraphitiPool.search(gen_group_id, query, max_results) do
        {:ok, raw_facts} -> {:ok, Enum.map(raw_facts, &Map.get(&1, :fact))}
        {:error, _} = err -> err
      end
    end
  end

  defp gen_recall_search_fn do
    fn group_id, query, max_results ->
      sanitized = Client.sanitize_group_id(group_id)
      gen_group_id = "#{sanitized}_gen"

      case GraphitiPool.search_nodes(GraphitiPool, gen_group_id, query, max_results) do
        {:ok, nodes} ->
          {:ok, Enum.map(nodes, &format_generalisation_node/1)}

        {:error, _} = err ->
          err
      end
    end
  end

  defp format_generalisation_node(%{name: name, summary: summary}) do
    body = if summary in [nil, ""], do: name, else: summary
    "<generalisation> #{body}"
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
