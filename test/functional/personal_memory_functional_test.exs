defmodule Gralkor.PersonalMemoryFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Search

  setup do
    keys = [:client, :destination_storage, :lens_storage, :ontology]
    previous = Map.new(keys, &{&1, Application.get_env(:jido_gralkor, &1)})
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
                return SimpleNamespace(episodes=self.episodes[:config.limit])
        PersonalGraphFixture()
        """,
        %{}
      )

    start_supervised!(
      {Gralkor.GraphitiPool,
       construct_falkor_db: fn _ -> :fixture end,
       falkordb_spec: {:embedded, "/tmp/never_used"},
       construct_shared_clients: fn _, _ ->
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
             write: :append,
             ingestion: Gralkor.Lens.Ingestion.Store
           }
         ],
         reflections: []
       }}
    )

    start_supervised!(
      {Gralkor.CaptureBuffer,
       flush_callback: Gralkor.Application.build_flush_callback(nil),
       lens_flush_callback: Gralkor.Application.build_lens_flush_callback(),
       retries: []}
    )

    %{graphiti: graphiti}
  end

  describe "when an application captures directly to the registered personal Destination without selecting a Lens" do
    test "then the graph named `personal/<operator id>` receives the conversation", context do
      capture({:direct, "personal"})
      assert [record] = recorded(context.graphiti)
      assert record["group_id"] == Client.sanitize_group_id("personal/owner")
    end

    test "and jido_gralkor's built-in ontology governs extraction", context do
      capture({:direct, "personal"})
      assert [record] = recorded(context.graphiti)
      assert record["has_entity_types"] == false
    end

    test "and public search returns the conversation without Lens or Reflection authorship" do
      capture({:direct, "personal"})
      assert {:ok, [%{episode: episode}]} = search()
      assert episode.content == "Eli: Remember teal"
      assert episode.source_kind == "conversation"
      assert episode.writer == :direct
      refute Map.has_key?(episode, :lens)
      refute Map.has_key?(episode, :reflection)
    end

    test "and no packaged Lens ingestion process runs", context do
      capture({:direct, "personal"})

      assert [%{"source_description" => "captured [gralkor: direct]"}] =
               recorded(context.graphiti)
    end
  end

  describe "when an application selects the packaged personal-chat Lens" do
    test "then its Store ingestion process writes to that operator's personal Destination",
         context do
      capture({:lenses, ["personal-chat"]})
      assert [%{"group_id" => group}] = recorded(context.graphiti)
      assert group == Client.sanitize_group_id("personal/owner")
    end

    test "and its built-in ontology applies to conversation and other supported source kinds" do
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

      assert JidoGralkor.Runtime.lens!(self(), "personal-chat").ontology ==
               Gralkor.DefaultOntology
    end

    test "and its stored episode identifies personal-chat as the originating Lens" do
      capture({:lenses, ["personal-chat"]})
      assert {:ok, [%{episode: %{lens: "personal-chat"}}]} = search()
    end

    test "and no additional direct capture write occurs", context do
      capture({:lenses, ["personal-chat"]})

      assert [%{"source_description" => "captured [lens: personal-chat]"}] =
               recorded(context.graphiti)
    end
  end

  describe "when direct capture and a genuine consumer Lens target personal memory for the same operator" do
    test "then both routes use the same personal graph", context do
      capture({:direct, "personal"})
      capture({:lenses, ["notes"]})
      assert [first, second] = recorded(context.graphiti)
      assert first["group_id"] == second["group_id"]
    end

    test "and each write retains its actual originating route" do
      capture({:direct, "personal"})
      capture({:lenses, ["notes"]})
      assert {:ok, [%{episode: %{writer: :direct}}, %{episode: %{lens: "notes"}}]} = search()
    end
  end

  describe "if an application selects the retired operator Lens or Destination" do
    test "then the request fails with an explicit migration error before capture or graph access",
         context do
      for route <- [{:direct, "operator"}, {:lenses, ["operator"]}] do
        assert_raise ArgumentError, ~r/retired/, fn -> capture(route) end
      end

      assert recorded(context.graphiti) == []
    end
  end

  describe "if an application retains the removed deployment-wide `:jido_gralkor, :ontology` setting" do
    test "then personal-chat still uses jido_gralkor's built-in ontology" do
      Application.put_env(:jido_gralkor, :ontology, Gralkor.TestOntologies.Strict)

      assert JidoGralkor.Runtime.lens!(self(), "personal-chat").ontology ==
               Gralkor.DefaultOntology
    end
  end

  defp capture(route) do
    assert :ok =
             Client.capture(self(), %Gralkor.Capture{
               session_id: "personal-session",
               operator_id: "owner",
               agent_name: "Susu",
               user_name: "Eli",
               messages: [Gralkor.Message.new("user", "Remember teal")],
               route: route
             })

    Client.impl().flush_and_await("personal-session", 5_000)
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
        "[{ 'group_id': item['group_id'], 'source_description': item['source_description'], 'has_entity_types': 'entity_types' in item } for item in g.recorded]",
        %{"g" => graphiti}
      )

    Pythonx.decode(raw)
  end
end
