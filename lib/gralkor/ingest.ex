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
  defstruct [:operator_id, :lens, :content, :source_description]

  @type t :: %__MODULE__{
          operator_id: String.t(),
          lens: String.t(),
          content: String.t(),
          source_description: String.t()
        }
end
