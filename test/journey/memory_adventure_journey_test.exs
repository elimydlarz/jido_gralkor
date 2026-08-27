defmodule Gralkor.MemoryAdventureJourneyTest do
  @moduledoc """
  One production-like memory adventure through the real PythonX, Graphiti, and
  embedded FalkorDB runtime.

  Reifies the `memory-adventure` Journey tree.
  """

  use ExUnit.Case, async: false

  alias Gralkor.Application, as: GralkorApplication
  alias Gralkor.CaptureBuffer
  alias Gralkor.Client
  alias Gralkor.Client.Native
  alias Gralkor.Graph
  alias Gralkor.GraphitiPool
  alias Gralkor.Ingest
  alias Gralkor.Message
  alias Gralkor.Reflection.Registry
  alias Gralkor.Replace
  alias Gralkor.Search

  @moduletag :journey
  @moduletag timeout: 600_000

  @operator_one "memory_adventure_operator_one"
  @operator_two "memory_adventure_operator_two"

  defmodule JourneyOntology do
    use Gralkor.Ontology, entities: :open, relationships: :scoped

    entity Job, "A scheduled background job such as backup or vacuum." do
    end

    entity Deployment, "A software deployment governed by an operational policy." do
    end

    entity Checkpoint, "A checkpoint that a deployment must verify." do
    end

    entity System, "A software system participating in a dependency." do
    end

    from Job do
      overlaps(Job)
    end

    from Deployment do
      requires(Checkpoint)
    end

    from System do
      depends_on(System)
    end
  end

  setup_all do
    keys = [
      :client,
      :destinations,
      :destination_storage,
      :lenses,
      :lens_storage,
      :recall_deadline_ms,
      :reflections,
      :reflection_storage
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:jido_gralkor, &1)})
    previous_data_dir = System.get_env("GRALKOR_DATA_DIR")

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "gralkor_memory_adventure_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(data_dir)
    System.put_env("GRALKOR_DATA_DIR", data_dir)

    Application.put_env(:jido_gralkor, :client, Native)
    Application.put_env(:jido_gralkor, :destination_storage, Gralkor.Destination.Storage.Graphiti)
    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.Graphiti)
    Application.put_env(:jido_gralkor, :reflection_storage, Gralkor.Reflection.Storage.Graphiti)
    Application.put_env(:jido_gralkor, :recall_deadline_ms, 90_000)

    Application.put_env(:jido_gralkor, :destinations, [])

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "work-notes",
        destination: "operator",
        ontology: JourneyOntology,
        ingestion: Gralkor.Lens.Ingestion.Store
      ],
      [
        name: "systems",
        destination: "operator",
        write: :replace_graph,
        graph_format: :property_graph
      ],
      [
        name: "published",
        destination: "global",
        ontology: JourneyOntology,
        ingestion: Gralkor.Lens.Ingestion.Store
      ]
    ])

    Application.put_env(:jido_gralkor, :reflections, [
      [
        name: "erl",
        chain_of_thought: "priv/reflections/erl.yaml",
        destination: "operator",
        ontology: Gralkor.Reflection.ERLOntology
      ]
    ])

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

    {:ok, _buffer} =
      start_supervised(
        {CaptureBuffer,
         [
           flush_callback: GralkorApplication.build_flush_callback({:embedded, data_dir}),
           lens_flush_callback: GralkorApplication.build_lens_flush_callback(),
           reflections: Registry.configured!()
         ]}
      )

    on_exit(fn ->
      File.rm_rf!(data_dir)

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:jido_gralkor, key)
        {key, value} -> Application.put_env(:jido_gralkor, key, value)
      end)

      case previous_data_dir do
        nil -> System.delete_env("GRALKOR_DATA_DIR")
        value -> System.put_env("GRALKOR_DATA_DIR", value)
      end
    end)

    {:ok, adventure: run_adventure()}
  end

  describe "when two operators use implicit memory, Lenses, ERL, and shared-Destination replacement" do
    test "then ontology-free implicit operator memory remains recallable", %{adventure: adventure} do
      assert adventure.implicit_memory
    end

    test "and captured appending-Lens information remains searchable", %{adventure: adventure} do
      assert adventure.appended_information
    end

    test "and ERL stores a structured Learning artefact", %{adventure: adventure} do
      assert adventure.erl_learning
    end

    test "and the global graph is visible to both operators", %{adventure: adventure} do
      assert adventure.global_for_first_operator
      assert adventure.global_for_second_operator
    end

    test "and one operator's operator graph is unavailable to another operator", %{
      adventure: adventure
    } do
      refute adventure.second_operator_local_information
    end

    test "and appending and replaceable Lenses use the same operator graph", %{
      adventure: adventure
    } do
      assert adventure.shared_operator_destination
    end

    test "and replacing one Lens's graph preserves information written by another Lens", %{
      adventure: adventure
    } do
      assert adventure.preserved_shared_information
    end

    test "and fresh retrieval returns the current replacement graph", %{adventure: adventure} do
      assert adventure.current_replacement
    end

    test "and fresh retrieval omits the superseded replacement graph", %{adventure: adventure} do
      refute adventure.superseded_replacement
    end
  end

  describe "when the Journey ingests conversation, document, and structured-record episodes" do
    test "then retrieved facts identify every originating episode by identifier, source kind, and source description",
         %{adventure: adventure} do
      assert adventure.conversation_provenance
      assert adventure.document_provenance
      assert adventure.structured_record_provenance
    end
  end

  defp run_adventure do
    implicit_fact =
      "The private deployment codename is Juniper and the launch city is Muscat."

    appended_fact =
      "The Backup job overlaps the Vacuum job at 02:00. Moving the Vacuum job to 04:00 prevents the Backup job from failing."

    global_fact =
      "The Atlas Deployment requires the Rollback Checkpoint before the Atlas release."

    structured_fact = %{
      "source_system" => "Payments",
      "relationship" => "depends_on",
      "target_system" => "Ledger",
      "statement" => "Payments depends on Ledger for settlement records."
    }

    :ok = Native.memory_add(@operator_one, implicit_fact, "manual")

    session_id = "memory_adventure_#{System.unique_integer([:positive])}"

    :ok =
      Native.capture(
        session_id,
        @operator_one,
        "Susu",
        "Eli",
        [
          Message.new("user", "The nightly Backup job conflicts with the Vacuum job."),
          Message.new("behaviour", "thought: both jobs overlap at 02:00"),
          Message.new("assistant", appended_fact)
        ],
        "work-notes",
        [],
        %{tools: [], tool_context: %{session_id: session_id}}
      )

    :ok = Native.flush_and_await(session_id, 90_000)

    :ok =
      Client.ingest(%Ingest{
        operator_id: @operator_one,
        lens: "published",
        source_kind: :document,
        content: global_fact,
        source_description: "deployment policy"
      })

    :ok =
      Client.ingest(%Ingest{
        operator_id: @operator_one,
        lens: "work-notes",
        source_kind: :structured_record,
        content: structured_fact,
        source_description: "system dependency registry"
      })

    :ok = Client.replace(replacement("Ledger", "old"))
    :ok = Client.replace(replacement("Clearing", "current"))

    {:ok, implicit_memory} =
      Native.recall(
        @operator_one,
        "Susu",
        "fresh_recall_#{System.unique_integer([:positive])}",
        "What is the private deployment codename and launch city?"
      )

    shared_episodes =
      search_until(
        @operator_one,
        ["operator"],
        :episodes,
        "backup vacuum 02:00 04:00",
        &(&1 != [])
      )

    global_for_first =
      search_until(
        @operator_one,
        ["global"],
        :episodes,
        "Atlas Deployment requires Rollback Checkpoint",
        &(&1 != [])
      )

    global_for_second =
      search_until(
        @operator_two,
        ["global"],
        :episodes,
        "Atlas Deployment requires Rollback Checkpoint",
        &(&1 != [])
      )

    local_for_second = search(@operator_two, ["operator"], :episodes, "backup vacuum")

    erl_artefacts =
      search_until(
        @operator_one,
        ["operator"],
        :artefacts,
        "backup vacuum scheduling conflict",
        &(&1 != []),
        120
      )

    current_graph =
      search_until(
        @operator_one,
        ["operator"],
        :facts,
        "settlement clearing",
        &contains_fact?(&1, "Clearing")
      )

    superseded_graph = search(@operator_one, ["operator"], :facts, "settlement ledger")

    conversation_facts =
      attributed_facts(
        @operator_one,
        "operator",
        "backup vacuum overlap",
        "conversation",
        "captured"
      )

    document_facts =
      attributed_facts(
        @operator_two,
        "global",
        "Atlas Deployment requires Rollback Checkpoint",
        "document",
        "deployment policy"
      )

    structured_record_facts =
      attributed_facts(
        @operator_one,
        "operator",
        "payments ledger dependency",
        "structured_record",
        "system dependency registry"
      )

    %{
      implicit_memory: contains_all?(implicit_memory, ["juniper", "muscat"]),
      appended_information: contains_episode?(shared_episodes, "backup"),
      erl_learning: learning_artefact?(erl_artefacts),
      global_for_first_operator: contains_episode?(global_for_first, "rollback"),
      global_for_second_operator: contains_episode?(global_for_second, "rollback"),
      second_operator_local_information: contains_episode?(local_for_second, "backup"),
      shared_operator_destination:
        Client.lens!("work-notes").destination == Client.lens!("systems").destination,
      preserved_shared_information: contains_episode?(shared_episodes, "vacuum"),
      current_replacement: contains_fact?(current_graph, "Clearing"),
      superseded_replacement: contains_fact?(superseded_graph, "Ledger"),
      conversation_provenance:
        contains_attributed_fact?(conversation_facts, "conversation", "captured"),
      document_provenance:
        contains_attributed_fact?(document_facts, "document", "deployment policy"),
      structured_record_provenance:
        contains_attributed_fact?(
          structured_record_facts,
          "structured_record",
          "system dependency registry"
        )
    }
  end

  defp replacement(target, suffix) do
    %Replace{
      operator_id: @operator_one,
      lens: "systems",
      graph: %Graph{
        format: :property_graph,
        data: %{
          nodes: [
            replacement_entity("payments-#{suffix}", "Payments"),
            replacement_entity("target-#{suffix}", target)
          ],
          relationships: [
            %{
              from: "payments-#{suffix}",
              to: "target-#{suffix}",
              type: "RELATES_TO",
              properties: %{
                uuid: "memory-adventure-settlement-#{suffix}",
                group_id: "operator/#{@operator_one}",
                name: "SETTLES_THROUGH",
                fact: "Payments settles through #{target}.",
                episodes: [],
                created_at: "2026-08-11T00:00:00Z"
              }
            }
          ]
        }
      }
    }
  end

  defp replacement_entity(id, name) do
    %{
      id: id,
      labels: ["Entity"],
      properties: %{
        uuid: "memory-adventure-#{id}",
        group_id: "operator/#{@operator_one}",
        name: name,
        summary: name,
        created_at: "2026-08-11T00:00:00Z"
      }
    }
  end

  defp search(operator_id, destinations, result_type, query) do
    assert {:ok, results} =
             Client.search(%Search{
               operator_id: operator_id,
               query: query,
               destinations: destinations,
               result_type: result_type,
               max_results: 20
             })

    results
  end

  defp search_until(operator_id, destinations, result_type, query, predicate, attempts \\ 60)

  defp search_until(operator_id, destinations, result_type, query, predicate, attempts) do
    results = search(operator_id, destinations, result_type, query)

    cond do
      predicate.(results) ->
        results

      attempts <= 1 ->
        results

      true ->
        Process.sleep(1_000)
        search_until(operator_id, destinations, result_type, query, predicate, attempts - 1)
    end
  end

  defp contains_episode?(results, text) do
    sought = String.downcase(text)

    Enum.any?(results, fn %{episode: episode} ->
      episode
      |> episode_content()
      |> String.downcase()
      |> String.contains?(sought)
    end)
  end

  defp episode_content(%{content: content}), do: content
  defp episode_content(%{"content" => content}), do: content
  defp episode_content(content) when is_binary(content), do: content

  defp contains_fact?(results, text) do
    Enum.any?(results, fn %{fact: fact} -> String.contains?(fact, text) end)
  end

  defp attributed_facts(operator_id, destination, query, source_kind, source_description) do
    search_until(
      operator_id,
      [destination],
      :facts,
      query,
      &contains_attributed_fact?(&1, source_kind, source_description),
      10
    )
  end

  defp contains_attributed_fact?(results, source_kind, source_description) do
    Enum.any?(results, fn %{fact: fact} ->
      String.contains?(fact, "source: #{source_kind} —") and
        String.contains?(fact, source_description) and
        Regex.match?(~r/episode: [^)]+\)/, fact)
    end)
  end

  defp contains_all?(text, expected) do
    text = String.downcase(text)
    Enum.all?(expected, &String.contains?(text, &1))
  end

  defp learning_artefact?(results) do
    Enum.any?(results, fn
      %{artefact: %{reflection: "erl", payload: payload, evidence_ids: evidence_ids}} ->
        is_binary(payload["problem_kind"]) and
          is_binary(payload["approach"]) and
          is_boolean(payload["success"]) and
          is_binary(payload["lesson"]) and evidence_ids != []

      _ ->
        false
    end)
  end
end
