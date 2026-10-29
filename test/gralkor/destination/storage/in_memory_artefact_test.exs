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

  describe "when in-memory Destination storage is searched with no Lenses" do
    test "then facts, nodes, and episodes of the Destination are returned within their limits" do
      seed_writers()

      assert {:ok, %{facts: facts, nodes: nodes, episodes: episodes}} =
               InMemory.search(%Destination{name: "observations"}, "operator-one", "q",
                 limits: %{facts: 2, nodes: 1, episodes: 3}
               )

      assert Enum.map(facts, & &1.fact) == ["alpha one", "beta one"]
      assert Enum.map(nodes, & &1.id) == ["owned"]

      assert [%{artefact: %{id: "review-id"}}, %{content: "alpha one"}, %{content: "beta one"}] =
               episodes
    end
  end

  describe "when in-memory Destination storage is searched with Lenses" do
    test "then only episodes written through a selected Lens are returned" do
      seed_writers()
      assert {:ok, %{episodes: episodes}} = lens_search(["alpha"])
      assert Enum.map(episodes, & &1.content) == ["alpha one", "alpha two"]
      assert Enum.all?(episodes, &(&1.lens == "alpha"))
    end

    test "and only facts drawn from those episodes or written by a selected Lens's graph replacement are returned" do
      seed_writers()
      assert {:ok, %{facts: facts}} = lens_search(["alpha"])
      assert Enum.map(facts, & &1.fact) == ["alpha one", "alpha two"]

      assert {:ok, %{facts: [replacement]}} = lens_search(["graph"])

      assert %{fact: "owned settles through other", relationship: "SETTLES_THROUGH"} =
               replacement
    end

    test "and only nodes owned by a selected Lens's graph replacement are returned" do
      seed_writers()
      assert {:ok, %{nodes: []}} = lens_search(["alpha"])
      assert {:ok, %{nodes: nodes}} = lens_search(["graph"])
      assert Enum.map(nodes, & &1.id) == ["owned", "other"]
    end

    test "but no direct write or Destination artefact contributes" do
      seed_writers()
      assert {:ok, %{facts: facts, episodes: episodes}} = lens_search(["alpha", "graph"])

      refute Enum.any?(episodes, &Map.has_key?(&1, :artefact))
      refute Enum.any?(episodes, &(Map.get(&1, :writer) == :direct))
      refute Enum.any?(facts, &(&1.fact == "direct one"))
    end

    test "and nodes are limited after Lens filtering" do
      seed_writers()

      GenServer.call(
        Gralkor.Lens.Storage.InMemory,
        {:replace_graph, "observations", "unselected",
         %{
           nodes:
             for(
               id <- 1..3,
               do: %{
                 id: "unselected-#{id}",
                 labels: ["Thing"],
                 properties: %{_gralkor_lens: "unselected"}
               }
             ),
           relationships: []
         }}
      )

      assert {:ok, %{nodes: nodes}} =
               InMemory.search(%Destination{name: "observations"}, "operator-one", "q",
                 limits: %{facts: 20, nodes: 1, episodes: 5},
                 lenses: ["graph"]
               )

      assert Enum.map(nodes, & &1.id) == ["owned"]
    end
  end

  # One Destination holding an artefact, two appending Lenses' episodes, a
  # direct write, and a replaceable Lens's graph.
  defp seed_writers do
    assert :ok =
             InMemory.put_artefact(
               output(),
               "review",
               "operator-one",
               artefact("review-id", %{"summary" => "reviewed"})
             )

    for {content, lens} <- [
          {"alpha one", "alpha"},
          {"beta one", "beta"},
          {"alpha two", "alpha"}
        ] do
      add_episode(%{content: content, lens: lens, source_description: "notes"})
    end

    add_episode(%{content: "direct one", source_description: "manual", writer: :direct})

    store = %Gralkor.Lens.Store{
      operator_id: "operator-one",
      lens: %Gralkor.Lens.Replaceable{
        name: "graph",
        destination: %Destination{name: "observations"}
      }
    }

    assert :ok =
             Gralkor.Lens.Storage.InMemory.replace_graph(store, %Gralkor.Graph{
               nodes: [
                 %{id: "owned", labels: ["Thing"], properties: %{}},
                 %{id: "other", labels: ["Thing"], properties: %{}}
               ],
               relationships: [
                 %{
                   from: "owned",
                   to: "other",
                   type: "RELATES_TO",
                   properties: %{
                     name: "SETTLES_THROUGH",
                     fact: "owned settles through other"
                   }
                 }
               ]
             })
  end

  defp add_episode(episode),
    do: GenServer.call(Gralkor.Lens.Storage.InMemory, {:add, "observations", episode})

  defp lens_search(lenses) do
    InMemory.search(%Destination{name: "observations"}, "operator-one", "q",
      limits: Gralkor.Search.limits(),
      lenses: lenses
    )
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
