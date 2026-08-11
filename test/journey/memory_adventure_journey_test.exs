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

    Application.put_env(:jido_gralkor, :destinations, [
      [name: "work", address: "operator/work"],
      [name: "published", address: "global/published"]
    ])

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "work-notes",
        destination: "work",
        ingestion: Gralkor.Lens.Ingestion.Store
      ],
      [
        name: "systems",
        destination: "work",
        write: :replace_graph,
        graph_format: :property_graph
      ],
      [
        name: "published",
        destination: "published",
        ingestion: Gralkor.Lens.Ingestion.Store
      ]
    ])

    Application.put_env(:jido_gralkor, :reflections, [
      [
        name: "erl",
        chain_of_thought: "priv/reflections/erl.yaml",
        destination: "experiential-learning"
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
           interpret_fn: Native.interpret_callback(),
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

    :ok
  end

  test "when two operators complete one production-like memory adventure / while implicit operator memory has no consumer ontology configuration / and explicit memory is added through the implicit operator Lens / and a completed turn is captured through an appending Lens and flushed / and ERL saves its Learning artefact / and operator-local and global information are saved through named Lenses / and an appending Lens and a replaceable Lens save to one shared Destination / and the replaceable Lens replaces its earlier graph / and fresh sessions search and recall from the adventure's Destinations / then the first operator sees implicit, appended, global, ERL, preserved, and current replacement information without the superseded replacement while the second operator sees only global information" do
                      implicit_fact =
                        "The private deployment codename is Juniper and the launch city is Muscat."

                      appended_fact =
                        "The backup and vacuum jobs overlapped at 02:00; moving vacuum to 04:00 fixed the backups."

                      global_fact =
                        "All operators should verify the rollback checkpoint before deployment."

                      assert :ok = Native.memory_add(@operator_one, implicit_fact, "manual")

                      session_id = "memory_adventure_#{System.unique_integer([:positive])}"

                      assert :ok =
                               Native.capture(
                                 session_id,
                                 @operator_one,
                                 "Susu",
                                 "Eli",
                                 [
                                   Message.new(
                                     "user",
                                     "The nightly backup keeps failing with a lock timeout."
                                   ),
                                   Message.new(
                                     "behaviour",
                                     "thought: the backup and vacuum jobs overlap at 02:00"
                                   ),
                                   Message.new(
                                     "assistant",
                                     appended_fact
                                   )
                                 ],
                                 "work-notes",
                                 [],
                                 %{tools: [], tool_context: %{session_id: session_id}}
                               )

                      assert :ok = Native.flush_and_await(session_id, 90_000)

                      assert :ok =
                               Client.ingest(%Ingest{
                                 operator_id: @operator_one,
                                 lens: "published",
                                 content: global_fact,
                                 source_description: "deployment policy"
                               })

                      assert :ok = Client.replace(replacement("Ledger", "old"))
                      assert :ok = Client.replace(replacement("Clearing", "current"))

                      assert {:ok, implicit_memory} =
                               Native.recall(
                                 @operator_one,
                                 "Susu",
                                 "fresh_recall_#{System.unique_integer([:positive])}",
                                 "What is the private deployment codename and launch city?"
                               )

                      shared_episodes =
                        search_until(
                          @operator_one,
                          ["work"],
                          :episodes,
                          "backup vacuum 02:00 04:00",
                          &(&1 != [])
                        )

                      global_for_first =
                        search_until(
                          @operator_one,
                          ["published"],
                          :episodes,
                          "rollback checkpoint deployment",
                          &(&1 != [])
                        )

                      global_for_second =
                        search_until(
                          @operator_two,
                          ["published"],
                          :episodes,
                          "rollback checkpoint deployment",
                          &(&1 != [])
                        )

                      local_for_second =
                        search(@operator_two, ["work"], :episodes, "backup vacuum")

                      erl_artefacts =
                        search_until(
                          @operator_one,
                          ["experiential-learning"],
                          :artefacts,
                          "backup vacuum scheduling conflict",
                          &(&1 != []),
                          120
                        )

                      current_graph =
                        search_until(
                          @operator_one,
                          ["work"],
                          :facts,
                          "settlement clearing",
                          &contains_fact?(&1, "Clearing")
                        )

                      superseded_graph =
                        search(@operator_one, ["work"], :facts, "settlement ledger")

                      final_memory_view = %{
                        implicit_memory: contains_all?(implicit_memory, ["juniper", "muscat"]),
                        appended_information: contains_episode?(shared_episodes, "backup"),
                        global_information: contains_episode?(global_for_first, "rollback"),
                        erl_learning: learning_artefact?(erl_artefacts),
                        preserved_shared_information:
                          contains_episode?(shared_episodes, "vacuum"),
                        current_replacement: contains_fact?(current_graph, "Clearing"),
                        superseded_replacement: contains_fact?(superseded_graph, "Ledger"),
                        second_operator_local_information:
                          contains_episode?(local_for_second, "backup"),
                        second_operator_global_information:
                          contains_episode?(global_for_second, "rollback")
                      }

                      assert final_memory_view == %{
                               implicit_memory: true,
                               appended_information: true,
                               global_information: true,
                               erl_learning: true,
                               preserved_shared_information: true,
                               current_replacement: true,
                               superseded_replacement: false,
                               second_operator_local_information: false,
                               second_operator_global_information: true
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
                group_id: @operator_one,
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
        group_id: @operator_one,
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
