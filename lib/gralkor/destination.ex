defmodule Gralkor.Destination do
  @moduledoc "A named memory destination with a scoped address and extraction ontology."

  @enforce_keys [:name, :address, :ontology]
  defstruct [:name, :address, :ontology]

  @type t :: %__MODULE__{
          name: String.t(),
          address: String.t(),
          ontology: module()
        }
end
