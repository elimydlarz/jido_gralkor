defmodule Gralkor.Lens.Replaceable do
  @enforce_keys [:name, :scope, :graph_format]
  defstruct [:name, :scope, :graph_format]

  @type t :: %__MODULE__{
          name: String.t(),
          scope: Gralkor.Lens.scope(),
          graph_format: atom()
        }
end
