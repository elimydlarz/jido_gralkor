defmodule Gralkor.OntologyExtractionTest do
  @moduledoc """
  End-to-end functional test for the ontology DSL. Real Pythonx + real
  graphiti-core + real embedded falkordblite + real LLM. Three scenarios:
  strict ontology, open ontology, no ontology — same fixture episode each
  time, asserting against the actual node/edge labels in the graph via
  raw Cypher.

  Reifies `test-trees/functional/ontology-extraction_TEST_TREES.md`.
  """

  use ExUnit.Case, async: false

  alias Gralkor.Client
  alias Gralkor.GraphitiPool
  alias Gralkor.Ingest

  @moduletag :functional
  @moduletag timeout: 600_000

  defmodule StrictOntology do
    use Gralkor.Ontology, entities: :strict, relationships: :scoped

    entity User,
           "A person the agent talks to. Extract a User for anyone the text names as talking to, instructing, or being helped by the agent." do
      field(:handle, :string, required: true, doc: "stable login handle")
    end

    entity Preference,
           "A way a person prefers things to be done. Extract a Preference for each distinct preference, style, or standing instruction the text records about how someone wants to be treated or answered." do
      field(:description, :string, required: true, doc: "what the user prefers")
    end

    from User do
      prefers(Preference)
    end
  end

  defmodule OpenOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity User,
           "A person the agent talks to. Extract a User for anyone the text names as talking to, instructing, or being helped by the agent." do
      field(:handle, :string, required: true)
    end

    entity Preference,
           "A way a person prefers things to be done. Extract a Preference for each distinct preference, style, or standing instruction the text records about how someone wants to be treated or answered." do
      field(:description, :string, required: true)
    end

    from User do
      prefers(Preference)
    end
  end

  @fixture """
  Important context. Eli (handle: eli) has a strong preference for concise,
  structured responses with minimal preamble. Eli prefers this format
  especially for technical questions. Eli also prefers dark mode in every
  editor, and prefers to be addressed by first name. Always respond to Eli
  in this style.
  """

  setup_all do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "gralkor_ontology_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
      )

    File.mkdir_p!(data_dir)
    System.put_env("GRALKOR_DATA_DIR", data_dir)

    original_client = Application.get_env(:jido_gralkor, :client)
    Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)

    on_exit(fn ->
      case original_client do
        nil -> Application.delete_env(:jido_gralkor, :client)
        mod -> Application.put_env(:jido_gralkor, :client, mod)
      end
    end)

    {:ok, _python} = start_supervised(Gralkor.Python)

    {:ok, _pool} =
      start_supervised(
        {GraphitiPool,
         [
           falkordb_spec: {:embedded, data_dir},
           llm_model: Gralkor.Config.llm_model(),
           embedder_model: Gralkor.Config.embedder_model(),
           warmup: false
         ]}
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)
    :ok
  end

  setup do
    previous_destinations = Application.get_env(:jido_gralkor, :destinations)
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)

    on_exit(fn ->
      if previous_destinations,
        do: Application.put_env(:jido_gralkor, :destinations, previous_destinations),
        else: Application.delete_env(:jido_gralkor, :destinations)

      if previous_lenses,
        do: Application.put_env(:jido_gralkor, :lenses, previous_lenses),
        else: Application.delete_env(:jido_gralkor, :lenses)
    end)

    :ok
  end

  describe "when an episode is ingested through a named Lens with a strict ontology" do
    test "then extraction conforms every node and relationship to the declared ontology" do
      group_id = ingest_through_named_lens("strict", StrictOntology)

      node_labels = node_labels(group_id)
      edge_types = edge_types(group_id)

      assert Enum.any?(node_labels, fn labels -> "User" in labels end),
             "expected at least one node with the User label; got node labels: #{inspect(node_labels)}"

      assert Enum.any?(node_labels, fn labels -> "Preference" in labels end),
             "expected at least one node with the Preference label; got node labels: #{inspect(node_labels)}"

      assert Enum.all?(node_labels, fn labels -> labels -- ["Entity"] != [] end),
             "expected every node to carry at least one label other than Entity (strict mode); got node labels: #{inspect(node_labels)}"

      assert "PREFERS" in edge_types,
             "expected at least one PREFERS edge; got edge types: #{inspect(edge_types)}"
    end
  end

  describe "when an episode is ingested through a named Lens with an open ontology" do
    test "then extraction includes the declared entity types without excluding generic entities" do
      group_id = ingest_through_named_lens("open", OpenOntology)

      node_labels = node_labels(group_id)

      assert Enum.any?(node_labels, fn labels -> "User" in labels end),
             "expected at least one node with the User label; got node labels: #{inspect(node_labels)}"

      assert Enum.any?(node_labels, fn labels -> "Preference" in labels end),
             "expected at least one node with the Preference label; got node labels: #{inspect(node_labels)}"
    end
  end

  describe "when an episode is added through implicit-default memory" do
    test "then extraction preserves generic entities without undeclared custom labels" do
      group_id = "ontology_none_#{System.unique_integer([:positive])}"

      :ok = Client.impl().memory_add(group_id, @fixture, "fixture")

      node_labels = node_labels(group_id)

      refute Enum.any?(node_labels, fn labels -> "User" in labels end),
             "expected no User-labelled nodes when no ontology is configured; got: #{inspect(node_labels)}"

      refute Enum.any?(node_labels, fn labels -> "Preference" in labels end),
             "expected no Preference-labelled nodes when no ontology is configured; got: #{inspect(node_labels)}"

      assert Enum.any?(node_labels, fn labels -> "Entity" in labels end),
             "expected at least one generic Entity node; got: #{inspect(node_labels)}"
    end
  end

  describe "where a named Lens supplies an application-owned ontology that differs from jido_gralkor's built-in ontology" do
    test "then that Lens's extraction is governed by its application-owned ontology alone" do
      group_id = ingest_through_named_lens("application-owned", StrictOntology)

      node_labels = node_labels(group_id)
      assert Enum.any?(node_labels, fn labels -> "User" in labels end)
      assert Enum.any?(node_labels, fn labels -> "Preference" in labels end)
    end
  end

  defp ingest_through_named_lens(lens, ontology) do
    operator_id = "ontology-operator-#{System.unique_integer([:positive])}"

    Application.put_env(:jido_gralkor, :destinations, [
      [name: lens]
    ])

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: lens,
        destination: lens,
        ontology: ontology,
        ingestion: Gralkor.Lens.Ingestion.Store
      ]
    ])

    assert :ok =
             Client.ingest(%Ingest{
               id: "ontology-#{operator_id}-#{lens}",
               operator_id: operator_id,
               lens: lens,
               source_kind: :document,
               content: @fixture,
               source_description: "fixture"
             })

    lens
    |> Gralkor.Destination.Registry.fetch!()
    |> Gralkor.Destination.graph_id(operator_id)
  end

  defp node_labels(group_id) do
    instance = GraphitiPool.for(group_id)

    {raw, _} =
      Pythonx.eval(
        """
        import asyncio
        records, _, _ = asyncio._gralkor_run(
            g.driver.execute_query("MATCH (n) RETURN labels(n) AS labels")
        )
        [r['labels'] for r in records]
        """,
        %{"g" => instance}
      )

    raw
    |> Pythonx.decode()
    |> Enum.map(fn labels -> Enum.map(labels, &to_string/1) end)
  end

  defp edge_types(group_id) do
    instance = GraphitiPool.for(group_id)

    {raw, _} =
      Pythonx.eval(
        """
        import asyncio
        records, _, _ = asyncio._gralkor_run(
            g.driver.execute_query("MATCH ()-[r:RELATES_TO]->() WHERE r.name IS NOT NULL RETURN r.name AS name")
        )
        [r['name'] for r in records]
        """,
        %{"g" => instance}
      )

    raw
    |> Pythonx.decode()
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end
end
