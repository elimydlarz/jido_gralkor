defmodule Gralkor.AgentLearning do
  @moduledoc """
  One flat experiential-learning record: what kind of problem was approached,
  the approach taken, whether it succeeded, and the lesson learned.

  No ERL-internal edges — it is a single node so ERL recall is single-label and
  never traverses. `to_episode/1` renders it into a well-formed episode body
  graphiti ingests into the same `group_id` as ordinary memory; the body states
  the `problem_kind` and the outcome so a problem-kind-seeded hybrid search
  surfaces it, with the success bias living in the text. Any domain entities the
  `lesson` mentions are linked to the consumer's `Learning` node by graphiti.

  See `ex-agent-learning` in `TEST_TREES.md`.
  """

  @enforce_keys [:problem_kind, :approach, :success, :lesson]
  defstruct [:problem_kind, :approach, :success, :lesson]

  @type t :: %__MODULE__{
          problem_kind: String.t(),
          approach: String.t(),
          success: boolean(),
          lesson: String.t()
        }

  @doc """
  Render the learning into the episode body graphiti ingests and recalls by
  problem kind.
  """
  @spec to_episode(t()) :: String.t()
  def to_episode(%__MODULE__{} = learning) do
    """
    The agent recorded a Learning titled "#{learning.problem_kind}".
    This Learning is a reusable lesson acquired from solving a problem.
    The Learning's problem kind: #{learning.problem_kind}.
    The Learning's approach: #{learning.approach}
    The Learning's outcome: the approach #{outcome(learning.success)}.
    The Learning's lesson: #{learning.lesson}
    """
    |> String.trim()
  end

  defp outcome(true), do: "succeeded"
  defp outcome(false), do: "did not succeed"
end
