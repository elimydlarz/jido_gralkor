defmodule Gralkor.Generalise do
  @moduledoc """
  Orchestrate one generalisation run: hypothesise generalisations from a
  transcript, search existing generalisations to rule candidates in or out,
  evaluate relationships, and persist the strongest.

  Pure orchestration — all dependencies (hypothesise LLM call, evaluate LLM
  call, search, add_episode, remove_episode) are passed as functions in
  `opts`. Production wiring lives in `Gralkor.Client.Native`.

  See `ex-generalise` in `TEST_TREES.md`.
  """

  require Logger

  alias Gralkor.Generalisation

  @default_min_confidence 0.3
  @default_max_gen_results 5

  @type group_id :: String.t()

  @type hypothesise_fn :: (String.t() -> {:ok, [%{content: String.t(), confidence: float()}]} | {:error, term()})
  @type search_gen_fn :: (String.t(), String.t(), pos_integer() -> {:ok, [String.t()]} | {:error, term()})
  @type evaluate_fn :: (String.t() -> {:ok, [map()]} | {:error, term()})
  @type add_episode_fn :: (String.t(), String.t(), String.t(), module() | nil, keyword()) -> :ok | {:error, term()}
  @type remove_episode_fn :: (String.t(), String.t()) -> :ok | {:error, term()}

  @type opts :: [
          hypothesise_fn: hypothesise_fn(),
          search_gen_fn: search_gen_fn(),
          evaluate_fn: evaluate_fn(),
          add_episode_fn: add_episode_fn(),
          remove_episode_fn: remove_episode_fn(),
          min_confidence: float(),
          max_gen_results: pos_integer()
        ]

  @doc """
  Run the full generalisation pipeline against a flushed transcript.

  Returns `:ok` (best-effort — failures are logged but do not propagate),
  or `{:error, term()}` when no required `opts` keys are provided.
  """
  @spec generalise(group_id(), String.t(), opts()) :: :ok | {:error, term()}
  def generalise(group_id, transcript, opts) when is_binary(group_id) and is_binary(transcript) do
    hypothesise_fn = Keyword.fetch!(opts, :hypothesise_fn)
    search_gen_fn = Keyword.fetch!(opts, :search_gen_fn)
    evaluate_fn = Keyword.fetch!(opts, :evaluate_fn)
    add_episode_fn = Keyword.fetch!(opts, :add_episode_fn)
    remove_episode_fn = Keyword.get(opts, :remove_episode_fn)

    min_confidence = Keyword.get(opts, :min_confidence, @default_min_confidence)
    max_gen_results = Keyword.get(opts, :max_gen_results, @default_max_gen_results)

    gen_partition = "#{group_id}:gen"

    with {:ok, hypotheses} <- do_hypothesise(transcript, hypothesise_fn, min_confidence),
         :ok <- do_persist(
           hypotheses,
           search_gen_fn,
           evaluate_fn,
           add_episode_fn,
           remove_episode_fn,
           gen_partition,
           max_gen_results
         ) do
      :ok
    else
      {:error, {:upstream_llm, reason}} ->
        Logger.warning("[gralkor] generalise upstream LLM error: #{inspect(reason)}")
        :ok

      {:error, reason} ->
        Logger.warning("[gralkor] generalise error: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Schema for the hypothesise LLM call. Returns a list of candidate
  generalisations with confidence scores.
  """
  def hypothesise_schema do
    [
      generalisations: [
        type: {:list, :map},
        required: true,
        doc:
          "List of hypothesised generalisations derived from the conversation transcript. Each entry must have content (string) and confidence (float 0.0-1.0)."
      ]
    ]
  end

  @doc """
  Schema for the evaluate LLM call. Returns a decision per hypothesis
  relative to any existing generalisations found via search.
  """
  def evaluate_schema do
    [
      decisions: [
        type: {:list, :map},
        required: true,
        doc:
          "One decision per hypothesised generalisation. Each must have: action (save|broadens|narrows|contradicts|skip), hypothesis_index (integer), confidence (float), content (string — the final content to save, which may be refined from the hypothesis). For broadens/narrows/contradicts, also provide existing_id (string — the id of the existing generalisation affected)."
      ]
    ]
  end

  # ── internal ────────────────────────────────────────────────

  defp do_hypothesise(transcript, hypothesise_fn, min_confidence) do
    prompt = hypothesise_prompt(transcript)

    if test_mode?(),
      do: Logger.info("[gralkor] [test] generalise hypothesise prompt chars: #{String.length(prompt)}")

    case hypothesise_fn.(prompt) do
      {:ok, candidates} ->
        filtered =
          candidates
          |> Enum.filter(fn c -> Map.get(c, :confidence, 0) >= min_confidence end)
          |> Enum.sort_by(fn c -> Map.get(c, :confidence, 0) end, :desc)

        Logger.info(
          "[gralkor] generalise hypothesised — candidates:#{length(candidates)} above_threshold:#{length(filtered)}"
        )

        if test_mode?() and filtered != [],
          do: Logger.info("[gralkor] [test] generalise hypotheses: #{inspect(filtered)}")

        {:ok, filtered}

      {:error, _} = err ->
        err
    end
  end

  defp do_persist(hypotheses, search_fn, evaluate_fn, add_fn, remove_fn, partition, max_results) do
    if hypotheses == [] do
      Logger.info("[gralkor] generalise no hypotheses above confidence threshold — nothing to persist")
      return :ok
    end

    # Search for existing generalisations related to each hypothesis
    existing_by_idx =
      hypotheses
      |> Enum.with_index()
      |> Enum.map(fn {h, idx} ->
        query = Map.get(h, :content, "")
        case search_fn.(partition, query, max_results) do
          {:ok, raw} ->
            decoded =
              Enum.reduce(raw, [], fn fact, acc ->
                case Generalisation.decode(fact) do
                  {:ok, gen, _plain} -> [gen | acc]
                  {:error, :not_a_generalisation} -> acc
                end
              end)
              |> Enum.reverse()

            {idx, decoded}

          {:error, reason} ->
            Logger.warning("[gralkor] generalise search failed for hypothesis ##{idx}: #{inspect(reason)}")
            {idx, []}
        end
      end)
      |> Map.new()

    # Build evaluate prompt: hypothesis + existing generalisations
    eval_inputs =
      hypotheses
      |> Enum.with_index()
      |> Enum.map(fn {h, idx} ->
        existing = Map.get(existing_by_idx, idx, [])
        %{hypothesis: h, index: idx, existing: existing}
      end)

    if test_mode?(),
      do: Logger.info("[gralkor] [test] generalise eval inputs: #{length(eval_inputs)}")

    case evaluate_fn.(evaluate_prompt(eval_inputs)) do
      {:ok, decisions} ->
        Logger.info("[gralkor] generalise evaluated — decisions:#{length(decisions)}")

        if test_mode?() and decisions != [],
          do: Logger.info("[gralkor] [test] generalise decisions: #{inspect(decisions)}")

        persist_decisions(decisions, hypotheses, existing_by_idx, add_fn, remove_fn, partition)
        :ok

      {:error, reason} ->
        Logger.warning("[gralkor] generalise evaluate failed: #{inspect(reason)}")
        :ok
    end
  end

  defp persist_decisions(decisions, hypotheses, existing_by_idx, add_fn, remove_fn, partition) do
    Enum.each(decisions, fn decision ->
      action = normalize_action(Map.get(decision, :action))
      idx = Map.get(decision, :hypothesis_index)
      content = Map.get(decision, :content, "")
      confidence = Map.get(decision, :confidence, 0.0)
      existing_id = Map.get(decision, :existing_id)

      case action do
        :skip ->
          Logger.info("[gralkor] generalise skip — hypothesis ##{idx}")

        a when a in [:save, :broadens, :narrows, :contradicts] ->
          generalises = if existing_id, do: [existing_id], else: []

          child_levels =
            if existing_id do
              existing = Map.get(existing_by_idx, idx, [])
              level_for(existing, existing_id)
            else
              []
            end

          level = (Enum.max(child_levels, fn -> -1 end)) + 1

          gen = %Generalisation{
            id: generate_id(),
            content: content,
            level: level,
            confidence: confidence,
            generalises: generalises
          }

          body = Generalisation.encode(gen)

          if action == :contradicts and existing_id and remove_fn do
            Logger.info("[gralkor] generalise contradict — removing #{existing_id}")
            remove_fn.(partition, existing_id)
          end

          case add_fn.(partition, body, "generalisation", nil, uuid: gen.id) do
            :ok ->
              Logger.info(
                "[gralkor] generalise #{action} — saved (id:#{gen.id} level:#{level} confidence:#{confidence})"
              )

            {:error, reason} ->
              Logger.warning("[gralkor] generalise persist failed: #{inspect(reason)}")
          end

        _ ->
          Logger.warning("[gralkor] generalise unknown action: #{inspect(Map.get(decision, :action))}")
      end
    end)
  end

  defp normalize_action("save"), do: :save
  defp normalize_action("broadens"), do: :broadens
  defp normalize_action("narrows"), do: :narrows
  defp normalize_action("contradicts"), do: :contradicts
  defp normalize_action("skip"), do: :skip
  defp normalize_action(other) when is_atom(other), do: other
  defp normalize_action(_), do: :unknown

  defp level_for(existing, id) do
    Enum.flat_map(existing, fn g ->
      if g.id == id, do: [g.level], else: []
    end)
  end

  defp generate_id do
    "gen-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  # ── prompts ─────────────────────────────────────────────────

  defp hypothesise_prompt(transcript) do
    """
    Review the following conversation transcript and hypothesise generalisations — durable, evidence-backed observations that capture meaningful patterns, preferences, decisions, or recurring behaviours.

    A good generalisation:
    - Is supported by specific evidence in the transcript
    - Captures a pattern that likely persists beyond this single conversation
    - Is specific enough to be useful, general enough to apply broadly
    - Avoids restating obvious facts from the transcript

    For each hypothesis, provide a confidence score (0.0-1.0) reflecting how strongly the transcript supports it.

    Transcript:
    #{transcript}
    """
  end

  defp evaluate_prompt(inputs) do
    entries =
      Enum.map(inputs, fn %{hypothesis: h, index: idx, existing: existing} ->
        existing_text =
          if existing == [] do
            "  (no existing generalisations found)"
          else
            Enum.map(existing, fn g ->
              "  - [#{g.id}] (level:#{g.level} confidence:#{g.confidence}) #{g.content}"
            end)
            |> Enum.join("\n")
          end

        """
        Hypothesis ##{idx} (confidence: #{Map.get(h, :confidence, 0)}):
        #{Map.get(h, :content, "")}

        Existing generalisations:
        #{existing_text}
        """
      end)
      |> Enum.join("\n---\n")

    """
    For each hypothesised generalisation below, decide what action to take relative to any existing generalisations found:

    - "save": New independent generalisation with no relationship to existing ones.
    - "broadens": The hypothesis is broader than an existing generalisation (subsumes it). The existing one remains active.
    - "narrows": The hypothesis is narrower than an existing generalisation (refines it). The existing one remains active.
    - "contradicts": The hypothesis directly contradicts an existing generalisation — evidence shows the existing one is wrong. Use this sparingly.
    - "skip": Not strong enough to persist, or already fully covered by an existing generalisation.

    For each decision, provide:
    - hypothesis_index: the index from the input
    - action: one of the five actions above
    - confidence: final confidence score (may differ from hypothesis)
    - content: the final content to save (may be refined from the hypothesis)
    - existing_id: required for broadens/narrows/contradicts — the id of the affected existing generalisation

    #{entries}
    """
  end

  defp test_mode?, do: Application.get_env(:jido_gralkor, :test, false)
end
