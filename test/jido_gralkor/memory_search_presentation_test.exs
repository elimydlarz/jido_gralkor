defmodule JidoGralkor.MemorySearchPresentationTest do
  use ExUnit.Case, async: true
  alias JidoGralkor.MemorySearchPresentation, as: Presentation

  @omitted_one "1 more memory omitted (response limit)."

  @examples """
  Reflection: generalisations
  - For any potentially customer-impacting release activity, a mandatory reversible, limited-scope checkpoint must be used… (valid from 2026-10-02)
    level: 2
    evolves_from:
    - For critical deployments, a mandatory reversible, limited-scope canary and checkpoint must be used…
      level: 1

  Reflection: erl
  - approach: moved Vacuum to 04:00 (valid from 2026-10-12)
    lesson: Keep the jobs apart
    problem_kind: job scheduling
    success: true

  Entities
  - Atlas: A rollout
    owner: Platform
    region: eu-west
  - Payments: Customer-impacting release activity needs a checkpoint
  """

  describe "when the memory search formatter is called" do
    test "then every memory is one bullet under the heading of its writer, its first line its main text and each other field on its own indented line" do
      input = [
        result("first", [fact("first\nfact", [%{lens: "notes"}])], [], [
          episode("first   episode", %{lens: "notes"}),
          artefact("lessons", %{"content" => "a\nlesson", "owner" => "Platform  team"})
        ])
      ]

      assert rendered(input) ==
               "Reflection: lessons\n- a lesson\n  owner: Platform team\n\n" <>
                 "Lens: notes\n- first fact\n- first episode"
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

    test "and a memory whose whole text is another memory's first line under the same heading is left out beside it" do
      generalisation =
        artefact("generalisations", %{
          "generalisations" => [%{"content" => "Use canaries", "level" => 2}]
        })

      extracted = fact("Use canaries", [%{reflection: "generalisations"}])
      other_heading = fact("Use canaries", [%{lens: "notes"}])

      assert rendered([result("global", [extracted, other_heading], [], [generalisation])]) ==
               "Reflection: generalisations\n- Use canaries\n  level: 2\n\nLens: notes\n- Use canaries"

      assert rendered([result("global", [extracted], [], [])] ++
                        [result("generalisations", [], [], [generalisation])]) ==
               "Reflection: generalisations\n- Use canaries\n  level: 2"
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

    test "and the formatter adds no record metadata such as a Destination, an artefact identifier, or a uuid" do
      episode =
        artefact("lessons", %{"lesson" => "Use canaries", "level" => 1})
        |> Map.merge(%{uuid: "episode-uuid", group_id: "g_676c6f62616c", destination: "global"})

      node = %{entity("Atlas") | summary: "A rollout"} |> Map.put(:uuid, "node-uuid")

      text = rendered([result("global", [], [node], [episode])])

      assert text ==
               "Reflection: lessons\n- lesson: Use canaries\n  level: 1\n\nEntities\n- Atlas: A rollout"

      refute text =~ "artefact-id"
      refute text =~ "uuid"
      refute text =~ "global"
    end

    test "and level and lineage appear only as fields the payload itself carries" do
      with_lineage = %{
        "generalisations" => [%{"content" => "Use canaries", "level" => 2, "evolves_from" => []}]
      }

      assert rendered([result("global", [], [], [artefact("lessons", with_lineage)])]) ==
               "Reflection: lessons\n- Use canaries\n  level: 2"

      without = %{"generalisations" => [%{"content" => "Use canaries"}]}

      assert rendered([result("global", [], [], [artefact("lessons", without)])]) ==
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

  describe "when the formatter shows when a memory was true and where it came from" do
    test "then a fact or episode with a start date ends with `(valid from <date>)`" do
      dated_fact =
        Map.put(fact("one", [%{lens: "notes"}]), :valid_at, "2026-10-30 09:16:32+00:00")

      dated_episode = Map.put(episode("two", %{lens: "notes"}), :valid_at, "2026-10-29T08:00:00Z")

      assert rendered([result("global", [dated_fact], [], [dated_episode])]) ==
               "Lens: notes\n- one (valid from 2026-10-30)\n- two (valid from 2026-10-29)"
    end

    test "and the start date is when it became true, or when it was recorded if that is missing" do
      became_true =
        fact("one", [%{lens: "notes"}])
        |> Map.put(:valid_at, "2026-10-30 00:00:00+00:00")
        |> Map.put(:created_at, "2026-10-31 00:00:00+00:00")

      recorded =
        Map.put(fact("two", [%{lens: "notes"}]), :created_at, "2026-10-31 00:00:00+00:00")

      assert rendered(facts([became_true, recorded])) ==
               "Lens: notes\n- one (valid from 2026-10-30)\n- two (valid from 2026-10-31)"
    end

    test "and an invalidated or expired fact ends with `(valid from <date> to <date>)`" do
      invalidated =
        fact("one", [%{lens: "notes"}])
        |> Map.put(:valid_at, "2026-10-02 00:00:00+00:00")
        |> Map.put(:invalid_at, "2026-10-12 00:00:00+00:00")
        |> Map.put(:expired_at, "2026-10-20 00:00:00+00:00")

      expired =
        fact("two", [%{lens: "notes"}])
        |> Map.put(:valid_at, "2026-10-02 00:00:00+00:00")
        |> Map.put(:expired_at, "2026-10-20 00:00:00+00:00")

      assert rendered(facts([invalidated, expired])) ==
               "Lens: notes\n- one (valid from 2026-10-02 to 2026-10-12)\n" <>
                 "- two (valid from 2026-10-02 to 2026-10-20)"
    end

    test "and an invalidated fact with no start date ends with `(valid until <date>)`" do
      invalidated =
        Map.put(fact("one", [%{lens: "notes"}]), :invalid_at, "2026-10-12 00:00:00+00:00")

      assert rendered(facts([invalidated])) == "Lens: notes\n- one (valid until 2026-10-12)"
    end

    test "and a memory's source descriptions follow its dates, as in `(valid from <date>; source: <description>)`" do
      dated =
        Map.put(
          fact("one", [%{lens: "notes", source_description: "team notes"}]),
          :valid_at,
          "2026-10-30 00:00:00+00:00"
        )

      undated = episode("two", %{lens: "notes", source_description: "planning call"})

      assert rendered([result("global", [dated], [], [undated])]) ==
               "Lens: notes\n- one (valid from 2026-10-30; source: team notes)\n" <>
                 "- two (source: planning call)"
    end

    test "and a fact drawn from several episodes lists each distinct source description once" do
      shared =
        fact("one", [
          %{lens: "notes", source_description: "team notes"},
          %{lens: "notes", source_description: "incident review"},
          %{lens: "notes", source_description: "team notes"}
        ])

      assert rendered(facts([shared])) ==
               "Lens: notes\n- one (source: team notes, incident review)"
    end

    test "and a source description never repeats its Lens marker" do
      marked = fact("one", [%{lens: "notes", source_description: "team notes [lens: notes]"}])
      assert rendered(facts([marked])) == "Lens: notes\n- one (source: team notes)"
    end

    test "and a source description that only names a Reflection is left out" do
      reflected =
        fact("one", [%{reflection: "lessons", source_description: "reflection:lessons"}])

      artefact =
        artefact("lessons", %{"lesson" => "two"})
        |> Map.put(:source_description, "reflection:lessons")

      assert rendered([result("global", [reflected], [], [artefact])]) ==
               "Reflection: lessons\n- two\n- one"
    end

    test "and a memory with no dates or source description ends with no parentheses" do
      assert rendered(facts([fact("one", [%{lens: "notes"}])])) == "Lens: notes\n- one"
    end
  end

  describe "when the formatter presents entities" do
    test "then each entity's first line is `name: summary`, or only its name when it has no summary" do
      assert rendered([
               result(
                 "global",
                 [],
                 [%{entity("Atlas") | summary: "A rollout"}, entity("Borealis")],
                 []
               )
             ]) == "Entities\n- Atlas: A rollout\n- Borealis"
    end

    test "and each attribute is its own indented `key: value` line, not an inline bracket" do
      node = %{
        name: "Atlas",
        summary: "A rollout",
        attributes: %{owner: "Platform", region: "eu-west", since: ~D[2026-10-02]}
      }

      assert rendered([result("global", [], [node], [])]) ==
               "Entities\n- Atlas: A rollout\n  owner: Platform\n  region: eu-west\n  since: 2026-10-02"
    end

    test "and entities with different attributes each show all of their own" do
      atlas = %{name: "Atlas", summary: "A rollout", attributes: %{"owner" => "Platform"}}

      borealis = %{
        name: "Borealis",
        summary: nil,
        attributes: %{"tier" => 1, "tags" => ["a", "b"]}
      }

      assert rendered([result("global", [], [atlas, borealis], [])]) ==
               "Entities\n- Atlas: A rollout\n  owner: Platform\n- Borealis\n  tags: a, b\n  tier: 1"
    end

    test "and internal `_gralkor` attributes are not shown" do
      node = %{
        name: "Atlas",
        summary: "A rollout",
        attributes: %{"_gralkor_lens" => "observations", "owner" => "Platform"}
      }

      assert rendered([result("global", [], [node], [])]) ==
               "Entities\n- Atlas: A rollout\n  owner: Platform"

      hidden_only = %{node | attributes: %{"_gralkor_lens" => "observations"}}

      assert rendered([result("global", [], [hidden_only], [])]) ==
               "Entities\n- Atlas: A rollout"
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
          %{"content" => "First lesson"},
          %{"content" => "Second lesson"}
        ]
      }

      assert rendered([result("global", [], [], [artefact("lessons", payload)])]) ==
               "Reflection: lessons\n- First lesson\n- Second lesson"
    end

    test "and a payload object with exactly one key is presented as that key's value, once, at the outer level only" do
      assert rendered([
               result("global", [], [], [artefact("lessons", %{"summary" => "Reviewed"})])
             ]) == "Reflection: lessons\n- Reviewed"

      nested = %{"outer" => %{"inner" => %{"lesson" => "Keep apart"}}}

      assert rendered([result("global", [], [], [artefact("lessons", nested)])]) ==
               "Reflection: lessons\n- inner:\n    lesson: Keep apart"
    end

    test "and an object's `content` string is its first line and every other field follows" do
      payload = %{"content" => "Use canaries", "level" => 3, "owner" => "Platform"}

      assert rendered([result("global", [], [], [artefact("lessons", payload)])]) ==
               "Reflection: lessons\n- Use canaries\n  level: 3\n  owner: Platform"
    end

    test "and an object without `content` puts its first field on the first line as `key: value`" do
      payload = %{"lesson" => "Keep them apart", "approach" => "moved Vacuum"}

      assert rendered([result("global", [], [], [artefact("erl", payload)])]) ==
               "Reflection: erl\n- approach: moved Vacuum\n  lesson: Keep them apart"
    end

    test "and one-line fields come first in alphabetical order, then multi-line fields in alphabetical order" do
      payload = %{
        "zeta" => "last plain",
        "alpha" => [%{"content" => "listed"}],
        "beta" => %{"note" => "nested"},
        "gamma" => "plain"
      }

      assert rendered([result("global", [], [], [artefact("erl", payload)])]) ==
               "Reflection: erl\n- gamma: plain\n  zeta: last plain\n  alpha:\n  - listed\n" <>
                 "  beta:\n    note: nested"
    end

    test "and a number or boolean is written as it is" do
      payload = %{"level" => 2, "score" => 0.5, "success" => true, "failed" => false}

      assert rendered([result("global", [], [], [artefact("erl", payload)])]) ==
               "Reflection: erl\n- failed: false\n  level: 2\n  score: 0.5\n  success: true"
    end

    test "and a list of plain values is one `key: a, b, c` line" do
      payload = %{"lesson" => "Keep apart", "tags" => ["ops", "jobs", 3]}

      assert rendered([result("global", [], [], [artefact("erl", payload)])]) ==
               "Reflection: erl\n- lesson: Keep apart\n  tags: ops, jobs, 3"
    end

    test "and a list containing an object is a `key:` line followed by one nested bullet per item, laid out the same way" do
      payload = %{
        "content" => "Current",
        "evolves_from" => [
          %{"content" => "Earlier", "level" => 1, "evolves_from" => [%{"content" => "Earliest"}]},
          "a plain snapshot"
        ]
      }

      assert rendered([result("global", [], [], [artefact("lessons", payload)])]) ==
               "Reflection: lessons\n- Current\n  evolves_from:\n  - Earlier\n    level: 1\n" <>
                 "    evolves_from:\n    - Earliest\n  - a plain snapshot"
    end

    test "and a nested object is a `key:` line followed by its own fields two spaces further in" do
      payload = %{
        "content" => "Use canaries",
        "scope" => %{"team" => "Platform", "region" => "eu"}
      }

      assert rendered([result("global", [], [], [artefact("lessons", payload)])]) ==
               "Reflection: lessons\n- Use canaries\n  scope:\n    region: eu\n    team: Platform"
    end

    test "and a nested object with one field keeps its field name" do
      payload = %{"content" => "Use canaries", "scope" => %{"team" => "Platform"}}

      assert rendered([result("global", [], [], [artefact("lessons", payload)])]) ==
               "Reflection: lessons\n- Use canaries\n  scope:\n    team: Platform"
    end

    test "and null, empty strings, empty lists, empty objects, and fields containing only those are left out" do
      payload = %{
        "content" => "Use canaries",
        "unset" => nil,
        "blank" => " ",
        "none" => [],
        "nothing" => %{},
        "hollow" => %{"inner" => [nil, ""], "other" => %{}},
        "kept" => [nil, "x"]
      }

      assert rendered([result("global", [], [], [artefact("lessons", payload)])]) ==
               "Reflection: lessons\n- Use canaries\n  kept: x"
    end

    test "and the generalisation, erl, and entity examples render exactly as specified" do
      generalisation =
        artefact("generalisations", %{
          "generalisations" => [
            %{
              "content" =>
                "For any potentially customer-impacting release activity, a mandatory reversible, limited-scope checkpoint must be used…",
              "level" => 2,
              "evolves_from" => [
                %{
                  "content" =>
                    "For critical deployments, a mandatory reversible, limited-scope canary and checkpoint must be used…",
                  "level" => 1
                }
              ]
            }
          ]
        })
        |> Map.put(:valid_at, "2026-10-02T00:00:00Z")

      erl =
        artefact("erl", %{
          "approach" => "moved Vacuum to 04:00",
          "lesson" => "Keep the jobs apart",
          "problem_kind" => "job scheduling",
          "success" => true
        })
        |> Map.put(:valid_at, "2026-10-12T00:00:00Z")

      atlas = %{
        name: "Atlas",
        summary: "A rollout",
        attributes: %{"owner" => "Platform", "region" => "eu-west"}
      }

      payments = %{
        name: "Payments",
        summary: "Customer-impacting release activity needs a checkpoint",
        attributes: %{}
      }

      assert rendered([result("global", [], [atlas, payments], [generalisation, erl])]) ==
               String.trim_trailing(@examples)
    end

    test "and an empty payload presents nothing" do
      assert rendered([result("global", [], [], [artefact("lessons", %{})])]) ==
               "No matching memory."
    end
  end

  describe "when the formatter presents episodes" do
    test "then an episode that is not a structured record is presented whole on one line" do
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
             ]) == "Lens: notes\n- approach: canary\n  owner: Platform"
    end

    test "and a structured-record episode whose content is not JSON keeps its text" do
      assert rendered([
               result("global", [], [], [
                 episode("not { json", %{lens: "notes", source_kind: :structured_record})
               ])
             ]) == "Lens: notes\n- not { json"
    end
  end

  describe "when the formatter shows a memory with several lines" do
    test "then its date and source suffix ends its first line" do
      episode =
        artefact("erl", %{"approach" => "canary", "lesson" => "Keep apart"})
        |> Map.merge(%{valid_at: "2026-10-12T00:00:00Z", source_description: "incident review"})

      assert rendered([result("global", [], [], [episode])]) ==
               "Reflection: erl\n- approach: canary (valid from 2026-10-12; source: incident review)\n" <>
                 "  lesson: Keep apart"
    end
  end

  describe "when one memory is longer than 4,000 characters" do
    test "then it is cut to 4,000 characters and marked as truncated" do
      text = String.duplicate("x", 4_001)

      assert rendered(facts([fact(text, [%{lens: "notes"}])])) ==
               "Lens: notes\n- " <> String.duplicate("x", 4_000) <> "… (truncated)"
    end

    test "and its length counts every line with its indentation and line breaks" do
      lesson = String.duplicate("x", 3_988)
      exact = %{"content" => "c", "lesson" => lesson}
      over = %{"content" => "cc", "lesson" => lesson}

      assert rendered([result("global", [], [], [artefact("erl", exact)])]) ==
               "Reflection: erl\n- c\n  lesson: " <> lesson

      assert rendered([result("global", [], [], [artefact("erl", over)])]) ==
               "Reflection: erl\n- cc\n  lesson: " <>
                 String.slice(lesson, 0, 3_987) <> "… (truncated)"
    end

    test "and the truncation marker ends the last line that is kept" do
      lines = for n <- 1..9, into: %{}, do: {"field_#{n}", String.duplicate("y", 490)}

      text =
        rendered([result("global", [], [], [artefact("erl", Map.put(lines, "content", "c"))])])

      body = String.replace_prefix(text, "Reflection: erl\n- ", "")

      assert String.length(body) == 4_000 + String.length("… (truncated)")
      assert String.ends_with?(body, "y… (truncated)")
      refute String.ends_with?(body, "\n… (truncated)")
    end

    test "and a memory of exactly 4,000 characters is not cut" do
      text = String.duplicate("x", 4_000)
      assert rendered(facts([fact(text, [%{lens: "notes"}])])) == "Lens: notes\n- " <> text
    end

    test "and its dates and source still follow the cut without counting toward it" do
      long =
        fact(String.duplicate("x", 4_001), [%{lens: "notes", source_description: "team notes"}])
        |> Map.put(:valid_at, "2026-10-02 00:00:00+00:00")
        |> Map.put(:invalid_at, "2026-10-12 00:00:00+00:00")

      assert rendered(facts([long])) ==
               "Lens: notes\n- " <>
                 String.duplicate("x", 4_000) <>
                 "… (truncated) (valid from 2026-10-02 to 2026-10-12; source: team notes)"
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
      texts = for number <- 1..5, do: "#{number} " <> String.duplicate("x", 3_998)
      memories = Enum.map(texts, &fact(&1, [%{lens: "notes"}]))

      assert rendered(facts(memories)) ==
               "Lens: notes\n" <>
                 Enum.map_join(Enum.take(texts, 4), "\n", &("- " <> &1)) <>
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
        for number <- 1..6 do
          fact("#{number} " <> String.duplicate("x", 3_998), [%{lens: "a"}, %{lens: "b"}])
        end

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
