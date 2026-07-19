defmodule Gralkor.Lens.Store do
  @moduledoc false

  alias Gralkor.Lens

  @enforce_keys [:operator_id, :lens]
  defstruct [:operator_id, :lens]

  @type t :: %__MODULE__{
          operator_id: String.t(),
          lens: Lens.t()
        }
end
