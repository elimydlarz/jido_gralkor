defmodule Gralkor.FormatTest do
  use ExUnit.Case, async: true

  alias Gralkor.Format

  describe "ex-format-fact > format_fact/1" do
    test "renders a fact with no timestamps as '- {fact}'" do
      assert "- X is a thing" = Format.format_fact(%{fact: "X is a thing"})
    end

    test "appends each present timestamp in parentheses in order" do
      result =
        Format.format_fact(%{
          fact: "X is a thing",
          created_at: "2020-01-02T03:04:05Z",
          valid_at: "2020-01-03T00:00:00Z",
          invalid_at: "2022-06-01T12:00:00Z",
          expired_at: "2023-01-01T00:00:00Z"
        })

      assert result =~ "- X is a thing"
      assert result =~ "(created 2020-01-02T03:04:05+0)"
      assert result =~ "(valid from 2020-01-03T00:00:00+0)"
      assert result =~ "(invalid since 2022-06-01T12:00:00+0)"
      assert result =~ "(expired 2023-01-01T00:00:00+0)"

      created_idx = String.split(result, "(created") |> hd() |> String.length()
      valid_idx = String.split(result, "(valid from") |> hd() |> String.length()
      invalid_idx = String.split(result, "(invalid since") |> hd() |> String.length()
      expired_idx = String.split(result, "(expired") |> hd() |> String.length()

      assert created_idx < valid_idx
      assert valid_idx < invalid_idx
      assert invalid_idx < expired_idx
    end

    test "skips absent timestamps" do
      assert "- X (created 2020-01-02T03:04:05+0)" =
               Format.format_fact(%{fact: "X", created_at: "2020-01-02T03:04:05Z"})
    end
  end

  describe "ex-format-fact > format_timestamp/1" do
    test "strips fractional seconds" do
      assert "2020-01-02T03:04:05+0" = Format.format_timestamp("2020-01-02T03:04:05.123456Z")
    end

    test "converts a trailing 'Z' to '+0'" do
      assert "2020-01-02T03:04:05+0" = Format.format_timestamp("2020-01-02T03:04:05Z")
    end

    test "compacts +HH:00 to +H" do
      assert "2020-01-02T03:04:05+5" = Format.format_timestamp("2020-01-02T03:04:05+05:00")
    end

    test "compacts -HH:00 to -H" do
      assert "2020-01-02T03:04:05-8" = Format.format_timestamp("2020-01-02T03:04:05-08:00")
    end

    test "preserves a non-zero minute offset as +H:MM" do
      assert "2020-01-02T03:04:05+5:30" = Format.format_timestamp("2020-01-02T03:04:05+05:30")
    end
  end

  describe "ex-format-fact > format_facts/1" do
    test "when the list is empty, returns ''" do
      assert "" = Format.format_facts([])
    end

    test "when the list has facts, joins format_fact/1 results with newlines" do
      result =
        Format.format_facts([
          %{fact: "X"},
          %{fact: "Y", created_at: "2020-01-01T00:00:00Z"}
        ])

      assert result == "- X\n- Y (created 2020-01-01T00:00:00+0)"
    end
  end
end
