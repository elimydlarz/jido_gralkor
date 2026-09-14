defmodule Gralkor.Destination do
  @moduledoc "A named graph destination."

  @enforce_keys [:name]
  defstruct [:name]

  @type t :: %__MODULE__{
          name: String.t()
        }

  @spec graph_id(t(), String.t()) :: String.t()
  def graph_id(%__MODULE__{name: "personal"}, operator_id) do
    validate_operator_id!(operator_id)
    "personal/" <> operator_id
  end

  def graph_id(%__MODULE__{name: "operator"}, _operator_id) do
    raise ArgumentError,
          "Destination \"operator\" was retired; migrate its graph and select \"personal\""
  end

  def graph_id(%__MODULE__{name: name}, _operator_id), do: name

  @spec validate_operator_id!(term()) :: :ok
  def validate_operator_id!(operator_id) do
    unless is_binary(operator_id) and String.trim(operator_id) != "" and
             not String.starts_with?(operator_id, ["personal/", "operator/"]) do
      raise ArgumentError,
            "operator_id must be a non-blank identity, not a resolved private graph, got #{inspect(operator_id)}"
    end

    :ok
  end
end
