defmodule JidoGralkor.MemorySearchPresentationTest do
  use ExUnit.Case, async: true
  alias JidoGralkor.MemorySearchPresentation, as: Presentation

  @omitted_one "1 more memory omitted (response limit)."

  describe "when the memory search formatter is called" do
    test "then every memory is one line of plain text under the heading of its writer" do
      input = [
        result("first", [fact("first\nfact", [%{lens: "notes"}])], [], [
          episode("first   episode", %{lens: "notes"})
        ])
      ]

      assert rendered(input) == "Lens: notes\n- first fact\n- first episode"
    end

    test "and whole Reflection artefacts come first, then facts, then episodes" do
      input = [
        result("first", [fact("a fact", [%{lens: "notes"}])], [], [
          episode("an episode", %{lens: "notes"})
        ]),
        result("second", [], [], [artefact("lessons", %{"lesson" => "an artefact"})])
      ]

      assert rendered(input) ==
               "Reflection: lessons\n- an artefact\n\nLens: notes\n- a fact\n- an episode"
    end

    test "and headings keep first-appearance order with retrieval order inside each heading" do
      assert rendered(
               facts([
                 fact("one", [%{lens: "z"}]),
                 fact("two", [%{lens: "a"}]),
                 fact("three", [%{lens: "z"}])
               ])
             ) == "Lens: z\n- one\n- three\n\nLens: a\n- two"
    end

    test "and the same text appears once under one heading" do
      input = [
        result("global", [fact("one", [%{lens: "notes"}])], [], [episode("one", %{lens: "notes"})])
      ]

      assert rendered(input) == "Lens: notes\n- one"
    end

    test "and entities come last under an `Entities` heading" do
      input = [
        result("global", [], [entity("Atlas")], [episode("an episode", %{lens: "notes"})]),
        result("second", [], [entity("Borealis")], [])
      ]

      assert rendered(input) == "Lens: notes\n- an episode\n\nEntities\n- Atlas\n- Borealis"
    end

    test "and nothing is labelled as a fact, an episode, or an artefact" do
      text =
        rendered([
          result("global", [fact("one", [%{lens: "notes"}])], [], [
            episode("two", %{lens: "notes"}),
            artefact("lessons", %{"lesson" => "three"})
          ])
        ])

      refute text =~ "Facts"
      refute text =~ "Episodes"
      refute text =~ "artefact"
      refute text =~ "Excerpt"
    end

    test "and the formatter adds no Destination, artefact identifier, level, or lineage metadata" do
      payload = %{
        "generalisations" => [%{"content" => "Use canaries", "level" => 2, "evolves_from" => []}]
      }

      assert rendered([result("global", [], [], [artefact("lessons", payload)])]) ==
               "Reflection: lessons\n- Use canaries"
    end

    test "and the structured input remains unchanged" do
      input = facts([fact("one", [%{lens: "notes", id: "source-id"}])])
      assert rendered(input) == "Lens: notes\n- one"
      assert input == facts([fact("one", [%{lens: "notes", id: "source-id"}])])
    end
  end

  describe "when the memory search formatter is called > while no memories are supplied" do
    test "then the text explicitly states that no matching memory was found" do
      assert rendered([]) == "No matching memory."
      assert rendered([result("global", [], [], [])]) == "No matching memory."
    end
  end

  describe "when the formatter names a writer" do
    test "then a Lens uses a `Lens: <name>` heading" do
      assert rendered(facts([fact("one", [%{lens: "notes"}])])) == "Lens: notes\n- one"
    end

    test "and a Reflection uses a `Reflection: <name>` heading" do
      assert rendered(facts([fact("one", [%{reflection: "lessons"}])])) ==
               "Reflection: lessons\n- one"
    end

    test "and known direct provenance identifies its source kind" do
      for {kind, heading} <- [
            {:conversation, "Source: direct conversation"},
            {"conversation", "Source: direct conversation"},
            {:document, "Source: direct document"},
            {:structured_record, "Source: direct structured record"}
          ] do
        assert rendered([
                 result("global", [], [], [
                   episode("one", %{writer: :direct, source_kind: kind})
                 ])
               ]) == heading <> "\n- one"
      end

      assert rendered(facts([fact("one", [%{writer: :direct}])])) == "Source: direct\n- one"
    end

    test "and unnamed provenance uses `Source: unknown`" do
      assert rendered(facts([fact("one", [%{id: "x"}]), fact("two", [])])) ==
               "Source: unknown\n- one\n- two"

      assert rendered([result("global", [], [], [%{content: "three"}])]) ==
               "Source: unknown\n- three"
    end
  end

  describe "when the formatter presents facts" do
    test "then each fact is one bullet with its complete text" do
      text = String.duplicate("a long fact ", 200) |> String.trim()
      assert rendered(facts([fact(text, [%{lens: "notes"}])])) == "Lens: notes\n- " <> text
    end

    test "and repeated provenance for one source adds no duplicate bullet for that fact" do
      assert rendered(
               facts([fact("one", [%{lens: "notes", id: "a"}, %{lens: "notes", id: "b"}])])
             ) ==
               "Lens: notes\n- one"
    end

    test "and a fact with several named sources appears under each distinct source" do
      assert rendered(facts([fact("one", [%{lens: "notes"}, %{reflection: "lessons"}])])) ==
               "Lens: notes\n- one\n\nReflection: lessons\n- one"
    end
  end

  describe "when the formatter presents facts > while a fact has an invalidation date" do
    test "then its bullet ends with `(invalidated at <date>)`" do
      invalidated =
        fact("The Vacuum job runs at 02:00.", [%{lens: "notes"}])
        |> Map.put(:invalid_at, "2026-10-12 09:16:40.173249+00:00")
        |> Map.put(:expired_at, "2026-10-20 00:00:00+00:00")

      assert rendered(facts([invalidated])) ==
               "Lens: notes\n- The Vacuum job runs at 02:00. (invalidated at 2026-10-12)"
    end
  end

  describe "when the formatter presents facts > while a fact has only an expiry date" do
    test "then its bullet ends with `(invalidated at <date>)`" do
      expired =
        fact("The Vacuum job runs at 02:00.", [%{lens: "notes"}])
        |> Map.put(:invalid_at, nil)
        |> Map.put(:expired_at, "2026-10-20 00:00:00+00:00")

      assert rendered(facts([expired])) ==
               "Lens: notes\n- The Vacuum job runs at 02:00. (invalidated at 2026-10-20)"
    end
  end

  describe "when the formatter presents entities" do
    test "then each entity is one bullet with its complete name, summary, and attributes" do
      node = %{name: "Atlas", summary: "A rollout", attributes: %{"owner" => "Platform"}}

      assert rendered([result("global", [], [node], [])]) ==
               "Entities\n- Atlas: A rollout (owner: Platform)"
    end
  end

  describe "when the formatter presents a Reflection artefact" do
    test "then its payload is presented whole as readable text" do
      text = String.duplicate("a long lesson ", 100) |> String.trim()

      assert rendered([result("global", [], [], [artefact("lessons", %{"lesson" => text})])]) ==
               "Reflection: lessons\n- " <> text
    end

    test "and each item of a top-level list is its own bullet" do
      payload = %{
        "generalisations" => [
          %{"content" => "First lesson", "level" => 1},
          %{"content" => "Second lesson", "level" => 1}
        ]
      }

      assert rendered([result("global", [], [], [artefact("lessons", payload)])]) ==
               "Reflection: lessons\n- First lesson\n- Second lesson"
    end

    test "and an object with a `content` string presents only that text" do
      payload = %{"content" => "Use canaries", "level" => 3, "owner" => "Platform"}

      assert rendered([result("global", [], [], [artefact("lessons", payload)])]) ==
               "Reflection: lessons\n- Use canaries"
    end

    test "and an object with one field presents only that field's value" do
      assert rendered([
               result("global", [], [], [artefact("lessons", %{"summary" => "Reviewed"})])
             ]) ==
               "Reflection: lessons\n- Reviewed"
    end

    test "and any other object presents `key: value` pairs separated by semicolons" do
      payload = %{
        "approach" => "moved Vacuum",
        "lesson" => "Keep them apart",
        "success" => true,
        "unset" => nil,
        "tags" => ["ops", "jobs"]
      }

      assert rendered([result("global", [], [], [artefact("erl", payload)])]) ==
               "Reflection: erl\n- approach: moved Vacuum; lesson: Keep them apart; " <>
                 "success: true; tags: ops, jobs"
    end

    test "and an empty payload presents nothing" do
      assert rendered([result("global", [], [], [artefact("lessons", %{})])]) ==
               "No matching memory."
    end
  end

  describe "when the formatter presents episodes" do
    test "then an episode's text is presented whole on one line" do
      text = String.duplicate("a long source document ", 100) |> String.trim()

      assert rendered([
               result("global", [], [], [
                 episode(text <> "\n\nuser: and more", %{lens: "notes"})
               ])
             ]) == "Lens: notes\n- " <> text <> " user: and more"
    end

    test "and a structured-record episode is presented as readable text the same way as a Reflection artefact" do
      content = Jason.encode!(%{"approach" => "canary", "owner" => "Platform"})

      assert rendered([
               result("global", [], [], [
                 episode(content, %{lens: "notes", source_kind: "structured_record"})
               ])
             ]) == "Lens: notes\n- approach: canary; owner: Platform"
    end

    test "and a structured-record episode whose content is not JSON keeps its text" do
      assert rendered([
               result("global", [], [], [
                 episode("not { json", %{lens: "notes", source_kind: :structured_record})
               ])
             ]) == "Lens: notes\n- not { json"
    end
  end

  describe "when one memory is longer than 4,000 characters" do
    test "then it is cut to 4,000 characters and marked as truncated" do
      text = String.duplicate("x", 4_001)

      assert rendered(facts([fact(text, [%{lens: "notes"}])])) ==
               "Lens: notes\n- " <> String.duplicate("x", 4_000) <> "… (truncated)"
    end

    test "and a memory of exactly 4,000 characters is not cut" do
      text = String.duplicate("x", 4_000)
      assert rendered(facts([fact(text, [%{lens: "notes"}])])) == "Lens: notes\n- " <> text
    end

    test "and an invalidated fact keeps its invalidation date" do
      invalidated =
        fact(String.duplicate("x", 4_001), [%{lens: "notes"}])
        |> Map.put(:invalid_at, "2026-10-12 00:00:00+00:00")

      assert rendered(facts([invalidated])) ==
               "Lens: notes\n- " <>
                 String.duplicate("x", 4_000) <> "… (truncated) (invalidated at 2026-10-12)"
    end
  end

  describe "when formatted results must fit response limits" do
    test "then an exact-fit response retains every memory" do
      input = [
        result("global", [fact("one", [%{lens: "notes"}])], [entity("Atlas")], [
          episode("story", %{lens: "notes"})
        ])
      ]

      expected = %{result: "Lens: notes\n- one\n- story\n\nEntities\n- Atlas"}

      assert Presentation.for_model(input, envelope_bytes(expected)) == {:ok, expected}
    end

    test "and headings and omission notices count towards the 16384-character ceiling" do
      memories = for _ <- 1..5, do: fact(String.duplicate("x", 4_000), [%{lens: "notes"}])

      assert rendered(facts(memories)) ==
               "Lens: notes\n" <>
                 Enum.map_join(1..4, "\n", fn _ -> "- " <> String.duplicate("x", 4_000) end) <>
                 "\n\n" <> @omitted_one
    end

    test "and UTF-8 bytes and JSON escaping count towards the complete-envelope byte budget" do
      input = facts([fact(String.duplicate("λ\"", 40), [%{lens: "notes"}])])
      text = rendered(input)
      bytes = envelope_bytes(%{result: text})
      assert Presentation.for_model(input, bytes) == {:ok, %{result: text}}
      assert Presentation.for_model(input, bytes - 1) == {:ok, %{result: @omitted_one}}
    end

    test "and a bullet that exceeds either limit is omitted whole while later fitting bullets remain eligible" do
      input =
        facts([
          fact(String.duplicate("x", 300), [%{lens: "notes"}]),
          fact("small", [%{lens: "notes"}])
        ])

      expected = %{result: "Lens: notes\n- small\n\n" <> @omitted_one}

      assert Presentation.for_model(input, envelope_bytes(expected)) == {:ok, expected}
    end

    test "and the omission notice gives the total omitted, each fact once regardless of its source count" do
      memories =
        for _ <- 1..6, do: fact(String.duplicate("x", 4_000), [%{lens: "a"}, %{lens: "b"}])

      text = rendered(facts(memories))

      assert String.ends_with?(text, "\n\n4 more memories omitted (response limit).")
    end
  end

  describe "when formatted results must fit response limits > while the budget cannot contain the empty response and required notice" do
    test "then an explicit error reports the required minimum bytes" do
      input = facts([fact("one", [%{lens: "notes"}])])
      minimum = envelope_bytes(%{result: @omitted_one})

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

  defp artefact(reflection, payload),
    do: %{reflection: reflection, artefact: %{id: "artefact-id", payload: payload}}

  defp rendered(input) do
    assert {:ok, %{result: text}} = Presentation.for_model(input, 65_536)
    text
  end

  defp envelope_bytes(output), do: byte_size(Jason.encode!(%{ok: true, result: output}))
end
