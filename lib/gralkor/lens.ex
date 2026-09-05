defmodule Gralkor.Lens do
  @moduledoc """
  Resolved definition of an appending memory Lens.

  A Lens combines a unique name, a registered `Gralkor.Destination`, an
  extraction ontology, and a module implementing `Gralkor.Lens.Ingestion`.
  Several Lenses and Reflections may use the same Destination.

  Consumers normally declare `write: :append` Lens definitions in a mounted
  agent's runtime configuration and resolve them through that agent's
  `JidoGralkor.Runtime`. `Gralkor.Client` also resolves definitions in
  `:jido_gralkor, :lenses` for direct application-compatibility calls. The
  resolved struct itself needs no write-mode field: its module identifies the
  appending write contract.
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
