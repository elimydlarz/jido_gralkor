defmodule Gralkor.Lens do
  @moduledoc """
  Application-owned definition of a memory Lens.

  A Lens combines a unique name, a registered `Gralkor.Destination`, an
  extraction ontology, and a module implementing `Gralkor.Lens.Ingestion`.
  Several Lenses and Reflections may use the same Destination.

  Consumers normally register Lens definitions in `:jido_gralkor, :lenses`
  and resolve them through `Gralkor.Client`, rather than constructing this
  struct directly.
  """

  @enforce_keys [:name, :destination, :ontology, :ingestion]
  defstruct [:name, :destination, :ontology, :ingestion]

  @type t :: %__MODULE__{
          name: String.t(),
          destination: Gralkor.Destination.t(),
          ontology: module(),
          ingestion: module()
        }
end
