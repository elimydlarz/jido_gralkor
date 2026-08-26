defmodule Gralkor.Ingest do
  @moduledoc """
  A request to ingest content through a registered `Gralkor.Lens`.

  `operator_id` identifies the operator whose local Lens group is used; global
  Lenses ignore it for storage placement. `lens` is the registered Lens name.
  Gralkor resolves that definition before invoking its ingestion process, so
  callers provide content and source context rather than ontology or group
  details.
  """

  @enforce_keys [:operator_id, :lens, :content, :source_description]
  defstruct [:operator_id, :lens, :source_kind, :content, :source_description, :evidence_id]

  @type source_kind :: :conversation | :document | :structured_record

  @type t ::
          %__MODULE__{
            operator_id: String.t(),
            lens: String.t(),
            source_kind: :conversation,
            content: String.t(),
            source_description: String.t(),
            evidence_id: String.t() | nil
          }
          | %__MODULE__{
              operator_id: String.t(),
              lens: String.t(),
              source_kind: :document,
              content: String.t(),
              source_description: String.t(),
              evidence_id: String.t() | nil
            }
          | %__MODULE__{
              operator_id: String.t(),
              lens: String.t(),
              source_kind: :structured_record,
              content: map() | list(),
              source_description: String.t(),
              evidence_id: String.t() | nil
            }
end
