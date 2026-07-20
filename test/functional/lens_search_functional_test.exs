defmodule Gralkor.LensSearchFunctionalTest do
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

  defmodule FailingSearchStorage do
    @behaviour Gralkor.Lens.Storage

    @impl true
    def add_episode(_store, _content, _source_description), do: :ok

    @impl true
    def search(%Gralkor.Lens.Store{lens: %{name: "observations"}}, _query, _max_results),
      do: {:error, :unavailable}

    def search(_store, _query, _max_results), do: {:ok, ["default memory"]}
  end

  defmodule UnexpectedSearchStorage do
    @behaviour Gralkor.Lens.Storage

    @impl true
    def add_episode(_store, _content, _source_description), do: :ok

    @impl true
    def search(_store, _query, _max_results), do: raise("memory query started")
  end

  setup do
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_ontology = Application.get_env(:jido_gralkor, :ontology)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)

    start_supervised!(Gralkor.Lens.Storage.InMemory)

    Application.put_env(:jido_gralkor, :ontology, MemoryOntology)
    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "observations",
        ontology: MemoryOntology,
        scope: :operator,
        ingestion: Gralkor.Lens.Ingestion.Store
      ],
      [
        name: "decisions",
        ontology: MemoryOntology,
        scope: :operator,
        ingestion: Gralkor.Lens.Ingestion.Store
      ],
      [
        name: "published-observations",
        ontology: MemoryOntology,
        scope: :global,
        ingestion: Gralkor.Lens.Ingestion.Store
      ],
      [
        name: "published-decisions",
        ontology: MemoryOntology,
        scope: :global,
        ingestion: Gralkor.Lens.Ingestion.Store
      ]
    ])

    on_exit(fn ->
      restore_env(:lenses, previous_lenses)
      restore_env(:ontology, previous_ontology)
      restore_env(:lens_storage, previous_storage)
    end)

    :ok
  end

  describe "when a caller searches memory" do
    test "then the requesting operator's reserved `default` destination is always searched first" do
      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "default",
                 content: "default memory",
                 source_description: "legacy"
               })

      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "observations",
                 content: "observation memory",
                 source_description: "observation"
               })

      assert {:ok, ["default memory", "observation memory"]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 targets: ["observations"]
               })
    end

    test "and another operator's default memory cannot contribute a result" do
      for {operator, content} <- [
            {"operator-one", "first operator memory"},
            {"operator-two", "second operator memory"}
          ] do
        assert :ok =
                 Client.ingest(%Ingest{
                   operator_id: operator,
                   lens: "default",
                   content: content,
                   source_description: "legacy"
                 })
      end

      assert {:ok, ["first operator memory"]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory"
               })
    end
  end

  describe "where a caller includes the reserved `default` target explicitly" do
    test "then the requesting operator's default destination is searched only once" do
      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "default",
                 content: "default memory",
                 source_description: "legacy"
               })

      assert {:ok, ["default memory"]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 targets: ["default"]
               })
    end
  end

  describe "where a caller supplies no additional search targets" do
    test "then only the requesting operator's reserved `default` destination is searched" do
      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "default",
                 content: "default memory",
                 source_description: "legacy"
               })

      assert {:ok, ["default memory"]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory"
               })
    end
  end

  describe "where a caller supplies additional operator-local Lens or reserved `global` targets" do
    test "then every additional target is searched after the requesting operator's reserved `default` destination" do
      for {lens, content} <- [
            {"default", "default memory"},
            {"observations", "observation memory"},
            {"decisions", "decision memory"}
          ] do
        assert :ok =
                 Client.ingest(%Ingest{
                   operator_id: "operator-one",
                   lens: lens,
                   content: content,
                   source_description: "functional"
                 })
      end

      assert {:ok, ["default memory", "decision memory", "observation memory"]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 targets: ["decisions", "observations"]
               })
    end

    test "and additional results retain their configured target order" do
      for {lens, content} <- [
            {"observations", "observation memory"},
            {"decisions", "decision memory"}
          ] do
        assert :ok =
                 Client.ingest(%Ingest{
                   operator_id: "operator-one",
                   lens: lens,
                   content: content,
                   source_description: "functional"
                 })
      end

      assert {:ok, ["observation memory", "decision memory"]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 targets: ["observations", "decisions"]
               })
    end

    test "and repeated matches from different destinations remain in the response" do
      for lens <- ["observations", "decisions"] do
        assert :ok =
                 Client.ingest(%Ingest{
                   operator_id: "operator-one",
                   lens: lens,
                   content: "shared memory",
                   source_description: "functional"
                 })
      end

      assert {:ok, ["shared memory", "shared memory"]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 targets: ["observations", "decisions"]
               })
    end

    test "and the same maximum result count applies independently to the default and every additional destination" do
      for {lens, content} <- [
            {"default", "default one"},
            {"default", "default two"},
            {"observations", "observation one"},
            {"observations", "observation two"}
          ] do
        assert :ok =
                 Client.ingest(%Ingest{
                   operator_id: "operator-one",
                   lens: lens,
                   content: content,
                   source_description: "functional"
                 })
      end

      assert {:ok, ["default one", "observation one"]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 targets: ["observations"],
                 max_results: 1
               })
    end

    test "and no unselected local Lens or another operator's local memory can contribute a result" do
      for {operator, lens, content} <- [
            {"operator-one", "observations", "selected memory"},
            {"operator-one", "decisions", "unselected memory"},
            {"operator-two", "observations", "other operator memory"}
          ] do
        assert :ok =
                 Client.ingest(%Ingest{
                   operator_id: operator,
                   lens: lens,
                   content: content,
                   source_description: "functional"
                 })
      end

      assert {:ok, ["selected memory"]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 targets: ["observations"]
               })
    end
  end

  describe "where the selection contains the reserved `global` target" do
    test "then every relevant globally stored episode may contribute" do
      for {lens, content} <- [
            {"published-observations", "published observation"},
            {"published-decisions", "published decision"}
          ] do
        assert :ok =
                 Client.ingest(%Ingest{
                   operator_id: "operator-one",
                   lens: lens,
                   content: content,
                   source_description: "functional"
                 })
      end

      assert {:ok, ["published observation", "published decision"]} =
               Client.search(%Search{
                 operator_id: "operator-two",
                 query: "published",
                 targets: ["global"]
               })
    end

    test "and originating Lens does not filter the global results" do
      for {lens, content} <- [
            {"published-observations", "published observation"},
            {"published-decisions", "published decision"}
          ] do
        assert :ok =
                 Client.ingest(%Ingest{
                   operator_id: "operator-one",
                   lens: lens,
                   content: content,
                   source_description: "functional"
                 })
      end

      assert {:ok, ["published observation", "published decision"]} =
               Client.search(%Search{
                 operator_id: "operator-two",
                 query: "published",
                 targets: ["global"]
               })
    end
  end

  describe "where a global Lens name identifies an episode's origin" do
    test "then that name remains attribution rather than a search boundary" do
      assert_raise ArgumentError, ~r/provenance/, fn ->
        Client.search(%Search{
          operator_id: "operator-one",
          query: "published",
          targets: ["published-observations"]
        })
      end
    end

    test "and `global` is the only target that selects globally stored memory" do
      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "published-observations",
                 content: "published observation",
                 source_description: "functional"
               })

      assert {:ok, ["published observation"]} =
               Client.search(%Search{
                 operator_id: "operator-two",
                 query: "published",
                 targets: ["global"]
               })
    end
  end

  describe "if the selected memory search fails" do
    test "then the error is returned without manufacturing a partial memory response" do
      Application.put_env(:jido_gralkor, :lens_storage, FailingSearchStorage)

      assert {:error, :unavailable} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 targets: ["observations"]
               })
    end
  end

  describe "if search supplies an additional target that is neither a registered operator-local Lens nor reserved `default` or `global`" do
    test "then search fails before any memory query is started" do
      Application.put_env(:jido_gralkor, :lens_storage, UnexpectedSearchStorage)

      assert_raise ArgumentError, ~r/unknown Lens "missing"/, fn ->
        Client.search(%Search{
          operator_id: "operator-one",
          query: "memory",
          targets: ["missing"]
        })
      end
    end

    test "and no valid subset is searched" do
      Application.put_env(:jido_gralkor, :lens_storage, UnexpectedSearchStorage)

      assert_raise ArgumentError, ~r/unknown Lens "missing"/, fn ->
        Client.search(%Search{
          operator_id: "operator-one",
          query: "memory",
          targets: ["observations", "missing"]
        })
      end
    end

    test "and the error identifies the invalid target" do
      assert_raise ArgumentError, ~r/missing/, fn ->
        Client.search(%Search{
          operator_id: "operator-one",
          query: "memory",
          targets: ["missing"]
        })
      end
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
