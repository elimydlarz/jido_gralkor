defmodule Gralkor.Reflection.ChainOfThoughtTest do
  use ExUnit.Case, async: true

  alias Gralkor.Reflection.ChainOfThought

  describe "if a structured-output declaration uses an unsupported type" do
    test "then parsing identifies that step and type" do
      for type <- ["float", "number", "map", "object", "'yes' | 'no'", "date", nil] do
        configuration = %{
          steps: [%{label: "review", directions: "Review evidence.", output: %{"result" => type}}]
        }

        assert {:error, {:invalid_output_type, "review", ^type}} =
                 ChainOfThought.from_config(configuration)
      end
    end
  end
end
