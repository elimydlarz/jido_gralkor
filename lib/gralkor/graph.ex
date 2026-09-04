defmodule Gralkor.Graph do
  @moduledoc """
  A complete graph payload supplied to `Gralkor.Client.replace/1`.

  Nodes have unique string identifiers, string labels, and property maps.
  Relationships identify two supplied nodes, a type, and a property map.
  """

  @enforce_keys [:nodes, :relationships]
  defstruct [:nodes, :relationships]

  @type properties :: %{optional(atom() | String.t()) => term()}
  @type graph_node :: %{
          required(:id) => String.t(),
          required(:labels) => [String.t()],
          required(:properties) => properties()
        }
  @type relationship :: %{
          required(:from) => String.t(),
          required(:to) => String.t(),
          required(:type) => String.t(),
          required(:properties) => properties()
        }
  @type t :: %__MODULE__{
          nodes: [graph_node()],
          relationships: [relationship()]
        }
end
