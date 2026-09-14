defmodule Gralkor.DestinationGraphsFunctionalTest do
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

  describe "when a Lens saves an episode to the `personal` Destination" do
    test "then the resolved graph is named `personal/<operator id>`" do
      assert :ok = ingest("operator-one", "personal-chat", "private observation")

      assert [%{content: "private observation", lens: "personal-chat"}] =
               Gralkor.Lens.Storage.InMemory.episodes("personal/operator-one")
    end

    test "and the episode is unavailable to another operator using the same Destination" do
      assert :ok = ingest("operator-one", "personal-chat", "private observation")

      assert {:ok, []} = search("operator-two", ["personal"])
    end

    test "and the episode is unavailable from any unselected Destination" do
      assert :ok = ingest("operator-one", "personal-chat", "private observation")

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
                %{destination: "global", fact: %{fact: "public observation"}},
                %{destination: "global", fact: %{fact: "public decision"}}
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

      assert {:ok, [%{destination: "observations", fact: %{fact: "shared observation"}}]} =
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

      assert {:ok, [%{fact: %{fact: "public observation"}}, %{fact: %{fact: "public decision"}}]} =
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

  describe "when personal memory is resolved for an existing identity" do
    test "then the identifier is preserved byte for byte in the logical graph name" do
      for identity <- ["owner", "dashboard:AbC-123", "Eli/a:b.c", "A B"] do
        assert Gralkor.Destination.graph_id(%Gralkor.Destination{name: "personal"}, identity) == "personal/" <> identity
      end
    end

    test "and punctuation-sensitive identifiers resolve to distinct physical graphs" do
      names = for identity <- ["a:b", "a_b", "a/b", "A:b"] do
        Gralkor.Destination.graph_id(%Gralkor.Destination{name: "personal"}, identity)
        |> Client.sanitize_group_id()
      end
      assert length(Enum.uniq(names)) == 4
    end
  end

  describe "if a caller resolves a stale Destination named operator" do
    test "then resolution raises a migration error before it can become a shared operator graph" do
      assert_raise ArgumentError, ~r/operator.*retired.*personal/, fn ->
        Gralkor.Destination.graph_id(%Gralkor.Destination{name: "operator"}, "owner")
      end
    end
  end

  describe "if a caller supplies a blank identity or a resolved private graph in place of an identity" do
    test "then personal graph resolution fails before any storage request" do
      for identity <- [nil, "", "  ", "operator/owner", "personal/owner"] do
        assert_raise ArgumentError, ~r/operator_id/, fn ->
          Gralkor.Destination.graph_id(%Gralkor.Destination{name: "personal"}, identity)
        end
      end
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
      id: "destination-#{operator}-#{lens}-#{System.unique_integer([:positive])}",
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
      destinations: destinations,
      result_type: :facts
    })
  end

  defp destination(name), do: [name: name]

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
