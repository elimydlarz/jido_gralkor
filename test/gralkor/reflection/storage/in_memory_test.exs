defmodule Gralkor.Reflection.Storage.InMemoryTest do
  use ExUnit.Case, async: false

  alias Gralkor.Destination
  alias Gralkor.Reflection
  alias Gralkor.Reflection.Artefact
  alias Gralkor.Reflection.Storage.InMemory

  setup do
    start_supervised!(InMemory)
    :ok
  end

  describe "when in-memory storage receives a new artefact" do
    test "then exact lookup and Destination search return it" do
      reflection = reflection()
      artefact = artefact("new-id", %{"summary" => "new"})

      assert :ok = InMemory.put(reflection, "operator-one", artefact)
      assert {:ok, ^artefact} = InMemory.get(reflection, "operator-one", "new-id")

      assert {:ok, [^artefact]} =
               InMemory.search_destination(reflection.destination, "operator-one", "", 20)
    end
  end

  describe "when in-memory storage receives the same artefact identifier repeatedly" do
    test "then equal writes converge on one copy in its original position" do
      reflection = reflection()
      first = artefact("stable-id", %{"summary" => "first"})
      second = artefact("other-id", %{"summary" => "second"})

      assert :ok = InMemory.put(reflection, "operator-one", first)
      assert :ok = InMemory.put(reflection, "operator-one", second)
      assert :ok = InMemory.put(reflection, "operator-one", first)

      assert {:ok, ^first} = InMemory.get(reflection, "operator-one", "stable-id")

      assert {:ok, [^first, ^second]} =
               InMemory.search_destination(
                 reflection.destination,
                 "operator-one",
                 "",
                 20
               )
    end

    test "then conflicting immutable content is rejected and leaves the original unchanged" do
      reflection = reflection()
      original = artefact("stable-id", %{"summary" => "original"})
      conflict = artefact("stable-id", %{"summary" => "changed"})

      assert :ok = InMemory.put(reflection, "operator-one", original)

      assert {:error, {:artefact_conflict, "stable-id"}} =
               InMemory.put(reflection, "operator-one", conflict)

      assert {:ok, ^original} = InMemory.get(reflection, "operator-one", "stable-id")

      assert {:ok, [^original]} =
               InMemory.search_destination(reflection.destination, "operator-one", "", 20)
    end
  end

  defp reflection do
    %Reflection{
      name: "review",
      destination: %Destination{name: "observations"},
      ontology: Gralkor.DefaultOntology,
      chain_of_thought: %Gralkor.Reflection.ChainOfThought{path: "test", steps: []}
    }
  end

  defp artefact(id, payload),
    do: %Artefact{id: id, reflection: "review", payload: payload, evidence_ids: []}
end
