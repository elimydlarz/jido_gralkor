defmodule Gralkor.ArtefactTest do
  use ExUnit.Case, async: true

  alias Gralkor.Artefact

  describe "when a consumer constructs an artefact from a stable identifier and structured payload" do
    test "then one `%Gralkor.Artefact{}` is returned" do
      assert %Artefact{} = Artefact.new("release-review-42", %{"approved" => true})
    end

    test "and it contains exactly that identifier and payload" do
      payload = %{"assessment" => %{"approved" => false, "reasons" => ["missing checkpoint"]}}

      assert Map.from_struct(Artefact.new("release-review-42", payload)) ==
               %{id: "release-review-42", payload: payload}
    end
  end

  describe "when an artefact identifier is derived from an operator, invocation, and Reflection name" do
    test "then the same ordered identity tuple always produces the same identifier" do
      identity = {"operator-42", "release-2026-09", "release-review"}
      {operator, invocation, reflection} = identity
      expected = Artefact.id_for(operator, invocation, reflection)

      task = Task.async(fn -> Artefact.id_for(operator, invocation, reflection) end)
      assert Task.await(task) == expected
      assert Artefact.id_for(operator, invocation, reflection) == expected
    end

    test "and boundaries between identity components remain unambiguous" do
      identities = [
        {"ab", "c", "d"},
        {"a", "bc", "d"},
        {"a", "b", "cd"},
        {"a:b", "c", "d"},
        {"a", "b:c", "d"},
        {"a", "b", "c:d"}
      ]

      identifiers = Enum.map(identities, fn {a, b, c} -> Artefact.id_for(a, b, c) end)
      assert length(Enum.uniq(identifiers)) == length(identities)
    end

    test "and changing any identity component changes the derived identifier" do
      original = Artefact.id_for("operator", "invocation", "reflection")

      for identity <- [
            {"other", "invocation", "reflection"},
            {"operator", "other", "reflection"},
            {"operator", "invocation", "other"}
          ] do
        {operator, invocation, reflection} = identity
        refute Artefact.id_for(operator, invocation, reflection) == original
      end
    end
  end
end
