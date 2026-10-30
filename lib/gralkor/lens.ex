defmodule Gralkor.Lens do
  @moduledoc """
  Resolved definition of a memory Lens.

  A Lens combines a unique name, a registered `Gralkor.Destination`, an
  extraction ontology, and a module implementing `Gralkor.Lens.Ingestion`.
  Several Lenses and Reflections may use the same Destination.

  Consumers normally declare Lens definitions in a mounted agent's runtime
  configuration and resolve them through that agent's `JidoGralkor.Runtime`.
  `Gralkor.Client` also resolves definitions in `:jido_gralkor, :lenses` for
  direct application-compatibility calls.
  """

  @enforce_keys [:name, :destination, :ontology, :ingestion]
  defstruct [:name, :destination, :ontology, :ingestion]

  @type t :: %__MODULE__{
          name: String.t(),
          destination: Gralkor.Destination.t(),
          ontology: module(),
          ingestion: module()
        }

  @doc "Migration guidance for a definition that retains the removed `:write` field."
  @spec removed_write_guidance() :: String.t()
  def removed_write_guidance do
    ":write was removed with replacement Lenses; delete it from appending Lenses and delete any `write: :replace_graph` Lens"
  end
end
