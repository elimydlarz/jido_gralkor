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
    test "then a complete repository YAML Chain of Thought and named destination validate", %{root: root} do
      path = write_cot(root, "valid.yaml", """
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

      assert {:ok, [%Gralkor.Reflection{name: "generalisation", scope: :operator}]} =
               Registry.load(
                 [[name: "generalisation", chain_of_thought: Path.relative_to(path, root), scope: :operator]],
                 root: root
               )
    end
  end

  defp write_cot(root, name, body) do
    path = Path.join(root, name)
    File.write!(path, body)
    path
  end
end
