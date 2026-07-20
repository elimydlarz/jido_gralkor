defmodule JidoGralkor.LensAwareAgentMemoryFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client.InMemory
  alias JidoGralkor.Plugin

  defmodule MemoryOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Memory do
      field(:content, :string, required: true)
    end
  end

  defmodule StoreIngestion do
    @behaviour Gralkor.Lens.Ingestion

    @impl true
    def ingest(request, store) do
      Gralkor.Lens.Store.add(store, request.content, request.source_description)
    end
  end

  setup do
    previous_client = Application.get_env(:jido_gralkor, :client)
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)

    Application.put_env(:jido_gralkor, :client, InMemory)

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "observations",
        ontology: MemoryOntology,
        scope: :operator,
        ingestion: StoreIngestion
      ],
      [
        name: "decisions",
        ontology: MemoryOntology,
        scope: :operator,
        ingestion: StoreIngestion
      ]
    ])

    InMemory.reset()
    InMemory.set_capture(:ok)

    on_exit(fn ->
      restore_env(:client, previous_client)
      restore_env(:lenses, previous_lenses)
    end)

    :ok
  end

  describe "where an agent turn selects another registered Lens" do
    test "when the matching request completes without repeating its Lens, then automatic capture uses the retained request Lens rather than the plugin default" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations",
                 search_targets: ["observations"]
               )

      request_id = "decision-request"

      query_signal = %Jido.Signal{
        id: "query-signal",
        source: "/functional",
        type: "ai.react.query",
        data: %{
          request_id: request_id,
          query: "Record a decision",
          tool_context: %{lens: "decisions"}
        }
      }

      query_agent = %{
        id: "operator-one",
        state: %{__memory__: plugin_state, __thread__: %{id: "session-one"}}
      }

      assert {:ok, {:continue, %{data: %{tool_context: retained_context}}}} =
               Plugin.handle_signal(query_signal, %{agent: query_agent})

      completion_agent = %{
        query_agent
        | state:
            Map.merge(query_agent.state, %{
              __strategy__: %{
                run_tool_context: retained_context,
                request_traces: %{
                  request_id => %{events: [%{kind: :llm_completed, data: %{}}]}
                }
              },
              requests: %{
                request_id => %{query: "Record a decision", status: :pending, result: nil}
              },
              user_name: "Eli"
            })
      }

      completion_signal = %Jido.Signal{
        id: "completion-signal",
        source: "/functional",
        type: "ai.request.completed",
        data: %{request_id: request_id, result: "We chose Friday."}
      }

      assert {:ok, :continue} =
               Plugin.handle_signal(completion_signal, %{agent: completion_agent})

      assert [["session-one", "operator-one", "Susu", "Eli", _messages, "decisions"]] =
               InMemory.captures()
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
