defmodule Gralkor.ApplicationLensWorkflowJourneyTest do
  use ExUnit.Case, async: false

  @moduletag :journey

  alias Gralkor.Client
  alias Gralkor.Ingest
  alias Gralkor.Search
  alias JidoGralkor.Actions.MemoryAdd
  alias JidoGralkor.Actions.MemorySearch
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
    keys = [
      :client,
      :lenses,
      :lens_storage,
      :generalise_hypothesise_fn,
      :generalise_min_confidence
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:jido_gralkor, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:jido_gralkor, key)
        {key, value} -> Application.put_env(:jido_gralkor, key, value)
      end)
    end)

    start_supervised!(Gralkor.Lens.Storage.InMemory)
    Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)
    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

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
      ],
      [
        name: "generalisations",
        ontology: MemoryOntology,
        scope: :global,
        ingestion: Gralkor.Lens.Ingestion.Generalise
      ]
    ])

    Application.put_env(:jido_gralkor, :generalise_hypothesise_fn, fn _prompt ->
      {:ok, [%{content: "Eli consistently prefers Friday launches.", confidence: 0.9}]}
    end)

    Application.put_env(:jido_gralkor, :generalise_min_confidence, 0.3)

    start_supervised!(
      {Gralkor.CaptureBuffer,
       flush_callback: fn _, _, _, _, _ -> :ok end,
       lens_flush_callback: Gralkor.Application.build_lens_flush_callback(),
       retries: []}
    )

    :ok
  end

  describe "when an application registers operator-local observation and decision Lenses and a global generalisation Lens" do
    test "then direct consumers and the mounted memory plugin use the same application-owned Lens definitions" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations",
                 search_lenses: ["observations", "decisions", "global"],
                 generalise_lens: "generalisations"
               )

      assert plugin_state.lens == Client.lens!("observations")

      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "observations",
                 content: "The launch window moved to Friday.",
                 source_description: "project update"
               })

      assert {:ok, observation_results} = search("operator-one", ["observations"])
      assert "The launch window moved to Friday." in observation_results

      assert {:ok, []} = search("operator-two", ["observations"])
      assert {:ok, []} = search("operator-one", [])

      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "default",
                 content: "The default launch memory.",
                 source_description: "legacy memory"
               })

      base_agent = %{
        id: "operator-one",
        state: %{
          __memory__: plugin_state,
          __thread__: %{id: "session-one"},
          user_name: "Eli"
        }
      }

      request_id = "request-one"

      decision_signal = %Jido.Signal{
        id: "decision-signal",
        source: "/journey",
        type: "ai.react.query",
        data: %{
          request_id: request_id,
          query: "Record a decision",
          tool_context: %{lens: "decisions"}
        }
      }

      assert {:ok,
              {:continue, %{data: %{tool_context: decision_context, extra_refs: decision_refs}}}} =
               Plugin.handle_signal(decision_signal, %{agent: base_agent})

      assert {:ok, %{result: "Ingesting."}} =
               MemoryAdd.run(
                 %{content: "We chose Friday.", source_description: "agent decision"},
                 Map.put(decision_context, :agent_id, base_agent.id)
               )

      assert eventually(fn ->
               {:ok, results} = search("operator-one", ["decisions"])
               "We chose Friday." in results
             end)

      assert {:ok, observation_results} = search("operator-one", ["observations"])
      refute "We chose Friday." in observation_results

      capture_agent = %{
        base_agent
        | state:
            Map.put(base_agent.state, :__strategy__, %{
              request_traces: %{request_id => %{events: [%{kind: :llm_completed, data: %{}}]}},
              requests: %{
                request_id => %{
                  query: "Let's launch Friday.",
                  status: :pending,
                  result: nil
                }
              }
            })
            |> Map.put(:__thread__, %{
              id: "session-one",
              entries: [
                %{
                  kind: :ai_message,
                  payload: %{role: :user},
                  refs: Map.put(decision_refs, :request_id, request_id)
                }
              ]
            })
      }

      completion_signal = %Jido.Signal{
        id: "completion-signal",
        source: "/journey",
        type: "ai.request.completed",
        data: %{request_id: request_id, result: "Agreed."}
      }

      assert {:ok, :continue} =
               Plugin.handle_signal(completion_signal, %{agent: capture_agent})

      assert :ok = Gralkor.Client.Native.flush_and_await("session-one", 1_000)

      assert Enum.any?(
               Gralkor.Lens.Storage.InMemory.episodes(:global),
               &(&1.lens == "generalisations" and
                   String.contains?(&1.content, "Friday launches"))
             )

      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-two",
                 lens: "observations",
                 content: "Another operator's local launch memory.",
                 source_description: "journey"
               })

      assert {:ok, {:continue, %{data: %{tool_context: search_context}}}} =
               Plugin.handle_signal(
                 %Jido.Signal{
                   id: "search-signal",
                   source: "/journey",
                   type: "ai.react.query",
                   data: %{query: "What do you remember?"}
                 },
                 %{agent: base_agent}
               )

      assert {:ok, %{result: result}} =
               MemorySearch.run(
                 %{query: "Friday launch"},
                 Map.put(search_context, :agent_id, base_agent.id)
               )

      assert result =~ "The default launch memory."
      assert result =~ "The launch window moved to Friday."
      assert result =~ "We chose Friday."
      assert result =~ "Eli consistently prefers Friday launches."
      refute result =~ "Another operator's local launch memory."

      assert {:ok, operator_one_results} =
               search("operator-one", ["observations", "decisions", "global"])

      refute "Another operator's local launch memory." in operator_one_results
    end
  end

  describe "if the application selects an unknown Lens or invalid search target" do
    test "then the operation fails before memory is ingested or searched" do
      assert_raise ArgumentError, ~r/unknown Lens "missing"/, fn ->
        Client.ingest(%Ingest{
          operator_id: "operator-one",
          lens: "missing",
          content: "must not land",
          source_description: "journey"
        })
      end

      assert Gralkor.Lens.Storage.InMemory.episodes({"operator-one", "missing"}) == []

      assert_raise ArgumentError, ~r/unknown Lens "missing"/, fn ->
        Plugin.mount(%{},
          agent_name: "Susu",
          default_lens: "observations",
          search_lenses: ["missing"]
        )
      end

      assert Gralkor.Lens.Storage.InMemory.episodes({"operator-one", "observations"}) == []
    end
  end

  defp search(operator_id, targets) do
    Client.search(%Search{
      operator_id: operator_id,
      query: "launch",
      targets: targets
    })
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
