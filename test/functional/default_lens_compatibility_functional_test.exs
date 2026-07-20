defmodule Gralkor.DefaultLensCompatibilityFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Ingest

  defmodule MemoryOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Memory do
      field(:content, :string, required: true)
    end
  end

  defmodule RecordingStorage do
    @behaviour Gralkor.Lens.Storage

    @impl true
    def add_episode(store, content, source_description) do
      send(
        Process.whereis(:default_lens_compatibility_functional),
        {:episode_added, store, content, source_description}
      )

      :ok
    end

    @impl true
    def search(_store, _query, _max_results), do: {:ok, []}
  end

  setup do
    Process.register(self(), :default_lens_compatibility_functional)

    keys = [:client, :lenses, :lens_storage, :ontology]
    previous = Map.new(keys, &{&1, Application.get_env(:jido_gralkor, &1)})

    Application.delete_env(:jido_gralkor, :lenses)
    Application.put_env(:jido_gralkor, :lens_storage, RecordingStorage)

    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)

    :ok
  end

  describe "where an application has not registered or selected a named Lens" do
    test "then the implicit `default` Lens preserves access to the operator's existing memory partition" do
      Application.put_env(:jido_gralkor, :ontology, MemoryOntology)

      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "default",
                 content: "compatible memory",
                 source_description: "legacy"
               })

      assert_receive {:episode_added,
                      %Gralkor.Lens.Store{
                        operator_id: "operator-one",
                        lens: %Gralkor.Lens{name: "default", scope: :operator}
                      }, "compatible memory", "legacy"}
    end

    test "and the `:jido_gralkor, :ontology` value remains its ontology" do
      Application.put_env(:jido_gralkor, :ontology, MemoryOntology)

      assert %Gralkor.Lens{name: "default", ontology: MemoryOntology} =
               Client.lens!("default")
    end

    test "and an unset `:jido_gralkor, :ontology` preserves generic extraction" do
      Application.delete_env(:jido_gralkor, :ontology)

      assert %Gralkor.Lens{
               name: "default",
               ontology: nil,
               scope: :operator,
               ingestion: Gralkor.Lens.Ingestion.Store
             } = Client.lens!("default")
    end

    test "and existing capture, memory addition, and recall preserve legacy behaviour" do
      Application.put_env(:jido_gralkor, :client, Gralkor.Client.InMemory)
      Gralkor.Client.InMemory.reset()
      Gralkor.Client.InMemory.set_capture(:ok)
      Gralkor.Client.InMemory.set_memory_add(:ok)
      Gralkor.Client.InMemory.set_recall({:ok, "legacy memory"})

      messages = [%Gralkor.Message{role: "user", content: "Remember this."}]

      assert :ok =
               Client.impl().capture(
                 "session-one",
                 "operator_one",
                 "Susu",
                 "Eli",
                 messages
               )

      assert :ok = Client.impl().memory_add("operator_one", "Legacy fact.", "manual")

      assert {:ok, "legacy memory"} =
               Client.impl().recall("operator_one", "Susu", "session-one", "fact")

      assert [["session-one", "operator_one", "Susu", "Eli", ^messages]] =
               Gralkor.Client.InMemory.captures()

      assert [["operator_one", "Legacy fact.", "manual"]] =
               Gralkor.Client.InMemory.adds()

      assert [["operator_one", "Susu", "session-one", "fact"]] =
               Gralkor.Client.InMemory.recalls()
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
