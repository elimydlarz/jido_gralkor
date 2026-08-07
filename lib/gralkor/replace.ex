defmodule Gralkor.Replace do
  @enforce_keys [:operator_id, :lens, :graph]
  defstruct [:operator_id, :lens, :graph]

  @type t :: %__MODULE__{
          operator_id: String.t(),
          lens: String.t(),
          graph: Gralkor.Graph.t()
        }
end
