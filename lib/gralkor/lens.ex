defmodule Gralkor.Lens do
  @moduledoc """
  Application-owned definition of a memory Lens.

  A Lens combines a unique name, a `Gralkor.Ontology`, a storage scope, and a
  module implementing `Gralkor.Lens.Ingestion`. `:operator` scope isolates
  storage by operator and Lens name. `:global` scope writes to the shared
  global group while retaining the Lens name as provenance.

  Consumers normally register Lens definitions in `:jido_gralkor, :lenses`
  and resolve them through `Gralkor.Client`, rather than constructing this
  struct directly.
  """

  @type scope :: :operator | :global

  @enforce_keys [:name, :destination, :ingestion]
  defstruct [:name, :destination, :ingestion]

  @type t :: %__MODULE__{
          name: String.t(),
          destination: Gralkor.Destination.t(),
          ingestion: module()
        }
end
