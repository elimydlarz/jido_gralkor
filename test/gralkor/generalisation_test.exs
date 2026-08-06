defmodule Gralkor.GeneralisationTest do
  use ExUnit.Case, async: true

  alias Gralkor.Generalisation
  alias Gralkor.GeneralisationParseFailed

  describe "when a generalisation is encoded" do
    test "then the first line is a \"GEN|v1|\" prefix followed by JSON metadata" do
      gen = %Generalisation{
        id: "abc123",
        content: "Eli prefers dark mode.",
        level: 0,
        confidence: 0.85
      }

      encoded = Generalisation.encode(gen)

      assert encoded =~ ~r/^GEN\|v1\|/
    end

    test "and the free-text content follows on the lines after it" do
      gen = %Generalisation{
        id: "abc123",
        content: "Eli prefers dark mode.",
        level: 0,
        confidence: 0.85
      }

      encoded = Generalisation.encode(gen)

      assert encoded =~ "Eli prefers dark mode."
      assert String.contains?(encoded, "\n")
    end

    test "and the metadata carries the id, the level, the confidence, and the ids generalised" do
      gen = %Generalisation{
        id: "abc123",
        content: "test",
        level: 3,
        confidence: 0.92,
        generalises: ["def456", "ghi789"]
      }

      encoded = Generalisation.encode(gen)
      [first_line | _] = String.split(encoded, "\n")
      json = String.replace_prefix(first_line, "GEN|v1|", "")
      meta = Jason.decode!(json)

      assert meta["id"] == "abc123"
      assert meta["level"] == 3
      assert meta["confidence"] == 0.92
      assert meta["generalises"] == ["def456", "ghi789"]
    end
  end

  describe "when a generalisation is encoded > where the generalisation generalises nothing" do
    test "then the metadata records an empty list of generalised ids" do
      gen = %Generalisation{
        id: "abc123",
        content: "test",
        level: 0,
        confidence: 0.5
      }

      encoded = Generalisation.encode(gen)
      [first_line | _] = String.split(encoded, "\n")
      json = String.replace_prefix(first_line, "GEN|v1|", "")
      meta = Jason.decode!(json)

      assert meta["generalises"] == []
    end
  end

  describe "when a string carrying the \"GEN|v1|\" prefix is decoded" do
    test "then the generalisation and its plain content are returned" do
      gen = %Generalisation{
        id: "abc123",
        content: "Eli prefers dark mode.",
        level: 2,
        confidence: 0.85,
        generalises: ["def456"]
      }

      encoded = Generalisation.encode(gen)
      assert {:ok, decoded, plain} = Generalisation.decode(encoded)

      assert %Generalisation{} = decoded
      assert plain == "Eli prefers dark mode."
    end

    test "and the id, level, confidence, and generalised ids round-trip the encoded values" do
      gen = %Generalisation{
        id: "abc123",
        content: "Eli prefers dark mode.",
        level: 2,
        confidence: 0.85,
        generalises: ["def456"]
      }

      encoded = Generalisation.encode(gen)
      assert {:ok, decoded, _plain} = Generalisation.decode(encoded)

      assert decoded.id == gen.id
      assert decoded.level == gen.level
      assert decoded.confidence == gen.confidence
      assert decoded.generalises == gen.generalises
    end

    test "and the plain content is trimmed of leading and trailing whitespace" do
      encoded =
        "GEN|v1|{\"id\":\"x\",\"level\":0,\"confidence\":0.5,\"generalises\":[]}\n  padded content  \n"

      assert {:ok, _gen, plain} = Generalisation.decode(encoded)
      assert plain == "padded content"
    end
  end

  describe "when a string carrying the \"GEN|v1|\" prefix is decoded > where the content spans several lines" do
    test "then every line after the first is preserved as plain content" do
      encoded =
        "GEN|v1|{\"id\":\"x\",\"level\":1,\"confidence\":0.7,\"generalises\":[\"y\"]}\nLine 1\nLine 2\nLine 3"

      assert {:ok, gen, plain} = Generalisation.decode(encoded)
      assert gen.id == "x"
      assert gen.level == 1
      assert plain == "Line 1\nLine 2\nLine 3"
    end
  end

  describe "when a string carrying the \"GEN|v1|\" prefix is decoded > if the JSON metadata is malformed" do
    test "then GeneralisationParseFailed is raised" do
      assert_raise GeneralisationParseFailed, fn ->
        Generalisation.decode("GEN|v1|not-json\ncontent")
      end
    end
  end

  describe "when a string carrying the \"GEN|v1|\" prefix is decoded > if the id, the level, or the confidence is missing from the metadata" do
    test "then GeneralisationParseFailed is raised" do
      assert_raise GeneralisationParseFailed, ~r/"id"/, fn ->
        Generalisation.decode(~s(GEN|v1|{"level":0,"confidence":0.5,"generalises":[]}\ncontent))
      end

      assert_raise GeneralisationParseFailed, ~r/"level"/, fn ->
        Generalisation.decode(~s(GEN|v1|{"id":"x","confidence":0.5,"generalises":[]}\ncontent))
      end

      assert_raise GeneralisationParseFailed, ~r/"confidence"/, fn ->
        Generalisation.decode(~s(GEN|v1|{"id":"x","level":0,"generalises":[]}\ncontent))
      end
    end
  end

  describe "when a string without the \"GEN|v1|\" prefix is decoded" do
    test "then {:error, :not_a_generalisation} is returned" do
      assert {:error, :not_a_generalisation} = Generalisation.decode("just a regular fact")
      assert {:error, :not_a_generalisation} = Generalisation.decode("- some fact (created 2020)")
    end
  end

  describe "when an empty string is decoded" do
    test "then {:error, :not_a_generalisation} is returned" do
      assert {:error, :not_a_generalisation} = Generalisation.decode("")
    end
  end

  describe "when a generalisation is built without its optional fields" do
    test "then the list of ids it generalises defaults to empty" do
      gen = %Generalisation{
        id: "abc",
        content: "test",
        level: 0,
        confidence: 0.5
      }

      assert gen.generalises == []
    end

    test "and its creation timestamp defaults to nil" do
      gen = %Generalisation{
        id: "abc",
        content: "test",
        level: 0,
        confidence: 0.5
      }

      assert gen.created_at == nil
    end
  end
end
