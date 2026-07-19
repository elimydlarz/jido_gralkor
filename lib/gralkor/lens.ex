defmodule Gralkor.Lens do
  @moduledoc false

  @type scope :: :operator | :global

  @enforce_keys [:name, :ontology, :scope, :ingestion]
  defstruct [:name, :ontology, :scope, :ingestion]

  @type t :: %__MODULE__{
          name: String.t(),
          ontology: module() | nil,
          scope: scope(),
          ingestion: module()
        }
end
