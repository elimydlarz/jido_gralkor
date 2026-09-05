defmodule Gralkor.Lens.Replaceable do
  @moduledoc """
  Resolved definition of a Lens whose write unit is a complete graph.

  Consumers normally declare `write: :replace_graph` Lens definitions in a
  mounted agent's runtime configuration and resolve them through that agent's
  `JidoGralkor.Runtime`. `Gralkor.Client` also resolves definitions in
  `:jido_gralkor, :lenses` for direct application-compatibility calls. A
  replaceable Lens always accepts Gralkor's single `%Gralkor.Graph{}`
  representation, so it has no configurable graph format.
  """

  @enforce_keys [:name, :destination]
  defstruct [:name, :destination]

  @type t :: %__MODULE__{
          name: String.t(),
          destination: Gralkor.Destination.t()
        }
end
