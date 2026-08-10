defmodule Gralkor.Reflection.ERLOntology do
  use Gralkor.Ontology, entities: :open, relationships: :open

  entity Learning,
         "An experiential lesson the agent learned while attempting to solve a problem. Extract one Learning from a record of the problem kind, approach, outcome, and reusable lesson." do
    field(:problem_kind, :string, required: false)
    field(:approach, :string, required: false)
    field(:success, :boolean, required: false)
    field(:lesson, :string, required: false)
  end
end
