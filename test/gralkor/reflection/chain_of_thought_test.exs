defmodule Gralkor.Reflection.ChainOfThoughtTest do
  use ExUnit.Case, async: true

  alias Gralkor.Reflection.ChainOfThought
  alias Gralkor.Reflection.ChainOfThought.Step

  describe "when structured Chain of Thought configuration contains one or more ordered steps > while the configuration and steps use maps" do
    test "then parsing returns the steps in declaration order" do
      first = step("first", %{"findings" => "string"})
      second = step("second", %{"approved" => "boolean"})

      assert {:ok, %ChainOfThought{steps: steps}} =
               ChainOfThought.from_config(%{steps: [first, second]})

      assert Enum.map(steps, & &1.label) == ["first", "second"]
    end

    test "and every parsed step retains its label, directions, and structured-output declaration" do
      definition = step("review", %{"findings" => "Array<{ content: string; level: integer }>"})

      assert {:ok, %ChainOfThought{steps: [parsed]}} =
               ChainOfThought.from_config(%{"steps" => [definition]})

      assert parsed == struct!(Step, definition)
    end
  end

  describe "when structured Chain of Thought configuration contains one or more ordered steps > while the configuration and steps use keyword lists" do
    test "then parsing returns the same structured Chain of Thought" do
      definition = step("review", %{"findings" => "string"})

      assert ChainOfThought.from_config(steps: [Map.to_list(definition)]) ==
               ChainOfThought.from_config(%{steps: [definition]})
    end
  end

  describe "if Chain of Thought configuration has no non-empty steps list" do
    test "then parsing reports missing steps" do
      for configuration <- [%{}, %{steps: []}, %{steps: nil}, %{steps: "review"}, :invalid] do
        assert {:error, :missing_steps} = ChainOfThought.from_config(configuration)
      end
    end
  end

  describe "if a Chain of Thought step is not structured configuration" do
    test "then parsing identifies that step" do
      for invalid <- ["review", 42, nil, :invalid] do
        assert {:error, {:invalid_step, ^invalid}} =
                 ChainOfThought.from_config(%{steps: [invalid]})
      end
    end
  end

  describe "if a Chain of Thought step has a missing or blank label" do
    test "then parsing identifies the invalid label" do
      for label <- [nil, "", "  ", 42] do
        assert {:error, {:invalid_step_label, ^label}} =
                 ChainOfThought.from_config(%{steps: [step(label, %{"result" => "string"})]})
      end
    end
  end

  describe "if a Chain of Thought step has missing or blank natural-language directions" do
    test "then parsing identifies that step's invalid directions" do
      for directions <- [nil, "", "  ", 42] do
        definition = Map.put(step("review", %{"result" => "string"}), :directions, directions)

        assert {:error, {:invalid_step_directions, "review"}} =
                 ChainOfThought.from_config(%{steps: [definition]})
      end
    end
  end

  describe "if a Chain of Thought step has a missing or empty structured-output declaration" do
    test "then parsing identifies that step's invalid output" do
      for output <- [nil, %{}, [], "string"] do
        assert {:error, {:invalid_step_output, "review"}} =
                 ChainOfThought.from_config(%{steps: [step("review", output)]})
      end
    end
  end

  describe "if a structured-output declaration has a blank output name" do
    test "then parsing identifies that step and invalid declaration" do
      for name <- ["", "  "] do
        assert {:error, {:invalid_output_name, "review", ^name}} =
                 ChainOfThought.from_config(%{steps: [step("review", %{name => "string"})]})
      end
    end
  end

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

  defp step(label, output) do
    %{label: label, directions: "Review the supplied evidence.", output: output}
  end
end
