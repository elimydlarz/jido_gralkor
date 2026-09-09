defmodule JidoGralkor.MemorySearchPresentationTest do
  use ExUnit.Case, async: true
  alias JidoGralkor.MemorySearchPresentation, as: Presentation

  describe "when the memory search formatter is called" do
    test "then Lens groups use `Lens: <name>` headings" do
      assert rendered([fact("Use retries", [%{lens: "jira"}])]) == "Lens: jira\n- Use retries"
    end
  end

  describe "when the memory search formatter is called" do
    test "and Reflection groups use `Reflection: <name>` headings" do
      assert rendered([fact("Use canaries", [%{reflection: "lessons"}])]) == "Reflection: lessons\n- Use canaries"
    end
  end

  describe "when the memory search formatter is called" do
    test "and each fact is presented as one bullet with its complete text" do
      assert rendered([fact("First\ncontinued", [%{lens: "notes"}]), fact("Second", [%{lens: "notes"}])]) == "Lens: notes\n- First\ncontinued\n- Second"
    end
  end

  describe "when the memory search formatter is called" do
    test "and groups retain first-appearance order with retrieval order inside each group" do
      assert rendered([fact("one", [%{lens: "z"}]), fact("two", [%{lens: "a"}]), fact("three", [%{lens: "z"}])]) == "Lens: z\n- one\n- three\n\nLens: a\n- two"
    end
  end

  describe "when the memory search formatter is called" do
    test "and repeated provenance for one source adds no duplicate bullet for that fact" do
      assert rendered([fact("one", [%{lens: "x", id: "a"}, %{lens: "x", id: "b"}])]) == "Lens: x\n- one"
    end
  end

  describe "when the memory search formatter is called" do
    test "and facts with several named sources appear under each distinct source" do
      assert rendered([fact("shared", [%{lens: "notes"}, %{reflection: "lessons"}])]) == "Lens: notes\n- shared\n\nReflection: lessons\n- shared"
    end
  end

  describe "when the memory search formatter is called" do
    test "and unnamed provenance is grouped under `Source: unknown`" do
      assert rendered([fact("one", []), fact("two", [%{source_description: "legacy"}])]) == "Source: unknown\n- one\n- two"
    end
  end

  describe "when the memory search formatter is called" do
    test "and the formatter adds no Destination, artefact, level, or lineage metadata" do
      input = fact("Use canaries", [%{reflection: "lessons", id: "episode-id"}]) |> Map.put(:artefact, %{id: "artefact-id", payload: %{level: 2, evolves_from: ["old"]}})
      assert rendered([input]) == "Reflection: lessons\n- Use canaries"
    end
  end

  describe "when the memory search formatter is called" do
    test "and the structured input remains unchanged" do
      input = [fact("one", [%{lens: "notes", id: "source-id"}])]
      assert rendered(input) == "Lens: notes\n- one"
      assert input == [fact("one", [%{lens: "notes", id: "source-id"}])]
    end
  end

  describe "when the memory search formatter is called > while no facts are supplied" do
    test "then the text explicitly states that no matching facts were found" do
      assert rendered([]) == "No matching facts."
    end
  end

  describe "when formatted fact results must fit response limits" do
    test "then an exact-fit response retains every complete fact" do
      expected = %{result: "Lens: notes\n- one"}
      assert Presentation.for_model([fact("one", [%{lens: "notes"}])], envelope_bytes(expected)) == {:ok, expected}
    end
  end

  describe "when formatted fact results must fit response limits" do
    test "and headings and omission notices count towards the 16384-character ceiling" do
      content = String.duplicate("x", 16_384 - String.length("Lens: notes\n- "))
      assert String.length(rendered([fact(content, [%{lens: "notes"}])])) == 16_384
      assert rendered([fact(content <> "x", [%{lens: "notes"}])]) == "Omitted facts: 1 (response limit)."
    end
  end

  describe "when formatted fact results must fit response limits" do
    test "and UTF-8 bytes and JSON escaping count towards the complete-envelope byte budget" do
      input = [fact(String.duplicate("λ\n\"", 40), [%{lens: "notes"}])]
      text = rendered(input)
      bytes = envelope_bytes(%{result: text})
      assert Presentation.for_model(input, bytes) == {:ok, %{result: text}}
      assert Presentation.for_model(input, bytes - 1) == {:ok, %{result: "Omitted facts: 1 (response limit)."}}
    end
  end

  describe "when formatted fact results must fit response limits" do
    test "and a fact that exceeds either limit is omitted whole while later fitting facts remain eligible" do
      input = [fact(String.duplicate("x", 17_000), [%{lens: "notes"}]), fact("small", [%{lens: "notes"}])]
      assert rendered(input) == "Lens: notes\n- small\n\nOmitted facts: 1 (response limit)."
      assert {:ok, %{result: same}} = Presentation.for_model(input, 200)
      assert same == rendered(input)
    end
  end

  describe "when formatted fact results must fit response limits" do
    test "and the omission notice counts excluded input facts once regardless of their source count" do
      input = [fact(String.duplicate("x", 17_000), [%{lens: "a"}, %{lens: "b"}])]
      assert rendered(input) == "Omitted facts: 1 (response limit)."
    end
  end

  describe "when formatted fact results must fit response limits > while the budget cannot contain the empty response and required notice" do
    test "then an explicit error reports the required minimum bytes" do
      input = [fact("one", [%{lens: "notes"}])]
      minimum = envelope_bytes(%{result: "Omitted facts: 1 (response limit)."})
      assert Presentation.for_model(input, 1) == {:error, {:memory_search_budget_too_small, %{max_bytes: 1, minimum_bytes: minimum}}}
    end
  end

  describe "when formatted fact results must fit response limits > if the byte budget is not a positive integer" do
    test "then an argument error identifies the invalid budget" do
      for invalid <- [0, -1, nil, "100", 1.5] do
        assert_raise ArgumentError, ~r/memory_search_max_bytes.*positive integer/, fn -> Presentation.for_model([], invalid) end
      end
    end
  end

  describe "when the action validates a model byte budget before search" do
    test "then a positive integer is returned unchanged" do
      assert Presentation.validate_max_bytes!(1) == 1
      assert Presentation.validate_max_bytes!(65_536) == 65_536
    end
  end

  describe "when the action validates a model byte budget before search > if the budget is not a positive integer" do
    test "then an argument error identifies the invalid budget" do
      for invalid <- [0, -1, nil, "100", 1.5] do
        assert_raise ArgumentError, ~r/memory_search_max_bytes.*positive integer/, fn -> Presentation.for_model([], invalid) end
      end
    end
  end

  defp fact(text, sources), do: %{destination: "global", fact: %{fact: text, sources: sources}}
  defp rendered(input) do
    assert {:ok, %{result: text}} = Presentation.for_model(input, 65_536)
    text
  end
  defp envelope_bytes(output), do: byte_size(Jason.encode!(%{ok: true, result: output}))
end
