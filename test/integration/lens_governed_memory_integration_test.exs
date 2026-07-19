defmodule Gralkor.LensGovernedMemoryIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Gralkor.Client
  alias Gralkor.Ingest
  alias JidoGralkor.Plugin

  defmodule ObservationOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Observation do
      field(:content, :string, required: true)
    end
  end

  defmodule RecordingIngestion do
    def ingest(request, store) do
      send(Process.whereis(:lens_governed_memory_integration), {:ingested, request, store})
      :ok
    end
  end

  setup do
    Process.register(self(), :lens_governed_memory_integration)
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "observations",
        ontology: ObservationOntology,
        scope: :operator,
        ingestion: RecordingIngestion
      ]
    ])

    on_exit(fn ->
      case previous_lenses do
        nil -> Application.delete_env(:jido_gralkor, :lenses)
        lenses -> Application.put_env(:jido_gralkor, :lenses, lenses)
      end
    end)

    :ok
  end

  describe "when an application registers a Lens with a non-blank name, ontology, local or global scope, and ingestion process" do
    test "then direct callers and mounted memory plugins can select that Lens by name" do
      request = %Ingest{
        operator_id: "operator-one",
        lens: "observations",
        content: "The launch window moved to Friday.",
        source_description: "project update"
      }

      assert :ok = Client.ingest(request)
      assert_receive {:ingested, ^request, %{lens: %{name: "observations"}}}

      opts = %{
        agent_name: "Susu",
        default_lens: "observations",
        search_targets: ["observations"]
      }

      assert {:ok, mount} = Plugin.mount(%{}, opts)
      assert mount.default_lens == "observations"
    end
  end
end
