defmodule JidoGralkor.RuntimeValidationTest do
  use ExUnit.Case, async: true

  alias JidoGralkor.Runtime

  describe "if runtime configuration is not a map" do
    test "then validation identifies the configured value" do
      assert {:error, {:invalid_configuration, :not_a_map}} = validate(:not_a_map)
    end
  end

  defp validate(configuration) do
    Runtime.validate(configuration,
      packaged_reflections: fn -> [] end,
      parse_chain_of_thought: &parse_chain_of_thought/1
    )
  end

  defp parse_chain_of_thought(%{steps: []}) do
    {:ok, %Gralkor.Reflection.ChainOfThought{steps: []}}
  end
end
