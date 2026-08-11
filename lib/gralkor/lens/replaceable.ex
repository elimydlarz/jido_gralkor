defmodule Gralkor.Lens.Replaceable do
  @moduledoc """
  Resolved definition of a Lens whose write unit is a complete graph.

  Consumers register definitions in `:jido_gralkor, :lenses` and resolve them
  through `Gralkor.Client` rather than constructing this struct directly.
  """

  @enforce_keys [:name, :destination, :graph_format]
  defstruct [:name, :destination, :graph_format]

  @type t :: %__MODULE__{
          name: String.t(),
          destination: Gralkor.Destination.t(),
          graph_format: :property_graph
        }
end
