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

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
