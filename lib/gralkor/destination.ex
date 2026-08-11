defmodule Gralkor.Destination do
  @moduledoc "A named memory destination with a scoped address and extraction ontology."

  @enforce_keys [:name, :address, :ontology]
  defstruct [:name, :address, :ontology]

  @type t :: %__MODULE__{
          name: String.t(),
          address: String.t(),
          ontology: module()
        }

  @spec graph_id(t(), String.t()) :: String.t()
  def graph_id(%__MODULE__{address: "operator/memory"}, operator_id),
    do: Gralkor.Client.sanitize_group_id(operator_id)

  def graph_id(%__MODULE__{address: "operator/" <> path}, operator_id),
    do: "destination_o_" <> encode(operator_id) <> "_" <> encode(path)

  def graph_id(%__MODULE__{address: "global/" <> path}, _operator_id),
    do: "destination_g_" <> encode(path)

  defp encode(value), do: Base.encode16(value, case: :lower)
end
