defmodule Gralkor.IngestedInformationProvenanceFunctionalTest do
  use ExUnit.Case, async: false

  alias Gralkor.Client
  alias Gralkor.GraphitiPool
  alias Gralkor.Ingest

  @moduletag :functional

  defmodule RecordingStorage do
    @behaviour Gralkor.Lens.Storage

    @impl true
    def add_episode(store, content, source_description) do
      send(
        Process.whereis(:ingested_information_provenance_functional),
        {:episode_added, store, content, source_description}
      )

      :ok
    end

    @impl true
    def search(_store, _query, _max_results), do: {:ok, []}

    @impl true
    def replace_graph(_store, _graph), do: :ok
  end

  defmodule NativeBoundaryStorage do
    @behaviour Gralkor.Lens.Storage

    @impl true
    def add_episode(store, content, source_description) do
      Gralkor.Lens.Storage.Graphiti.add_episode(store, content, source_description,
        add_episode_fn: fn group_id, body, description, ontology, opts ->
          Gralkor.GraphitiPool.add_episode(
            :provenance_graphiti_pool,
            group_id,
            body,
            description,
            ontology,
            opts
          )
        end
      )
    end

    @impl true
    def search(_store, _query, _max_results), do: {:ok, []}

    @impl true
    def replace_graph(_store, _graph), do: :ok
  end

  setup do
    Process.register(self(), :ingested_information_provenance_functional)

    previous_destinations = Application.get_env(:jido_gralkor, :destinations)
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)

    Application.put_env(:jido_gralkor, :destinations, [
      [name: "observations", address: "operator/observations"]
    ])

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "observations",
        destination: "observations",
        ingestion: Gralkor.Lens.Ingestion.Store
      ]
    ])

    Application.put_env(:jido_gralkor, :lens_storage, RecordingStorage)

    on_exit(fn ->
      restore_env(:destinations, previous_destinations)
      restore_env(:lenses, previous_lenses)
      restore_env(:lens_storage, previous_storage)
    end)

    :ok
  end

  describe "when information is submitted through public ingestion with a supported source kind" do
    test "then its stored episode retains the declared source kind" do
      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "observations",
                 source_kind: :conversation,
                 content: "Mina: Atlas might launch Friday.",
                 source_description: "planning conversation"
               })

      assert_receive {:episode_added,
                      %Gralkor.Lens.Store{source_kind: :conversation},
                      "Mina: Atlas might launch Friday.", "planning conversation"}
    end

    test "and its stored episode retains the reported source description" do
      assert :ok = Client.ingest(request(:document, "Draft launch plan", "Q3 Roadmap — Draft"))

      assert_receive {:episode_added, %Gralkor.Lens.Store{}, "Draft launch plan",
                      "Q3 Roadmap — Draft"}
    end
  end

  describe "where the source kind is conversation" do
    test "while the supplied content is speaker-attributed text then Graphiti receives a conversational-message episode containing that text" do
      graphiti = use_native_boundary()

      assert :ok =
               Client.ingest(
                 request(
                   :conversation,
                   "Mina: Atlas might launch Friday.",
                   "planning conversation"
                 )
               )

      assert [%{"body" => "Mina: Atlas might launch Friday.", "source" => "message"}] =
               added_episodes(graphiti)
    end
  end

  defp request(source_kind, content, source_description) do
    %Ingest{
      operator_id: "operator-one",
      lens: "observations",
      source_kind: source_kind,
      content: content,
      source_description: source_description
    }
  end

  defp use_native_boundary do
    Application.put_env(:jido_gralkor, :lens_storage, NativeBoundaryStorage)

    {graphiti, _} =
      Pythonx.eval(
        """
        class _Graphiti:
            def __init__(self):
                self.added = []

            async def add_episode(self, **kwargs):
                self.added.append({
                    "body": kwargs.get("episode_body"),
                    "source": kwargs.get("source").value,
                    "source_description": kwargs.get("source_description"),
                    "custom_extraction_instructions": kwargs.get("custom_extraction_instructions"),
                })

        _Graphiti()
        """,
        %{}
      )

    table = :"provenance_functional_#{System.unique_integer([:positive])}"

    start_supervised!({GraphitiPool,
      name: :provenance_graphiti_pool,
      table: table,
      falkordb_spec: {:embedded, "/tmp/never_used"},
      construct_falkor_db: fn _spec -> :stub_falkor_db end,
      construct_shared_clients: fn _llm, _embedder ->
        %{llm_client: nil, embedder: nil, cross_encoder: nil}
      end,
      construct_instance: fn _db, _shared, _group_id -> graphiti end,
      initialise_instance: fn _instance -> :ok end,
      warmup: false,
      install_loop_fn: &Gralkor.Python.install_async_runtime/0
    })

    graphiti
  end

  defp added_episodes(graphiti) do
    {episodes, _} = Pythonx.eval("g.added", %{"g" => graphiti})
    Pythonx.decode(episodes)
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
