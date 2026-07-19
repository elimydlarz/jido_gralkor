defmodule Gralkor.LensWorkflowFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

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
      :generalise_evaluate_fn
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
      {:ok, [%{content: "Eli prefers Friday launches.", confidence: 0.9}]}
    end)

    Application.put_env(:jido_gralkor, :generalise_evaluate_fn, fn _prompt ->
      {:ok,
       [
         %{
           action: "save",
           hypothesis_index: 0,
           confidence: 0.9,
           content: "Eli prefers Friday launches."
         }
       ]}
    end)

    start_supervised!(
      {Gralkor.CaptureBuffer,
       flush_callback: fn _, _, _, _, _ -> :ok end,
       lens_flush_callback: Gralkor.Application.build_lens_flush_callback(),
       retries: []}
    )

    :ok
  end

  describe "given a consumer registers local, global, and generalising Lenses and mounts the plugin with defaults" do
    test "then tools, capture, and search obey the configured Lens workflow" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations",
                 search_targets: ["observations", "global"],
                 generalise_lens: "generalisations"
               )

      query_signal = %Jido.Signal{
        id: "query-signal",
        source: "/functional",
        type: "ai.react.query",
        data: %{query: "What do you remember?"}
      }

      base_agent = %{
        id: "operator-one",
        state: %{__memory__: plugin_state, __thread__: %{id: "session-one"}}
      }

      assert {:ok, {:continue, %{data: %{tool_context: default_context}}}} =
               Plugin.handle_signal(query_signal, %{agent: base_agent})

      assert {:ok, %{result: "Ingesting."}} =
               MemoryAdd.run(
                 %{content: "The launch moved.", source_description: "agent thought"},
                 Map.put(default_context, :agent_id, base_agent.id)
               )

      assert eventually(fn ->
               Gralkor.Lens.Storage.InMemory.episodes({"operator-one", "observations"}) != []
             end)

      override_signal = %Jido.Signal{
        id: "override-signal",
        source: "/functional",
        type: "ai.react.query",
        data: %{query: "Record a decision", tool_context: %{lens: "decisions"}}
      }

      assert {:ok, {:continue, %{data: %{tool_context: decision_context}}}} =
               Plugin.handle_signal(override_signal, %{agent: base_agent})

      assert {:ok, %{result: "Ingesting."}} =
               MemoryAdd.run(
                 %{content: "We chose Friday.", source_description: "agent decision"},
                 Map.put(decision_context, :agent_id, base_agent.id)
               )

      assert eventually(fn ->
               Gralkor.Lens.Storage.InMemory.episodes({"operator-one", "decisions"}) != []
             end)

      request_id = "request-one"

      capture_agent = %{
        base_agent
        | state:
            Map.merge(base_agent.state, %{
              __strategy__: %{
                request_traces: %{
                  request_id => %{events: [%{kind: :llm_completed, data: %{}}]}
                }
              },
              requests: %{
                request_id => %{query: "Let's launch Friday.", status: :pending, result: nil}
              },
              user_name: "Eli"
            })
      }

      completion_signal = %Jido.Signal{
        id: "completion-signal",
        source: "/functional",
        type: "ai.request.completed",
        data: %{request_id: request_id, result: "Agreed."}
      }

      assert {:ok, :continue} = Plugin.handle_signal(completion_signal, %{agent: capture_agent})
      assert length(Gralkor.CaptureBuffer.turns_for("session-one")) == 1
      assert :ok = Gralkor.Client.Native.flush_and_await("session-one", 1_000)

      assert {:ok, %{result: result}} =
               MemorySearch.run(
                 %{query: "Friday launch"},
                 Map.put(default_context, :agent_id, base_agent.id)
               )

      assert result =~ "The launch moved."
      assert result =~ "Eli prefers Friday launches."
      refute result =~ "We chose Friday."

      assert {:ok, []} =
               Client.search(%Search{
                 operator_id: "operator-two",
                 query: "launch",
                 targets: ["observations"]
               })

      assert {:ok, global_results} =
               Client.search(%Search{
                 operator_id: "operator-two",
                 query: "launch",
                 targets: ["global"]
               })

      assert Enum.any?(global_results, &String.contains?(&1, "Eli prefers Friday launches."))

      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-two",
                 lens: "observations",
                 content: "Another operator's local memory.",
                 source_description: "functional"
               })

      refute result =~ "Another operator's local memory."
    end
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
