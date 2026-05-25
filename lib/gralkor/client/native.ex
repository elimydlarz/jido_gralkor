defmodule Gralkor.Client.Native do
  @moduledoc """
  Production `Gralkor.Client` implementation. In-process — no HTTP — talks
  to graphiti via `Gralkor.GraphitiPool` (Pythonx-backed) and to the LLM via
  `req_llm` (Elixir-side, used by `Gralkor.Distill` and `Gralkor.Interpret`).

  See `ex-client-native` in `gralkor/TEST_TREES.md`.
  """

  @behaviour Gralkor.Client

  alias Gralkor.CaptureBuffer
  alias Gralkor.Client
  alias Gralkor.Config
  alias Gralkor.Distill
  alias Gralkor.Format
  alias Gralkor.Generalise
  alias Gralkor.Generalisation
  alias Gralkor.GraphitiPool
  alias Gralkor.Interpret
  alias Gralkor.Recall

  # ── Client behaviour ────────────────────────────────────────

  @impl Gralkor.Client
  def recall(group_id, agent_name, session_id, query) do
    raise_if_blank!(:agent_name, agent_name)

    opts = [
      search_fn: search_fn(),
      gen_search_fn: gen_recall_search_fn(),
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
    CaptureBuffer.append(session_id, group_id, agent_name, user_name, Config.ontology(), msgs)
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
      add_episode_fn: &GraphitiPool.add_episode/4,
      remove_episode_fn: &GraphitiPool.remove_episode/2
    ]

    Generalise.generalise(group_id, transcript, opts)
  end

  @impl Gralkor.Client
  def search_generalisations(group_id, query, max_results) do
    sanitized = Client.sanitize_group_id(group_id)
    gen_partition = "#{sanitized}:gen"

    case GraphitiPool.search(gen_partition, query, max_results) do
      {:ok, raw_facts} ->
        gens =
          Enum.flat_map(raw_facts, fn fact ->
            case Generalisation.decode(fact.fact) do
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

    fn prompt, max_tokens ->
      case ReqLLM.generate_object(model, prompt, schema, max_tokens: max_tokens) do
        {:ok, response} ->
          object = ReqLLM.Response.object(response)
          {:ok, Map.get(object, :relevantFacts) || Map.get(object, "relevantFacts") || []}

        {:error, _} = err ->
          err
      end
    end
  end

  defp distill_fn do
    model = Config.llm_model()
    schema = Distill.distill_schema()

    fn prompt ->
      case ReqLLM.generate_object(model, prompt, schema) do
        {:ok, response} ->
          object = ReqLLM.Response.object(response)
          {:ok, Map.get(object, :behaviour) || Map.get(object, "behaviour") || ""}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc false
  def distill_callback, do: distill_fn()

  @doc false
  def interpret_callback, do: interpret_fn()

  defp turns_fn, do: &CaptureBuffer.turns_for/1

  defp hypothesise_gen_fn do
    model = Config.llm_model()
    schema = Generalise.hypothesise_schema()

    fn prompt ->
      case ReqLLM.generate_object(model, prompt, schema) do
        {:ok, response} ->
          object = ReqLLM.Response.object(response)
          candidates = Map.get(object, :generalisations) || Map.get(object, "generalisations") || []
          {:ok, candidates}

        {:error, _} = err ->
          err
      end
    end
  end

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
    fn partition, query, max_results ->
      case GraphitiPool.search(partition, query, max_results) do
        {:ok, raw_facts} -> {:ok, Enum.map(raw_facts, &Map.get(&1, :fact))}
        {:error, _} = err -> err
      end
    end
  end

  defp gen_recall_search_fn do
    fn group_id, query, max_results ->
      sanitized = Client.sanitize_group_id(group_id)
      gen_partition = "#{sanitized}:gen"

      case GraphitiPool.search(gen_partition, query, max_results) do
        {:ok, raw_facts} ->
          formatted =
            Enum.flat_map(raw_facts, fn fact ->
              case Generalisation.decode(fact.fact) do
                {:ok, gen, _plain} ->
                  ["<generalisation> #{gen.content} (confidence: #{gen.confidence}) (level: #{gen.level})"]

                {:error, :not_a_generalisation} ->
                  []
              end
            end)

          {:ok, formatted}

        {:error, _} = err ->
          err
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
