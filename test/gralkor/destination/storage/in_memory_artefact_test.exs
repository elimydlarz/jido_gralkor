defmodule Gralkor.Destination.Storage.InMemoryArtefactTest do
  use ExUnit.Case, async: false

  alias Gralkor.Artefact
  alias Gralkor.Destination
  alias Gralkor.Destination.Storage.InMemory

  setup do
    start_supervised!(InMemory)
    start_supervised!(Gralkor.Lens.Storage.InMemory)
    :ok
  end

  describe "when in-memory Destination storage receives a new artefact" do
    test "then it stores the artefact at the declared Destination output" do
      output = output()
      artefact = artefact("new-id", %{"summary" => "new"})

      assert :ok = InMemory.put_artefact(output, "review", "operator-one", artefact)

      assert {:ok, [^artefact]} =
               searched_artefacts(output.destination)

      assert {:ok, []} =
               searched_artefacts(%Destination{name: "global"})
    end

    test "and exact lookup returns that artefact" do
      output = output()
      artefact = artefact("new-id", %{"summary" => "new"})

      assert :ok = InMemory.put_artefact(output, "review", "operator-one", artefact)
      assert {:ok, ^artefact} = InMemory.get_artefact(output, "review", "operator-one", "new-id")
    end

    test "and Destination search returns it in insertion order" do
      output = output()
      earlier = artefact("earlier-id", %{"summary" => "earlier"})
      artefact = artefact("new-id", %{"summary" => "new"})

      assert :ok = InMemory.put_artefact(output, "review", "operator-one", earlier)
      assert :ok = InMemory.put_artefact(output, "review", "operator-one", artefact)

      assert {:ok, [^earlier, ^artefact]} =
               searched_artefacts(output.destination)
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
               searched_artefacts(output.destination)
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
               searched_artefacts(output.destination)
    end
  end

  describe "when in-memory Destination storage looks up an absent artefact identifier" do
    test "then lookup reports not found" do
      assert {:error, :not_found} =
               InMemory.get_artefact(output(), "review", "operator-one", "absent")
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

  defp searched_artefacts(destination) do
    with {:ok, %{episodes: episodes}} <-
           InMemory.search(destination, "operator-one", "", limits: Gralkor.Search.limits()) do
      {:ok, Enum.map(episodes, &struct!(Artefact, &1.artefact))}
    end
  end
end
