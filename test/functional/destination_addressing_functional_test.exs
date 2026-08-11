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
      destination("observations", "operator/observations"),
      destination("decisions", "operator/decisions"),
      destination("published", "global/published")
    ])

    Application.put_env(:jido_gralkor, :lenses, [
      lens("observations", "observations"),
      lens("decisions", "decisions"),
      lens("published-observations", "published"),
      lens("published-decisions", "published")
    ])

    on_exit(fn ->
      restore_env(:lenses, previous_lenses)
      restore_env(:destinations, previous_destinations)
      restore_env(:lens_storage, previous_storage)
      restore_env(:destination_storage, previous_destination_storage)
    end)

    :ok
  end

  describe "when a Lens saves an episode to an `operator/path` Destination" do
    test "then the resolved graph is determined by the operator and address path together" do
      assert :ok = ingest("operator-one", "observations", "private observation")

      assert [%{content: "private observation", lens: "observations"}] =
               Gralkor.Lens.Storage.InMemory.episodes(group("observations", "operator-one"))
    end

    test "and the episode is unavailable from any unselected Destination" do
      assert :ok = ingest("operator-one", "observations", "private observation")

      assert {:ok, []} = search("operator-one", ["decisions"])
    end

    test "and the episode is unavailable to another operator using the same Destination" do
      assert :ok = ingest("operator-one", "observations", "private observation")

      assert {:ok, []} = search("operator-two", ["observations"])
    end

  end

  describe "when a Lens saves an episode to a `global/path` Destination" do
    test "then every operator resolves the same graph for that address path" do
      assert :ok = ingest("operator-one", "published-observations", "public observation")
      assert :ok = ingest("operator-two", "published-decisions", "public decision")

      assert {:ok,
              [
                %{destination: "published", fact: "public observation"},
                %{destination: "published", fact: "public decision"}
              ]} =
               search("operator-three", ["published"])
    end

    test "and the episode is unavailable from any unselected Destination" do
      assert :ok = ingest("operator-one", "published-observations", "public observation")
      assert {:ok, []} = search("operator-one", ["observations"])
    end
  end

  describe "when multiple Lenses save episodes to the same Destination" do
    test "then every episode is available by searching that Destination" do
      assert :ok = ingest("operator-one", "published-observations", "public observation")
      assert :ok = ingest("operator-one", "published-decisions", "public decision")

      assert {:ok, [%{fact: "public observation"}, %{fact: "public decision"}]} =
               search("operator-one", ["published"])
    end
  end

  describe "where a Lens references an operator or global Destination" do
    test "then that Destination's address and ontology govern every episode the Lens's ingestion process submits" do
      Application.put_env(:jido_gralkor, :destinations, [
        destination("summaries", "global/summaries")
      ])

      Application.put_env(:jido_gralkor, :lenses, [
        lens("summaries", "summaries") |> Keyword.put(:ingestion, MultipleIngestion)
      ])

      assert :ok = ingest("operator-one", "summaries", "summary")

      assert [
               %{content: "first summary", lens: "summaries"},
               %{content: "second summary", lens: "summaries"}
             ] =
               Gralkor.Lens.Storage.InMemory.episodes(group("summaries", "operator-one"))

      assert Client.lens!("summaries").destination.ontology == MemoryOntology
    end
  end

  defp lens(name, destination) do
    [
      name: name,
      destination: destination,
      ingestion: Gralkor.Lens.Ingestion.Store
    ]
  end

  defp ingest(operator, lens, content) do
    Client.ingest(%Ingest{
      operator_id: operator,
      lens: lens,
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

  defp destination(name, address),
    do: [name: name, address: address, ontology: MemoryOntology]

  defp group(destination_name, operator_id) do
    destination = Gralkor.Destination.Registry.fetch!(destination_name)
    Gralkor.Destination.graph_id(destination, operator_id)
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
