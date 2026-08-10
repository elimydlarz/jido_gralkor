defmodule Gralkor.ReflectionSystemFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Reflection.Registry

  setup do
    root = Path.join(System.tmp_dir!(), "gralkor-reflection-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  describe "when Reflection declarations are validated" do
    test "while every Reflection has a non-blank name", context, do: assert_valid(context)
    test "and every Reflection name is unique", context, do: assert_valid(context)
    test "and every Reflection references a repository YAML Chain of Thought", context, do: assert_valid(context)
    test "and every referenced Chain of Thought contains one or more ordered steps", context, do: assert_valid(context)
    test "and every step has a non-blank label and natural-language directions", context, do: assert_valid(context)
    test "and every step declares one or more named structured outputs and their types", context, do: assert_valid(context)
    test "and output names are unique across the Chain of Thought", context, do: assert_valid(context)
    test "and every interpolation references an output from an earlier step", context, do: assert_valid(context)
    test "and every Reflection destination is named by its Reflection and has operator or global scope then validation succeeds", context,
      do: assert_valid(context)

    test "if a Reflection name is blank then validation fails identifying the blank name", %{root: root} do
      assert {:error, {:blank_name, " "}} = Registry.load([valid_definition(root, name: " ")], root: root)
    end

    test "if Reflection names are duplicated then validation fails identifying the duplicate name", %{root: root} do
      definition = valid_definition(root)
      assert {:error, {:duplicate_name, "generalisation"}} = Registry.load([definition, definition], root: root)
    end

    test "if a Reflection has no Chain of Thought then validation fails identifying that Reflection", %{root: root} do
      definition = valid_definition(root) |> Keyword.delete(:chain_of_thought)
      assert {:error, {:missing_chain_of_thought, "generalisation"}} = Registry.load([definition], root: root)
    end

    test "if a Reflection's Chain of Thought does not identify a repository YAML file then validation fails identifying that Reflection and file", %{root: root} do
      assert {:error, {:invalid_chain_of_thought_file, "generalisation", "../outside.yaml"}} =
               Registry.load([valid_definition(root, chain_of_thought: "../outside.yaml")], root: root)
    end

    test "if a Reflection's Chain of Thought YAML cannot be loaded or parsed then validation fails identifying that Reflection, file, and parse failure", %{root: root} do
      write_cot(root, "broken.yaml", "steps: [")
      assert {:error, {:invalid_chain_of_thought, "generalisation", "broken.yaml", _}} =
               Registry.load([valid_definition(root, chain_of_thought: "broken.yaml")], root: root)
    end

    test "if a Chain of Thought has no steps then validation fails identifying that Reflection and Chain of Thought", %{root: root} do
      write_cot(root, "empty.yaml", "steps: []")
      assert {:error, {:invalid_chain_of_thought, "generalisation", "empty.yaml", :missing_steps}} =
               Registry.load([valid_definition(root, chain_of_thought: "empty.yaml")], root: root)
    end

    test "if a Chain of Thought step has no non-blank label then validation fails identifying that Reflection and step", %{root: root} do
      write_cot(root, "blank-label.yaml", "steps:\n  - label: ' '\n    directions: Think.\n    output: {result: string}\n")
      assert {:error, {:invalid_chain_of_thought, "generalisation", "blank-label.yaml", {:invalid_step_label, " "}}} =
               Registry.load([valid_definition(root, chain_of_thought: "blank-label.yaml")], root: root)
    end

    test "if a Chain of Thought step has no natural-language directions then validation fails identifying that Reflection and step", %{root: root} do
      write_cot(root, "no-directions.yaml", "steps:\n  - label: think\n    output: {result: string}\n")
      assert {:error, {:invalid_chain_of_thought, "generalisation", "no-directions.yaml", {:invalid_step_directions, "think"}}} =
               Registry.load([valid_definition(root, chain_of_thought: "no-directions.yaml")], root: root)
    end

    test "if a Chain of Thought step has no structured-output declaration then validation fails identifying that Reflection and step", %{root: root} do
      write_cot(root, "no-output.yaml", "steps:\n  - label: think\n    directions: Think.\n")
      assert {:error, {:invalid_chain_of_thought, "generalisation", "no-output.yaml", {:invalid_step_output, "think"}}} =
               Registry.load([valid_definition(root, chain_of_thought: "no-output.yaml")], root: root)
    end

    test "if an output name is declared by more than one step then validation fails identifying that Reflection, output name, and steps", %{root: root} do
      write_cot(root, "duplicate-output.yaml", "steps:\n  - {label: one, directions: First., output: {result: string}}\n  - {label: two, directions: Second., output: {result: string}}\n")
      assert {:error, {:invalid_chain_of_thought, "generalisation", "duplicate-output.yaml", {:duplicate_output, "result", "two"}}} =
               Registry.load([valid_definition(root, chain_of_thought: "duplicate-output.yaml")], root: root)
    end

    test "if an interpolation references an output not declared by an earlier step then validation fails identifying that Reflection, step, and interpolation", %{root: root} do
      write_cot(root, "forward.yaml", "steps:\n  - label: one\n    directions: Use {{later}}.\n    output: {first: string}\n  - {label: two, directions: Later., output: {later: string}}\n")
      assert {:error, {:invalid_chain_of_thought, "generalisation", "forward.yaml", {:unknown_interpolation, "later", "one"}}} =
               Registry.load([valid_definition(root, chain_of_thought: "forward.yaml")], root: root)
    end

    test "if a Reflection has no destination scope then validation fails identifying that Reflection", %{root: root} do
      definition = valid_definition(root) |> Keyword.delete(:scope)
      assert {:error, {:invalid_destination_scope, "generalisation", nil}} = Registry.load([definition], root: root)
    end

    test "if a Reflection's destination scope is neither operator nor global then validation fails identifying that Reflection and destination scope", %{root: root} do
      assert {:error, {:invalid_destination_scope, "generalisation", :private}} =
               Registry.load([valid_definition(root, scope: :private)], root: root)
    end
  end

  defp assert_valid(%{root: root}) do
    assert {:ok, [%Gralkor.Reflection{name: "generalisation", scope: :operator}]} =
             Registry.load([valid_definition(root)], root: root)
  end

  defp valid_definition(root, overrides \\ []) do
    unless File.exists?(Path.join(root, "valid.yaml")) do
      write_cot(root, "valid.yaml", """
      steps:
        - label: gather
          directions: Gather evidence.
          output:
            facts: Array<string>
        - label: synthesise
          directions: "Synthesise {{facts}}"
          output:
            artefact: string
      """)
    end

    Keyword.merge(
      [name: "generalisation", chain_of_thought: "valid.yaml", scope: :operator],
      overrides
    )
  end

  defp write_cot(root, name, body) do
    path = Path.join(root, name)
    File.write!(path, body)
    path
  end
end
