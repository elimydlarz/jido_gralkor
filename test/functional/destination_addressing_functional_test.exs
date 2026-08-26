defmodule Gralkor.DestinationAddressingFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Ingest
  alias Gralkor.Search

  defmodule MemoryOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Memory do
      field(:content, :string, required: true)
    end
  end

  defmodule MultipleIngestion do
    @behaviour Gralkor.Lens.Ingestion

    @impl true
    def ingest(request, store) do
      with :ok <-
             Gralkor.Lens.Store.add(store, "first #{request.content}", request.source_description) do
        Gralkor.Lens.Store.add(store, "second #{request.content}", request.source_description)
      end
    end
  end

  setup do
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_destinations = Application.get_env(:jido_gralkor, :destinations)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)
    previous_destination_storage = Application.get_env(:jido_gralkor, :destination_storage)

    start_supervised!(Gralkor.Lens.Storage.InMemory)

    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

    Application.put_env(
      :jido_gralkor,
      :destination_storage,
      Gralkor.Destination.Storage.InMemory
    )

    Application.put_env(:jido_gralkor, :destinations, [
      destination("observations"),
      destination("decisions")
    ])

    Application.put_env(:jido_gralkor, :lenses, [
      lens("observations", "observations"),
      lens("decisions", "decisions"),
      lens("published-observations", "global"),
      lens("published-decisions", "global")
    ])

    on_exit(fn ->
      restore_env(:lenses, previous_lenses)
      restore_env(:destinations, previous_destinations)
      restore_env(:lens_storage, previous_storage)
      restore_env(:destination_storage, previous_destination_storage)
    end)

    :ok
  end

  describe "when a Lens saves an episode to the `operator` Destination" do
    test "then the resolved graph is named `operator/<operator id>`" do
      assert :ok = ingest("operator-one", "operator", "private observation")

      assert [%{content: "private observation", lens: "observations"}] =
               Gralkor.Lens.Storage.InMemory.episodes("operator/operator-one")
    end

    test "and the episode is unavailable to another operator using the same Destination" do
      assert :ok = ingest("operator-one", "operator", "private observation")

      assert {:ok, []} = search("operator-two", ["operator"])
    end

    test "and the episode is unavailable from any unselected Destination" do
      assert :ok = ingest("operator-one", "operator", "private observation")

      assert {:ok, []} = search("operator-one", ["decisions"])
    end
  end

  describe "when a Lens saves an episode to the `global` Destination" do
    test "then every operator resolves the one graph named `global`" do
      assert :ok = ingest("operator-one", "published-observations", "public observation")
      assert :ok = ingest("operator-two", "published-decisions", "public decision")

      assert Enum.map(Gralkor.Lens.Storage.InMemory.episodes("global"), & &1.content) == [
               "public observation",
               "public decision"
             ]
    end

    test "and every operator can retrieve the episode by searching the `global` Destination" do
      assert :ok = ingest("operator-one", "published-observations", "public observation")
      assert :ok = ingest("operator-two", "published-decisions", "public decision")

      assert {:ok,
              [
                %{destination: "global", fact: "public observation"},
                %{destination: "global", fact: "public decision"}
              ]} =
               search("operator-three", ["global"])
    end

    test "and the episode is unavailable from any unselected Destination" do
      assert :ok = ingest("operator-one", "published-observations", "public observation")
      assert {:ok, []} = search("operator-one", ["observations"])
    end
  end

  describe "when a Lens saves an episode to an application Destination" do
    test "then its one graph is named for that Destination" do
      assert :ok = ingest("operator-one", "observations", "shared observation")

      assert [%{content: "shared observation", lens: "observations"}] =
               Gralkor.Lens.Storage.InMemory.episodes("observations")
    end

    test "and every operator can retrieve the episode by searching that Destination" do
      assert :ok = ingest("operator-one", "observations", "shared observation")

      assert {:ok, [%{destination: "observations", fact: "shared observation"}]} =
               search("operator-two", ["observations"])
    end

    test "and the episode is unavailable from any unselected Destination" do
      assert :ok = ingest("operator-one", "observations", "shared observation")

      assert {:ok, []} = search("operator-two", ["decisions"])
    end
  end

  describe "when multiple Lenses save episodes to the same Destination" do
    test "then every episode is available by searching that Destination" do
      assert :ok = ingest("operator-one", "published-observations", "public observation")
      assert :ok = ingest("operator-one", "published-decisions", "public decision")

      assert {:ok, [%{fact: "public observation"}, %{fact: "public decision"}]} =
               search("operator-one", ["global"])
    end
  end

  describe "where a Lens references a registered Destination" do
    test "then that Destination governs the graph for every episode the Lens's ingestion process submits" do
      Application.put_env(:jido_gralkor, :destinations, [
        destination("summaries")
      ])

      Application.put_env(:jido_gralkor, :lenses, [
        lens("summaries", "summaries") |> Keyword.put(:ingestion, MultipleIngestion)
      ])

      assert :ok = ingest("operator-one", "summaries", "summary")

      assert [
               %{content: "first summary", lens: "summaries"},
               %{content: "second summary", lens: "summaries"}
             ] =
               Gralkor.Lens.Storage.InMemory.episodes("summaries")

      assert Client.lens!("summaries").destination.name == "summaries"
    end
  end

  defp lens(name, destination) do
    [
      name: name,
      destination: destination,
      ontology: MemoryOntology,
      ingestion: Gralkor.Lens.Ingestion.Store
    ]
  end

  defp ingest(operator, lens, content) do
    Client.ingest(%Ingest{
      operator_id: operator,
      lens: lens,
      source_kind: :document,
      content: content,
      source_description: "functional"
    })
  end

  defp search(operator, destinations) do
    Client.search(%Search{
      operator_id: operator,
      query: "memory",
      destinations: destinations
    })
  end

  defp destination(name), do: [name: name]

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
