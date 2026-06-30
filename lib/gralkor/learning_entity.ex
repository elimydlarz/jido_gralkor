defmodule Gralkor.LearningEntity do
  @moduledoc """
  The plugin's built-in graphiti custom entity type for ERL.

  `Learning` is declared as a graphiti custom entity type (the same shape a
  consumer's `use Gralkor.Ontology` entity takes) and merged onto every learning
  write's `entity_types` at the write boundary — additively over the consumer's
  configured ontology (or `nil`), so ERL is not gated on a configured ontology.
  Declaring `Learning` in `entity_types` causes graphiti's extractor to emit a
  `Learning`-typed node per learning episode and stamp the `"Learning"` label on
  it, so `SearchFilters(node_labels: ["Learning"])` (ex-recall) reliably returns
  only learning nodes.

  See `ex-learning-entity` in `TEST_TREES.md`.
  """

  @learning_name "Learning"

  @description "An experiential lesson the agent learned from attempting to solve a problem. " <>
                 "Extract a Learning entity from any text that records what was learned while " <>
                 "solving or attempting a task: the kind of problem faced, the approach taken, " <>
                 "whether it succeeded, and the reusable lesson. There is exactly one Learning " <>
                 "per such record."

  @spec spec() :: %{name: String.t(), description: String.t(), fields: [map()]}
  def spec do
    %{
      name: @learning_name,
      description: @description,
      fields: [
        %{name: :problem_kind, type: :string, required: false, doc: "the kind of problem approached"},
        %{name: :approach, type: :string, required: false, doc: "the approach taken"},
        %{name: :success, type: :boolean, required: false, doc: "whether it succeeded"},
        %{name: :lesson, type: :string, required: false, doc: "what was learned"}
      ]
    }
  end

  @doc """
  Union the `Learning` entity type onto a consumer's `entity_types` list.

  Additive — a consumer that intentionally declared its own `Learning` entity is
  not overridden.
  """
  @spec merge_entity_types([map()]) :: [map()]
  def merge_entity_types(entity_types) when is_list(entity_types) do
    if Enum.any?(entity_types, &(&1.name == @learning_name)) do
      entity_types
    else
      entity_types ++ [spec()]
    end
  end

  @doc """
  Merge `Learning` onto a consumer ontology payload (from `__ontology__/0`) or
  `nil`, preserving `edge_types`, `edge_type_map`, and `excluded_entity_types`.

  `nil` → a payload carrying only the `Learning` entity type, so ERL applies even
  when no consumer ontology is configured.
  """
  @spec merge_ontology_payload(map() | nil) :: map()
  def merge_ontology_payload(nil) do
    %{
      entity_types: [spec()],
      edge_types: [],
      edge_type_map: [],
      excluded_entity_types: nil
    }
  end

  def merge_ontology_payload(payload) when is_map(payload) do
    %{payload | entity_types: merge_entity_types(payload.entity_types || [])}
  end
end
