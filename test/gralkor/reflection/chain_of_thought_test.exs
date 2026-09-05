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

  describe "if an output name is declared by more than one step" do
    test "then parsing identifies the output and both declaring steps" do
      steps = [step("first", %{"finding" => "string"}), step("second", %{"finding" => "string"})]

      assert {:error, {:duplicate_output, "finding", "first", "second"}} =
               ChainOfThought.from_config(%{steps: steps})
    end
  end

  describe "if an interpolation references an output not declared by an earlier step" do
    test "then parsing identifies the interpolation and current step" do
      first = %{step("first", %{"finding" => "string"}) | directions: "Inspect {{ finding }}."}
      later = step("second", %{"approved" => "boolean"})

      assert {:error, {:unknown_interpolation, "finding", "first"}} =
               ChainOfThought.from_config(%{steps: [first, later]})

      forward = %{first | directions: "Inspect {{ approved }}."}

      assert {:error, {:unknown_interpolation, "approved", "first"}} =
               ChainOfThought.from_config(%{steps: [forward, later]})
    end
  end

  describe "when a value is checked against a consumed structured-output type" do
    test "then string, boolean, and integer declarations enforce their corresponding JSON value types" do
      for {type, valid, invalid} <- [
            {"string", ["", "release"], [nil, true, 1, %{}]},
            {"boolean", [true, false], ["true", 0, 1, nil]},
            {"integer", [0, -1, 42], [1.0, "1", true, nil]}
          ] do
        for value <- valid, do: assert(ChainOfThought.matches_type?(value, type))
        for value <- invalid, do: refute(ChainOfThought.matches_type?(value, type))
      end
    end

    test "and arrays and exact objects recursively enforce their declared consumed types" do
      type = "Array<{ content: string; history: Array<{ level: integer; accepted: boolean }> }>"
      value = [%{"content" => "trial", "history" => [%{"level" => 1, "accepted" => true}]}]
      assert ChainOfThought.matches_type?(value, type)

      invalid = [%{"content" => "trial", "history" => [%{"level" => "1", "accepted" => true}]}]
      refute ChainOfThought.matches_type?(invalid, type)
      refute ChainOfThought.matches_type?(%{}, type)
    end
  end

  describe "when a value is checked against a consumed structured-output type > while the value has the declared shape and types" do
    test "then it matches" do
      assert ChainOfThought.matches_type?([], "Array<string>")
      assert ChainOfThought.matches_type?([[1], [2, 3]], "Array<Array<integer>>")
      assert ChainOfThought.matches_type?(%{"accepted" => false}, "{ accepted: boolean }")
      assert ChainOfThought.matches_type?(%{accepted: true}, "{ accepted: boolean }")
    end
  end

  describe "when a value is checked against a consumed structured-output type > while an exact object has a missing, extra, or mistyped field" do
    test "then it does not match" do
      for value <- [%{}, %{"level" => 1, "extra" => 2}, %{"level" => "1"}, nil, []] do
        refute ChainOfThought.matches_type?(value, "{ level: integer }")
      end
    end
  end

  describe "when natural-language directions contain output interpolations" do
    test "then their referenced output names are returned in occurrence order" do
      assert ChainOfThought.interpolations("{{ first }} then {{second-output}} and {{ first }}") ==
               ["first", "second-output", "first"]

      assert ChainOfThought.interpolations("Review evidence.") == []
    end
  end

  defp step(label, output) do
    %{label: label, directions: "Review the supplied evidence.", output: output}
  end
end
