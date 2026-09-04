defmodule JidoGralkor.Actions.MemoryAdd do
  @moduledoc """
  ReAct tool the LLM can call to store a thought or decision in memory.

  Conversations are already captured automatically via the capture hook
  in `JidoGralkor.Plugin`; this tool is for higher-level insights the
  agent wants to preserve explicitly.

  Fire-and-forget: the in-process Gralkor write is spawned in a background
  `Task` and the action returns immediately. The write invokes Graphiti's
  entity/edge extraction (LLM + graph update),
  which takes tens of seconds — far longer than the agent should wait
  before replying. Failures are logged; best-effort storage is the
  contract. Jido does not have native async tool calls.
  """

  use Jido.Action,
    name: "memory_add",
    description:
      "Store a thought, insight, reflection, or decision in long-term memory. " <>
        "Conversations are already captured automatically — use this for higher-level " <>
        "reasoning and conclusions you want to preserve.",
    schema: [
      content: [type: :string, required: true, doc: "The information to store"],
      source_kind: [
        type: {:in, [:conversation, :document, :structured_record]},
        required: true,
        doc: "Whether the information came from a conversation, document, or structured record"
      ],
      source_description: [type: :string, required: true, doc: "Where this came from"]
    ]

  require Logger
  alias Gralkor.Client
  alias Gralkor.Ingest

  @impl true
  def run(params, context) do
    operator_id = Map.fetch!(context, :agent_id)

    Task.start(fn ->
      result =
        case Map.get(context, :lens) do
          lens when is_binary(lens) ->
            request = %Ingest{
              id: "memory-add:#{System.unique_integer([:positive, :monotonic])}",
              operator_id: operator_id,
              lens: lens,
              source_kind: params.source_kind,
              content: params.content,
              source_description: params.source_description
            }

            case Map.get(context, :gralkor_runtime) do
              nil -> Client.ingest(request)
              runtime_owner -> Client.ingest(runtime_owner, request)
            end

          _ ->
            group_id = Client.operator_graph_id(operator_id)

            Client.impl().memory_add(
              group_id,
              params.content,
              params.source_description,
              params.source_kind
            )
        end

      case result do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("[gralkor] memory_add failed: #{inspect(reason)}")
      end
    end)

    {:ok, %{result: "Ingesting."}}
  end
end
