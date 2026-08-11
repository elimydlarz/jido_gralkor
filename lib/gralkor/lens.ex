defmodule Gralkor.Lens do
  @moduledoc """
  Application-owned definition of a memory Lens.

  A Lens combines a unique name, a registered `Gralkor.Destination`, and a
  module implementing `Gralkor.Lens.Ingestion`. The Destination supplies the
  address and extraction ontology. Several Lenses and Reflections may use the
  same Destination.

  Consumers normally register Lens definitions in `:jido_gralkor, :lenses`
  and resolve them through `Gralkor.Client`, rather than constructing this
  struct directly.
  """

  @enforce_keys [:name, :destination, :ingestion]
  defstruct [:name, :destination, :ingestion]

  @type t :: %__MODULE__{
          name: String.t(),
          destination: Gralkor.Destination.t(),
          ingestion: module()
        }
end
