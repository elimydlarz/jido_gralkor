defmodule Gralkor.LensMemoryScopeFunctionalTest do
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
    previous_ontology = Application.get_env(:jido_gralkor, :ontology)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)

    start_supervised!(Gralkor.Lens.Storage.InMemory)

    Application.put_env(:jido_gralkor, :ontology, MemoryOntology)
    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

    Application.put_env(:jido_gralkor, :lenses, [
      lens("observations", :operator),
      lens("decisions", :operator),
      lens("published-observations", :global),
      lens("published-decisions", :global)
    ])

    on_exit(fn ->
      restore_env(:lenses, previous_lenses)
      restore_env(:ontology, previous_ontology)
      restore_env(:lens_storage, previous_storage)
    end)

    :ok
  end

  describe "when an operator-local Lens adds an episode" do
    test "then its group is determined by the operator and Lens together" do
      assert :ok = ingest("operator-one", "observations", "private observation")

      assert [%{content: "private observation", lens: "observations"}] =
               Gralkor.Lens.Storage.InMemory.episodes({"operator-one", "observations"})
    end

    test "and the episode is unavailable through another local Lens belonging to the same operator" do
      assert :ok = ingest("operator-one", "observations", "private observation")

      assert {:ok, []} = search("operator-one", ["decisions"])
    end

    test "and the episode is unavailable to another operator using a Lens with the same name" do
      assert :ok = ingest("operator-one", "observations", "private observation")

      assert {:ok, []} = search("operator-two", ["observations"])
    end

    test "and the episode is unavailable from shared global memory" do
      assert :ok = ingest("operator-one", "observations", "private observation")

      assert {:ok, []} = search("operator-one", ["global"])
    end
  end

  describe "when a global Lens adds an episode" do
    test "then the episode enters the one global group shared by every global Lens and every operator" do
      assert :ok = ingest("operator-one", "published-observations", "public observation")
      assert :ok = ingest("operator-two", "published-decisions", "public decision")

      assert {:ok, ["public observation", "public decision"]} =
               search("operator-three", ["global"])
    end

    test "and the same episode submission records the name of its originating Lens" do
      assert :ok = ingest("operator-one", "published-observations", "public observation")

      assert [%{content: "public observation", lens: "published-observations"}] =
               Gralkor.Lens.Storage.InMemory.episodes(:global)
    end

    test "and the ingestion process does not have to add Lens provenance itself" do
      assert :ok = ingest("operator-one", "published-decisions", "public decision")

      assert [%{lens: "published-decisions"}] =
               Gralkor.Lens.Storage.InMemory.episodes(:global)
    end
  end

  describe "where a Lens is registered as operator-local or global" do
    test "then that scope governs every episode the Lens's ingestion process submits" do
      Application.put_env(:jido_gralkor, :lenses, [
        lens("summaries", :global) |> Keyword.put(:ingestion, MultipleIngestion)
      ])

      assert :ok = ingest("operator-one", "summaries", "summary")

      assert [
               %{content: "first summary", lens: "summaries"},
               %{content: "second summary", lens: "summaries"}
             ] = Gralkor.Lens.Storage.InMemory.episodes(:global)

      assert Gralkor.Lens.Storage.InMemory.episodes({"operator-one", "summaries"}) == []
    end
  end

  defp lens(name, scope) do
    [
      name: name,
      ontology: MemoryOntology,
      scope: scope,
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

  defp search(operator, lenses) do
    Client.search(%Search{
      operator_id: operator,
      query: "memory",
      lenses: lenses
    })
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
