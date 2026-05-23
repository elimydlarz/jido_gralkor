defmodule Gralkor.OntologyExtractionTest do
  @moduledoc """
  End-to-end functional test for the ontology DSL. Real Pythonx + real
  graphiti-core + real embedded falkordblite + real LLM. Three scenarios:
  strict ontology, open ontology, no ontology — same fixture episode each
  time, asserting against the actual node/edge labels in the graph via
  raw Cypher.

  Reifies the `ontology-extraction` tree in `TEST_TREES.md`.
  """

  use ExUnit.Case, async: false

  alias Gralkor.Client
  alias Gralkor.Client.Native
  alias Gralkor.Config
  alias Gralkor.GraphitiPool

  @moduletag :functional
  @moduletag timeout: 600_000

  defmodule StrictOntology do
    use Gralkor.Ontology, entities: :strict, relationships: :scoped

    entity User do
      field :handle, :string, required: true, doc: "stable login handle"
    end

    entity Preference do
      field :description, :string, required: true, doc: "what the user prefers"
    end

    from User do
      prefers Preference
    end
  end

  defmodule OpenOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity User do
      field :handle, :string, required: true
    end

    entity Preference do
      field :description, :string, required: true
    end

    from User do
      prefers Preference
    end
  end

  @fixture """
  Important context. Eli (handle: eli) has a strong preference for concise,
  structured responses with minimal preamble. Eli prefers this format
  especially for technical questions. Always respond to Eli in this style.
  """

  setup_all do
    if System.get_env("GOOGLE_API_KEY") in [nil, ""] do
      {:skip, "GOOGLE_API_KEY not set; copy .env.example to .env"}
    else
      data_dir =
        Path.join(System.tmp_dir!(), "gralkor_ontology_#{System.unique_integer([:positive])}")

      File.mkdir_p!(data_dir)
      System.put_env("GRALKOR_DATA_DIR", data_dir)

      {:ok, _python} = start_supervised(Gralkor.Python)

      {:ok, _pool} =
        start_supervised(
          {GraphitiPool,
           [
             falkordb_spec: {:embedded, data_dir},
             llm_model: Config.llm_model(),
             embedder_model: Config.embedder_model(),
             interpret_fn: Native.interpret_callback(),
             warmup: false
           ]}
        )

      on_exit(fn -> File.rm_rf!(data_dir) end)
      :ok
    end
  end

  describe "ontology-extraction > strict ontology" do
    test "every node has a custom label and PREFERS edges exist" do
      group_id = "ontology_strict_#{System.unique_integer([:positive])}"

      :ok = Client.impl().memory_add(group_id, @fixture, "fixture", StrictOntology)

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

  describe "ontology-extraction > open ontology" do
    test "User and Preference nodes still appear; generic-only nodes are not asserted against" do
      group_id = "ontology_open_#{System.unique_integer([:positive])}"

      :ok = Client.impl().memory_add(group_id, @fixture, "fixture", OpenOntology)

      node_labels = node_labels(group_id)

      assert Enum.any?(node_labels, fn labels -> "User" in labels end),
             "expected at least one node with the User label; got node labels: #{inspect(node_labels)}"

      assert Enum.any?(node_labels, fn labels -> "Preference" in labels end),
             "expected at least one node with the Preference label; got node labels: #{inspect(node_labels)}"
    end
  end

  describe "ontology-extraction > no ontology" do
    test "nodes are generic Entity, no User or Preference labels" do
      group_id = "ontology_none_#{System.unique_integer([:positive])}"

      :ok = Client.impl().memory_add(group_id, @fixture, "fixture", nil)

      node_labels = node_labels(group_id)

      refute Enum.any?(node_labels, fn labels -> "User" in labels end),
             "expected no User-labelled nodes when no ontology is configured; got: #{inspect(node_labels)}"

      refute Enum.any?(node_labels, fn labels -> "Preference" in labels end),
             "expected no Preference-labelled nodes when no ontology is configured; got: #{inspect(node_labels)}"

      assert Enum.any?(node_labels, fn labels -> "Entity" in labels end),
             "expected at least one generic Entity node; got: #{inspect(node_labels)}"
    end
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
            g.driver.execute_query("MATCH ()-[r]->() RETURN type(r) AS type")
        )
        [r['type'] for r in records]
        """,
        %{"g" => instance}
      )

    raw
    |> Pythonx.decode()
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end
end
