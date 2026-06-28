defmodule Gralkor.TaskKind do
  @moduledoc """
  Classify an incoming task into just its `problem_kind` — the seed for ERL
  recall. Cheaper than `Gralkor.Learn`: it emits only the kind, not the full
  learning record, so a consumer can recall the learnings that came from the
  same kind of problem at task start.

  Same `*_fn` + schema shape as the other evaluators; production wiring lives in
  `Gralkor.Client.Native`.

  See `ex-task-kind` in `TEST_TREES.md`.
  """

  @type classify_fn :: (String.t() -> {:ok, String.t()} | {:error, term()})

  @doc """
  Classify `task` into its problem kind.

  Raises `ArgumentError` when `task` is blank. Returns `{:error, reason}` when
  `classify_fn` fails.
  """
  @spec classify(String.t(), classify_fn()) :: {:ok, String.t()} | {:error, term()}
  def classify(task, classify_fn) when is_function(classify_fn, 1) do
    raise_if_blank!(task)
    classify_fn.(prompt(task))
  end

  @doc "Schema for the structured-output response classifying a task into a kind."
  @spec classify_schema() :: keyword()
  def classify_schema do
    [
      problem_kind: [
        type: :string,
        required: true,
        doc: "The kind of problem this incoming task is approaching (a short, reusable category)."
      ]
    ]
  end

  # ── internal ────────────────────────────────────────────────

  defp prompt(task) do
    """
    Classify the following incoming task into the kind of problem it is
    approaching — a short, reusable category, not a restatement.

    Task:
    #{task}
    """
  end

  defp raise_if_blank!(task) when is_binary(task) do
    if String.trim(task) == "" do
      raise ArgumentError, "task must be a non-blank string, got #{inspect(task)}"
    end

    :ok
  end

  defp raise_if_blank!(other) do
    raise ArgumentError, "task must be a non-blank string, got #{inspect(other)}"
  end
end
