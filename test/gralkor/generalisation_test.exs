defmodule Gralkor.GeneralisationTest do
  use ExUnit.Case, async: true

  alias Gralkor.Generalisation
  alias Gralkor.GeneralisationParseFailed

  describe "encode/1" do
    test "produces the GEN|v1| prefix format" do
      gen = %Generalisation{
        id: "abc123",
        content: "Eli prefers dark mode.",
        level: 0,
        confidence: 0.85
      }

      encoded = Generalisation.encode(gen)

      assert encoded =~ ~r/^GEN\|v1\|/
      assert encoded =~ "Eli prefers dark mode."
      assert String.contains?(encoded, "\n")
    end

    test "includes all metadata in the first line" do
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

    test "generalises defaults to empty list" do
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

  describe "decode/1" do
    test "round-trips a generalisation" do
      gen = %Generalisation{
        id: "abc123",
        content: "Eli prefers dark mode.",
        level: 2,
        confidence: 0.85,
        generalises: ["def456"]
      }

      encoded = Generalisation.encode(gen)
      assert {:ok, decoded, plain} = Generalisation.decode(encoded)

      assert decoded.id == gen.id
      assert decoded.level == gen.level
      assert decoded.confidence == gen.confidence
      assert decoded.generalises == gen.generalises
      assert plain == "Eli prefers dark mode."
    end

    test "returns plain content trimmed of whitespace" do
      encoded = "GEN|v1|{\"id\":\"x\",\"level\":0,\"confidence\":0.5,\"generalises\":[]}\n  padded content  \n"

      assert {:ok, _gen, plain} = Generalisation.decode(encoded)
      assert plain == "padded content"
    end

    test "handles content with newlines" do
      encoded = "GEN|v1|{\"id\":\"x\",\"level\":1,\"confidence\":0.7,\"generalises\":[\"y\"]}\nLine 1\nLine 2\nLine 3"

      assert {:ok, gen, plain} = Generalisation.decode(encoded)
      assert gen.id == "x"
      assert gen.level == 1
      assert plain == "Line 1\nLine 2\nLine 3"
    end

    test "returns :not_a_generalisation for strings without prefix" do
      assert {:error, :not_a_generalisation} = Generalisation.decode("just a regular fact")
      assert {:error, :not_a_generalisation} = Generalisation.decode("- some fact (created 2020)")
    end

    test "returns :not_a_generalisation for empty strings" do
      assert {:error, :not_a_generalisation} = Generalisation.decode("")
    end

    test "raises GeneralisationParseFailed for malformed JSON" do
      assert_raise GeneralisationParseFailed, fn ->
        Generalisation.decode("GEN|v1|not-json\ncontent")
      end
    end

    test "raises GeneralisationParseFailed when required fields are missing" do
      assert_raise GeneralisationParseFailed, fn ->
        Generalisation.decode(~s(GEN|v1|{"id":"x"}\ncontent))
      end
    end

    test "raises GeneralisationParseFailed when level is missing" do
      assert_raise GeneralisationParseFailed, fn ->
        Generalisation.decode(~s(GEN|v1|{"id":"x","confidence":0.5,"generalises":[]}\ncontent))
      end
    end
  end

  describe "struct defaults" do
    test "generalises defaults to empty list" do
      gen = %Generalisation{
        id: "abc",
        content: "test",
        level: 0,
        confidence: 0.5
      }

      assert gen.generalises == []
    end

    test "created_at defaults to nil" do
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
