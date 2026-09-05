defmodule Gralkor.Destination.Storage.InMemoryArtefactTest do
  use ExUnit.Case, async: false

  alias Gralkor.Artefact
  alias Gralkor.Destination
  alias Gralkor.Destination.Storage.InMemory

  setup do
    start_supervised!(InMemory)
    :ok
  end

  describe "when in-memory Destination storage receives a new artefact" do
    test "then it stores the artefact at the declared Destination output" do
      output = output()
      artefact = artefact("new-id", %{"summary" => "new"})

      assert :ok = InMemory.put_artefact(output, "review", "operator-one", artefact)
    end

    test "and exact lookup returns that artefact" do
      output = output()
      artefact = artefact("new-id", %{"summary" => "new"})

      assert :ok = InMemory.put_artefact(output, "review", "operator-one", artefact)
      assert {:ok, ^artefact} = InMemory.get_artefact(output, "review", "operator-one", "new-id")
    end

    test "and Destination search returns it in insertion order" do
      output = output()
      artefact = artefact("new-id", %{"summary" => "new"})

      assert :ok = InMemory.put_artefact(output, "review", "operator-one", artefact)

      assert {:ok, [^artefact]} =
               InMemory.search(output.destination, "operator-one", "", :artefacts, 20, [])
    end
  end

  describe "when in-memory Destination storage receives the same artefact identifier and immutable content repeatedly" do
    test "then every write succeeds" do
      output = output()
      artefact = artefact("stable-id", %{"summary" => "first"})

      assert :ok = InMemory.put_artefact(output, "review", "operator-one", artefact)
      assert :ok = InMemory.put_artefact(output, "review", "operator-one", artefact)
    end

    test "and exact lookup and Destination search retain exactly one copy at its original position" do
      output = output()
      first = artefact("stable-id", %{"summary" => "first"})
      second = artefact("other-id", %{"summary" => "second"})

      assert :ok = InMemory.put_artefact(output, "review", "operator-one", first)
      assert :ok = InMemory.put_artefact(output, "review", "operator-one", second)
      assert :ok = InMemory.put_artefact(output, "review", "operator-one", first)

      assert {:ok, ^first} =
               InMemory.get_artefact(output, "review", "operator-one", "stable-id")

      assert {:ok, [^first, ^second]} =
               InMemory.search(output.destination, "operator-one", "", :artefacts, 20, [])
    end
  end

  describe "when in-memory Destination storage receives an existing artefact identifier with different immutable content" do
    test "then the write returns an artefact conflict" do
      output = output()
      original = artefact("stable-id", %{"summary" => "original"})
      conflict = artefact("stable-id", %{"summary" => "changed"})

      assert :ok = InMemory.put_artefact(output, "review", "operator-one", original)

      assert {:error, {:artefact_conflict, "stable-id"}} =
               InMemory.put_artefact(output, "review", "operator-one", conflict)
    end

    test "and exact lookup and Destination search retain the original unchanged" do
      output = output()
      original = artefact("stable-id", %{"summary" => "original"})
      conflict = artefact("stable-id", %{"summary" => "changed"})

      assert :ok = InMemory.put_artefact(output, "review", "operator-one", original)

      assert {:error, {:artefact_conflict, "stable-id"}} =
               InMemory.put_artefact(output, "review", "operator-one", conflict)

      assert {:ok, ^original} =
               InMemory.get_artefact(output, "review", "operator-one", "stable-id")

      assert {:ok, [^original]} =
               InMemory.search(output.destination, "operator-one", "", :artefacts, 20, [])
    end
  end

  defp output,
    do: %{
      kind: :destination,
      destination: %Destination{name: "observations"},
      ontology: Gralkor.DefaultOntology
    }

  defp artefact(id, payload),
    do: %Artefact{id: id, payload: payload}
end
