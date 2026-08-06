defmodule Gralkor.GraphitiEpisodeProvenanceTest do
  use ExUnit.Case, async: false

  alias Gralkor.GraphitiPool

  setup_all do
    {:ok, _applications} = Application.ensure_all_started(:pythonx)
    :ok
  end

  describe "when add_episode receives an originating Lens" do
    test "then the source description submitted to Graphiti identifies that Lens" do
      {pid, graphiti} = start_recording_pool()

      assert :ok =
               GraphitiPool.add_episode(
                 pid,
                 "global",
                 "public fact",
                 "publication",
                 nil,
                 lens: "published-observations"
               )

      added = decode(graphiti, "g.added")

      assert added["source_description"] ==
               "publication [lens: published-observations]"

      GenServer.stop(pid)
    end

    test "and no second graph mutation is attempted after Graphiti ingests the episode" do
      {pid, graphiti} = start_recording_pool()

      assert :ok =
               GraphitiPool.add_episode(
                 pid,
                 "global",
                 "public fact",
                 "publication",
                 nil,
                 lens: "published-observations"
               )

      assert decode(graphiti, "g.driver.queries") == []

      GenServer.stop(pid)
    end
  end

  describe "where add_episode has no originating Lens" do
    test "then the original source description is submitted unchanged" do
      {pid, graphiti} = start_recording_pool()

      assert :ok =
               GraphitiPool.add_episode(
                 pid,
                 "operator",
                 "private fact",
                 "conversation",
                 nil
               )

      added = decode(graphiti, "g.added")
      assert added["source_description"] == "conversation"
      assert decode(graphiti, "g.driver.queries") == []

      GenServer.stop(pid)
    end
  end

  defp start_recording_pool do
    {graphiti, _} =
      Pythonx.eval(
        """
        class _Episode:
            uuid = "episode-123"

        class _Result:
            episode = _Episode()

        class _Driver:
            def __init__(self):
                self.queries = []

            async def execute_query(self, query, **kwargs):
                self.queries.append({"query": query, "kwargs": kwargs})
                return [], None, None

        class _Graphiti:
            def __init__(self):
                self.driver = _Driver()
                self.added = None

            async def add_episode(self, **kwargs):
                self.added = kwargs
                return _Result()

        _Graphiti()
        """,
        %{}
      )

    table = :"provenance_pool_#{System.unique_integer([:positive])}"

    opts = [
      name: nil,
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
    ]

    {:ok, pid} = GraphitiPool.start_link(opts)
    {pid, graphiti}
  end

  defp decode(graphiti, expression) do
    {value, _} = Pythonx.eval(expression, %{"g" => graphiti})
    Pythonx.decode(value)
  end
end
