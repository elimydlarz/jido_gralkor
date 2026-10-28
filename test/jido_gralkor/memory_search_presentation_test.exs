defmodule JidoGralkor.MemorySearchPresentationTest do
  use ExUnit.Case, async: true
  alias JidoGralkor.MemorySearchPresentation, as: Presentation

  @omitted_one_fact "Omitted (response limit): facts 1, entities 0, episodes 0."

  describe "when the memory search formatter is called" do
    test "then facts from every Destination appear first under a `Facts` heading, then entities under an `Entities` heading, then episodes under an `Episodes` heading" do
      input = [
        result("first", [fact("first fact", [%{lens: "notes"}])], [entity("Atlas")], [
          episode("first episode", %{lens: "notes"})
        ]),
        result("second", [fact("second fact", [%{lens: "notes"}])], [entity("Borealis")], [])
      ]

      assert rendered(input) ==
               "Facts\n\nLens: notes\n- first fact\n- second fact\n\n" <>
                 "Entities\n- Atlas\n- Borealis\n\n" <>
                 "Episodes\n- [Lens: notes] first episode"
    end

    test "and a section with nothing to show is left out" do
      assert rendered([result("global", [], [entity("Atlas")], [])]) == "Entities\n- Atlas"
    end

    test "and the formatter adds no Destination, artefact level, or lineage metadata" do
      input =
        fact("Use canaries", [%{reflection: "lessons", id: "episode-id"}])
        |> Map.put(:artefact, %{id: "artefact-id", payload: %{level: 2, evolves_from: ["old"]}})

      assert rendered(facts([input])) == "Facts\n\nReflection: lessons\n- Use canaries"
    end

    test "and the structured input remains unchanged" do
      input = facts([fact("one", [%{lens: "notes", id: "source-id"}])])
      assert rendered(input) == "Facts\n\nLens: notes\n- one"
      assert input == facts([fact("one", [%{lens: "notes", id: "source-id"}])])
    end
  end

  describe "when the memory search formatter is called > while no facts, entities, or episodes are supplied" do
    test "then the text explicitly states that no matching memory was found" do
      assert rendered([]) == "No matching memory."
      assert rendered([result("global", [], [], [])]) == "No matching memory."
    end
  end

  describe "when the formatter presents facts" do
    test "then Lens groups use `Lens: <name>` headings" do
      assert rendered(facts([fact("Use retries", [%{lens: "jira"}])])) ==
               "Facts\n\nLens: jira\n- Use retries"
    end

    test "and Reflection groups use `Reflection: <name>` headings" do
      assert rendered(facts([fact("Use canaries", [%{reflection: "lessons"}])])) ==
               "Facts\n\nReflection: lessons\n- Use canaries"
    end

    test "and each fact is presented as one bullet with its complete text" do
      assert rendered(
               facts([
                 fact("First\ncontinued", [%{lens: "notes"}]),
                 fact("Second", [%{lens: "notes"}])
               ])
             ) == "Facts\n\nLens: notes\n- First\ncontinued\n- Second"
    end

    test "and groups retain first-appearance order with retrieval order inside each group" do
      assert rendered(
               facts([
                 fact("one", [%{lens: "z"}]),
                 fact("two", [%{lens: "a"}]),
                 fact("three", [%{lens: "z"}])
               ])
             ) == "Facts\n\nLens: z\n- one\n- three\n\nLens: a\n- two"
    end

    test "and repeated provenance for one source adds no duplicate bullet for that fact" do
      assert rendered(facts([fact("one", [%{lens: "x", id: "a"}, %{lens: "x", id: "b"}])])) ==
               "Facts\n\nLens: x\n- one"
    end

    test "and facts with several named sources appear under each distinct source" do
      assert rendered(facts([fact("shared", [%{lens: "notes"}, %{reflection: "lessons"}])])) ==
               "Facts\n\nLens: notes\n- shared\n\nReflection: lessons\n- shared"
    end

    test "and known direct provenance identifies its source kind without a Lens or Reflection heading" do
      for {kind, name} <- [
            {:conversation, "conversation"},
            {"document", "document"},
            {:structured_record, "structured record"}
          ] do
        assert rendered(facts([fact("one", [%{writer: :direct, source_kind: kind}])])) ==
                 "Facts\n\nSource: direct #{name}\n- one"
      end

      assert rendered(facts([fact("one", [%{writer: :direct}])])) ==
               "Facts\n\nSource: direct\n- one"
    end

    test "and unnamed provenance is grouped under `Source: unknown`" do
      assert rendered(facts([fact("one", []), fact("two", [%{source_description: "legacy"}])])) ==
               "Facts\n\nSource: unknown\n- one\n- two"
    end
  end

  describe "when the formatter presents entities" do
    test "then each entity is presented as one bullet with its complete name, summary, and attributes" do
      node = %{
        name: "parse/1",
        summary: "Parses the whole input " <> String.duplicate("carefully ", 60),
        attributes: %{"module" => "Lexer", "arity" => "1"}
      }

      assert rendered([result("global", [], [node], [])]) ==
               "Entities\n- parse/1: #{node.summary} (arity: 1, module: Lexer)"
    end
  end

  describe "when the formatter presents episodes" do
    test "then each episode is presented as one bullet labelled with its originating Lens, Reflection, or source kind" do
      episodes = [
        episode("from a lens", %{lens: "notes"}),
        episode("from a conversation", %{writer: :direct, source_kind: "conversation"})
      ]

      assert rendered([result("global", [], [], episodes)]) ==
               "Episodes\n- [Lens: notes] from a lens\n- [Source: direct conversation] from a conversation"
    end

    test "and an episode's text is cut to a bounded excerpt marked as truncated" do
      content = String.duplicate("word ", 200)

      assert "Episodes\n- [Lens: notes] " <> excerpt =
               rendered([result("global", [], [], [episode(content, %{lens: "notes"})])])

      assert String.ends_with?(excerpt, "… (truncated)")
      assert String.length(excerpt) < 300
    end

    test "and a Reflection episode is summarised by its artefact identifier and a bounded excerpt of its payload" do
      reflection = %{
        artefact: %{id: "gen-1", payload: %{"generalisations" => String.duplicate("x", 1_000)}},
        reflection: "generalisations",
        source_description: "reflection:generalisations"
      }

      assert "Episodes\n- [Reflection: generalisations] artefact gen-1: " <> excerpt =
               rendered([result("global", [], [], [reflection])])

      assert excerpt =~ ~s({"generalisations":"xxx)
      assert String.ends_with?(excerpt, "… (truncated)")
      assert String.length(excerpt) < 300
    end

    test "and an episode with no named writer is labelled `Source: unknown`" do
      assert rendered([result("global", [], [], [%{content: "old", source_description: "x"}])]) ==
               "Episodes\n- [Source: unknown] old"
    end
  end

  describe "when formatted results must fit response limits" do
    test "then an exact-fit response retains every complete fact, entity, and episode bullet" do
      input = [
        result("global", [fact("one", [%{lens: "notes"}])], [entity("Atlas")], [
          episode("story", %{lens: "notes"})
        ])
      ]

      expected = %{
        result:
          "Facts\n\nLens: notes\n- one\n\nEntities\n- Atlas\n\nEpisodes\n- [Lens: notes] story"
      }

      assert Presentation.for_model(input, envelope_bytes(expected)) == {:ok, expected}
    end

    test "and headings and omission notices count towards the 16384-character ceiling" do
      heading = "Facts\n\nLens: notes\n- "
      notice = "\n\n" <> @omitted_one_fact
      oversized = fact(String.duplicate("y", 17_000), [%{lens: "notes"}])
      content = String.duplicate("x", 16_384 - String.length(heading) - String.length(notice))

      assert rendered(facts([fact(content, [%{lens: "notes"}]), oversized])) ==
               heading <> content <> notice

      assert rendered(facts([fact(content <> "x", [%{lens: "notes"}]), oversized])) ==
               "Omitted (response limit): facts 2, entities 0, episodes 0."
    end

    test "and UTF-8 bytes and JSON escaping count towards the complete-envelope byte budget" do
      input = facts([fact(String.duplicate("λ\n\"", 40), [%{lens: "notes"}])])
      text = rendered(input)
      bytes = envelope_bytes(%{result: text})
      assert Presentation.for_model(input, bytes) == {:ok, %{result: text}}
      assert Presentation.for_model(input, bytes - 1) == {:ok, %{result: @omitted_one_fact}}
    end

    test "and a bullet that exceeds either limit is omitted whole while later fitting bullets remain eligible" do
      input = [
        result(
          "global",
          [
            fact(String.duplicate("x", 17_000), [%{lens: "notes"}]),
            fact("small", [%{lens: "notes"}])
          ],
          [entity("Atlas")],
          []
        )
      ]

      assert rendered(input) ==
               "Facts\n\nLens: notes\n- small\n\nEntities\n- Atlas\n\n" <> @omitted_one_fact
    end

    test "and the omission notice counts excluded facts, entities, and episodes separately, each fact once regardless of its source count" do
      huge = String.duplicate("x", 17_000)

      input = [
        result(
          "global",
          [fact(huge, [%{lens: "a"}, %{lens: "b"}])],
          [%{name: huge, summary: nil, attributes: %{}}],
          []
        )
      ]

      assert rendered(input) == "Omitted (response limit): facts 1, entities 1, episodes 0."
    end
  end

  describe "when formatted results must fit response limits > while the budget cannot contain the empty response and required notice" do
    test "then an explicit error reports the required minimum bytes" do
      input = facts([fact("one", [%{lens: "notes"}])])
      minimum = envelope_bytes(%{result: @omitted_one_fact})

      assert Presentation.for_model(input, 1) ==
               {:error,
                {:memory_search_budget_too_small, %{max_bytes: 1, minimum_bytes: minimum}}}
    end
  end

  describe "when formatted results must fit response limits > if the byte budget is not a positive integer" do
    test "then an argument error identifies the invalid budget" do
      for invalid <- [0, -1, nil, "100", 1.5] do
        assert_raise ArgumentError, ~r/memory_search_max_bytes.*positive integer/, fn ->
          Presentation.for_model([], invalid)
        end
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
        error =
          assert_raise ArgumentError, fn -> Presentation.validate_max_bytes!(invalid) end

        assert error.message =~ "memory_search_max_bytes must be a positive integer"
        assert error.message =~ inspect(invalid)
      end
    end
  end

  defp result(destination, facts, nodes, episodes),
    do: %{destination: destination, facts: facts, nodes: nodes, episodes: episodes}

  defp facts(facts), do: [result("global", facts, [], [])]
  defp fact(text, sources), do: %{fact: text, sources: sources}
  defp entity(name), do: %{name: name, summary: nil, attributes: %{}}
  defp episode(content, provenance), do: Map.put(provenance, :content, content)

  defp rendered(input) do
    assert {:ok, %{result: text}} = Presentation.for_model(input, 65_536)
    text
  end

  defp envelope_bytes(output), do: byte_size(Jason.encode!(%{ok: true, result: output}))
end
