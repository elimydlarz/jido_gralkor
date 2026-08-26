defmodule Gralkor.Destination do
  @moduledoc "A named graph destination."

  @enforce_keys [:name]
  defstruct [:name]

  @type t :: %__MODULE__{
          name: String.t()
        }

  @spec graph_id(t(), String.t()) :: String.t()
  def graph_id(%__MODULE__{name: "operator"}, operator_id), do: "operator/" <> operator_id
  def graph_id(%__MODULE__{name: name}, _operator_id), do: "destination_" <> name
end
