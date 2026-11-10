defmodule Gralkor.PersonalMemoryFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Search

  setup context do
    keys = [:client, :destination_storage, :lens_storage, :ontology]
    previous = Map.new(keys, &{&1, Application.get_env(:jido_gralkor, &1)})

    if ontology = context[:retained_deployment_ontology] do
      Application.put_env(:jido_gralkor, :ontology, ontology)
    end

    Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)
    Application.put_env(:jido_gralkor, :destination_storage, Gralkor.Destination.Storage.Graphiti)
    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.Graphiti)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value,
          do: Application.put_env(:jido_gralkor, key, value),
          else: Application.delete_env(:jido_gralkor, key)
      end)
    end)

    {graphiti, _} =
      Pythonx.eval(
        """
        from types import SimpleNamespace
        class PersonalGraphFixture:
            def __init__(self):
                self.episodes = []
                self.recorded = []
                self.driver = self
                self._gralkor_completed_episode_uuids = set()
            @property
            def _gralkor_episode_count(self):
                return len(self.episodes)
            async def add_episode(self, **kwargs):
                self.recorded.append(kwargs)
                from graphiti_core.nodes import EpisodicNode
                guard = getattr(EpisodicNode, '_gralkor_requested_uuid_guard', None)
                context = guard.get() if guard is not None else None
                writer = context.get('writer') if context is not None else None
                self.episodes.append(SimpleNamespace(uuid=str(len(self.episodes)), content=kwargs['episode_body'], source_description=kwargs['source_description'], source=kwargs['source'], _gralkor_writer=writer))
            async def search_(self, query, config=None, group_ids=None, search_filter=None):
                return SimpleNamespace(edges=[], nodes=[], episodes=self.episodes[:config.limit])
        PersonalGraphFixture()
        """,
        %{}
      )

    start_supervised!(
      {Gralkor.GraphitiPool,
       construct_falkor_db: fn _ -> :fixture end,
       falkordb_spec: {:embedded, "/tmp/never_used"},
       construct_shared_clients: fn _spec ->
         %{llm_client: nil, embedder: nil, cross_encoder: nil}
       end,
       construct_instance: fn _, _, _ -> graphiti end,
       initialise_instance: fn _ -> :ok end,
       warmup: false,
       install_loop_fn: &Gralkor.Python.install_async_runtime/0}
    )

    start_supervised!(
      {JidoGralkor.Runtime,
       owner: self(),
       configuration: %{
         destinations: [],
         lenses: [
           %{
             name: "notes",
             destination: "personal",
             ingestion: Gralkor.Lens.Ingestion.Store
           }
         ],
         reflections: []
       }}
    )

    %{graphiti: graphiti}
  end

  describe "when an application adds memory directly to an operator's personal graph without selecting a Lens" do
    test "then the graph named `personal/<operator id>` receives the conversation", context do
      remember({:direct, "personal"})
      assert [record] = recorded(context.graphiti)
      assert record["group_id"] == Client.sanitize_group_id("personal/owner")
    end

    test "and jido_gralkor's built-in ontology governs extraction", context do
      remember({:direct, "personal"})
      assert [record] = recorded(context.graphiti)
      assert record["has_entity_types"] == false
    end

    test "and public search returns the conversation without Lens or Reflection authorship" do
      remember({:direct, "personal"})
      assert {:ok, [%{destination: "personal", episodes: [episode]}]} = search()
      assert episode.content == "Eli: Remember teal"
      assert episode.source_kind == "conversation"
      assert episode.writer == :direct
      refute Map.has_key?(episode, :lens)
      refute Map.has_key?(episode, :reflection)
    end

    test "and no packaged Lens ingestion process runs", context do
      remember({:direct, "personal"})

      assert [%{"source_description" => "captured [gralkor: direct]"}] =
               recorded(context.graphiti)
    end
  end

  describe "when an application selects the packaged personal-chat Lens" do
    test "then its Store ingestion process writes to that operator's personal Destination",
         context do
      remember({:lenses, ["personal-chat"]})
      assert [%{"group_id" => group}] = recorded(context.graphiti)
      assert group == Client.sanitize_group_id("personal/owner")
    end

    test "and its built-in ontology applies to conversation and other supported source kinds",
         context do
      for {kind, content} <- [
            {:conversation, "Eli: hello"},
            {:document, "hello"},
            {:structured_record, %{hello: true}}
          ] do
        assert :ok =
                 Client.ingest(self(), %Gralkor.Ingest{
                   id: "kind-#{kind}",
                   operator_id: "owner",
                   lens: "personal-chat",
                   source_kind: kind,
                   content: content,
                   source_description: "source"
                 })
      end

      records = recorded(context.graphiti)
      assert length(records) == 3

      for record <- records do
        assert record["group_id"] == Client.sanitize_group_id("personal/owner")
        assert record["has_entity_types"] == false
        assert record["has_edge_types"] == false
      end
    end

    test "and its stored episode identifies personal-chat as the originating Lens" do
      remember({:lenses, ["personal-chat"]})
      assert {:ok, [%{destination: "personal", episodes: [%{lens: "personal-chat"}]}]} = search()
    end

    test "and no additional direct write occurs", context do
      remember({:lenses, ["personal-chat"]})

      assert [%{"source_description" => "captured [lens: personal-chat]"}] =
               recorded(context.graphiti)
    end
  end

  describe "when direct memory addition and a genuine consumer Lens target personal memory for the same operator" do
    test "then both routes use the same personal graph", context do
      remember({:direct, "personal"})
      remember({:lenses, ["notes"]})
      assert [first, second] = recorded(context.graphiti)
      assert first["group_id"] == second["group_id"]
    end

    test "and each write retains its actual originating route" do
      remember({:direct, "personal"})
      remember({:lenses, ["notes"]})

      assert {:ok, [%{destination: "personal", episodes: [%{writer: :direct}, %{lens: "notes"}]}]} =
               search()
    end
  end

  describe "if an application selects the retired operator Lens or Destination" do
    test "then the request fails with an explicit migration error before graph access",
         context do
      assert_raise ArgumentError, ~r/retired/, fn -> remember({:lenses, ["operator"]}) end

      assert_raise ArgumentError, ~r/retired/, fn ->
        Client.search(self(), %Search{
          operator_id: "owner",
          query: "teal",
          destinations: ["operator"]
        })
      end

      assert recorded(context.graphiti) == []
    end
  end

  describe "if an application retains the removed deployment-wide `:jido_gralkor, :ontology` setting" do
    @tag retained_deployment_ontology: Gralkor.TestOntologies.Strict
    test "then personal-chat still uses jido_gralkor's built-in ontology", context do
      remember({:lenses, ["personal-chat"]})

      assert [record] = recorded(context.graphiti)
      assert record["source_description"] == "captured [lens: personal-chat]"
      assert record["has_entity_types"] == false
      assert record["has_edge_types"] == false
    end
  end

  defp remember({:direct, "personal"}) do
    assert :ok =
             Client.impl().memory_add(
               Client.personal_graph_id("owner"),
               "Eli: Remember teal",
               "captured",
               :conversation
             )
  end

  defp remember({:lenses, [lens]}) do
    assert :ok =
             Client.ingest(self(), %Gralkor.Ingest{
               id: "personal-#{lens}",
               operator_id: "owner",
               lens: lens,
               source_kind: :conversation,
               content: "Eli: Remember teal",
               source_description: "captured"
             })
  end

  defp search,
    do:
      Client.search(self(), %Search{
        operator_id: "owner",
        query: "teal",
        destinations: ["personal"]
      })

  defp recorded(graphiti) do
    {raw, _} =
      Pythonx.eval(
        "[{ 'group_id': item['group_id'], 'source_description': item['source_description'], 'has_entity_types': 'entity_types' in item, 'has_edge_types': 'edge_types' in item } for item in g.recorded]",
        %{"g" => graphiti}
      )

    Pythonx.decode(raw)
  end
end
