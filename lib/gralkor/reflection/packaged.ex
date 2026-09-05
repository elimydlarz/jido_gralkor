defmodule Gralkor.Reflection.Packaged do
  @moduledoc false

  def definitions do
    [
      %{
        name: "generalisations",
        outputs: [
          %{
            kind: :destination,
            destination: "global",
            ontology: Gralkor.DefaultOntology
          }
        ],
        chain_of_thought: %{
          steps: [
            %{
              label: "inspect-world",
              directions: """
              Inspect every current lensed representation and all related stored
              information supplied to this Reflection. Treat current representations
              and Lens-authored stored episodes as observations. Treat stored artefacts
              declaring the generalisations Reflection as prior generalisations.
              Revisit current and related observations together with prior
              generalisations. Describe how the observations reinforce, qualify,
              conflict with, or connect the prior generalisations, and where they call
              for a new generalisation.
              """,
              output: %{"inspection" => "string"}
            },
            %{
              label: "evolve-generalisations",
              directions: """
              Evolve the generalisations in light of this inspection:

              {{inspection}}

              Carry forward, combine, broaden, narrow, split, replace, or otherwise
              revise generalisations as observations warrant. Return each current
              generalisation with its content, level, and lineage snapshots. Provide
              non-blank content for every current generalisation and lineage snapshot.
              A new generalisation with no lineage uses level 1. An evolved
              generalisation uses a level one greater than the highest level in its
              evolves_from snapshots.
              """,
              output: %{
                "generalisations" =>
                  "Array<{ content: string; level: integer; evolves_from: Array<{ content: string; level: integer }> }>"
              }
            }
          ]
        }
      },
      %{
        name: "erl",
        outputs: [
          %{
            kind: :destination,
            destination: "operator",
            ontology: Gralkor.Reflection.ERLOntology
          }
        ],
        chain_of_thought: %{
          steps: [
            %{
              label: "inspect-reasoning",
              directions: """
              Inspect the completed reasoning information supplied for this ingestion
              operation, including the problem, attempted approach, tool interactions,
              and outcome. Use any available tools when their results would materially
              improve the assessment.
              """,
              output: %{
                "reasoning_assessment" =>
                  "{ problem_kind: string; approach: string; outcome: string }"
              }
            },
            %{
              label: "derive-lesson",
              directions: """
              Derive an experiential learning candidate from this reasoning assessment:

              {{reasoning_assessment}}

              Determine whether the approach succeeded and state the reusable lesson
              supported by the completed reasoning information.
              """,
              output: %{
                "learning_candidate" =>
                  "{ problem_kind: string; approach: string; success: boolean; lesson: string }"
              }
            },
            %{
              label: "synthesise-artefact",
              directions: """
              Produce the final experiential-learning artefact from this candidate:

              {{learning_candidate}}

              Preserve the assessed problem kind, approach, success, and lesson exactly
              as structured fields.
              """,
              output: %{
                "problem_kind" => "string",
                "approach" => "string",
                "success" => "boolean",
                "lesson" => "string"
              }
            }
          ]
        }
      }
    ]
  end
end
