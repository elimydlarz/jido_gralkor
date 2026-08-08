defmodule JidoGralkor.Plugin do
  @moduledoc """
  Jido plugin that replaces `Jido.Memory.BasicPlugin` with Gralkor-backed
  memory. Claims the `:__memory__` slot so it is the only memory plugin
  attached to the agent.

  On `ai.react.query` the plugin plants the current thread's `:session_id`
  and the configured `:agent_name` on the signal's `tool_context` so the
  `MemorySearch` ReAct tool can find them. A Lens-aware mount also plants its
  selected `:lens` and `:search_lenses`:

    * `:session_id` — the current Jido thread id (read from
      `agent.state[:__thread__].id`). Absent when no thread is
      committed yet (first query of a fresh agent, before the ReAct
      strategy's `ThreadAgent.append` runs inside `@start`); on that
      turn `MemorySearch` short-circuits with a non-result message.
    * `:agent_name` — the value supplied at mount.

  The plugin does **not** search memory on its own. Search is the LLM's job,
  invoked through `MemorySearch`: Lens-aware mounts call
  `Gralkor.Client.search/1`; implicit-default mounts call the configured
  client's legacy `recall/4`.
  Consumers force it on the first ReAct iteration via
  `JidoGralkor.ReAct.maybe_force_memory_search/2` from their
  `Jido.AI.Reasoning.ReAct.RequestTransformer`.

  Capture fires on `ai.request.completed` / `ai.request.failed`: the
  full request trace and assistant answer are normalised via
  `JidoGralkor.Canonical.to_messages/3` into Gralkor's canonical
  `[%Gralkor.Message{role, content}]` shape and submitted to the configured
  client. Implicit-default capture uses `capture/5`; Lens-aware capture uses
  `capture/6`, or `/7` when an additional generalising Lens is configured.
  The capture buffer keeps turn order by `session_id` and flushes Lens batches
  independently.
  Capture is skipped if the thread isn't present (first-turn failure
  with nothing committed) or if the canonical message list is empty.
  Capture failures raise; retry and backoff belong to the capture buffer, not
  this plugin.
  """

  use Jido.Plugin,
    name: "gralkor",
    state_key: :__memory__,
    singleton: true,
    actions: [
      JidoGralkor.Actions.MemorySearch,
      JidoGralkor.Actions.MemoryAdd,
      JidoGralkor.Actions.MemoryBuildIndices,
      JidoGralkor.Actions.MemoryBuildCommunities
    ],
    description: "Gralkor-backed long-term memory",
    capabilities: [:memory]

  require Logger

  alias Gralkor.Client
  alias JidoGralkor.Canonical
  alias Jido.AI.Request
  alias Jido.Signal

  @no_thread_warning_hint "jido_ai commits state.thread on :request_completed, not at :ai.react.query — see susu JIDO_CHANGE_SUGGESTIONS.md §2"

  @impl Jido.Plugin
  def mount(_agent, opts) do
    agent_name = fetch_opt(opts, :agent_name)

    unless is_binary(agent_name) and String.trim(agent_name) != "" do
      raise ArgumentError,
            "JidoGralkor.Plugin requires :agent_name (non-blank string), got #{inspect(agent_name)}"
    end

    if fetch_opt(opts, :default_lens) != nil do
      raise ArgumentError, ":default_lens was removed; use :ingestion_lens instead"
    end

    case fetch_opt(opts, :ingestion_lens) do
      nil ->
        if fetch_opt(opts, :search_lenses) != nil or fetch_opt(opts, :generalise_lens) != nil do
          raise ArgumentError, ":ingestion_lens is required when Lens options are configured"
        end

        {:ok, %{agent_name: agent_name}}

      ingestion_lens ->
        lens = Client.lens!(ingestion_lens)
        search_lenses = validate_search_lenses!(fetch_opt(opts, :search_lenses))
        generalise_lens = fetch_opt(opts, :generalise_lens)

        if generalise_lens, do: Client.lens!(generalise_lens)

        if generalise_lens == ingestion_lens do
          raise ArgumentError, ":generalise_lens must differ from :ingestion_lens"
        end

        {:ok,
         %{
           agent_name: agent_name,
           ingestion_lens: ingestion_lens,
           search_lenses: search_lenses,
           lens: lens,
           generalise_lens: generalise_lens
         }}
    end
  end

  defp fetch_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp fetch_opt(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp fetch_opt(_, _), do: nil

  defp validate_search_lenses!(nil), do: []

  defp validate_search_lenses!(lenses) when is_list(lenses) do
    Enum.each(lenses, fn
      "global" -> :ok
      name when is_binary(name) -> Client.lens!(name)
      name -> raise ArgumentError, "invalid Lens #{inspect(name)}"
    end)

    lenses
  end

  defp validate_search_lenses!(lenses) do
    raise ArgumentError, "search_lenses must be a list, got #{inspect(lenses)}"
  end

  @impl Jido.Plugin
  def handle_signal(%Signal{type: "ai.react.query"} = signal, %{agent: agent}) do
    agent_name = agent_name(agent)

    extras =
      case thread_id(agent) do
        nil -> %{agent_name: agent_name}
        id -> %{session_id: id, agent_name: agent_name}
      end
      |> Map.merge(lens_context(agent))

    {:ok, {:continue, signal |> merge_tool_context(extras) |> retain_request_lens()}}
  end

  def handle_signal(
        %Signal{
          type: "ai.request.completed",
          data: %{request_id: request_id, result: result}
        },
        %{agent: agent}
      )
      when is_binary(request_id) and is_binary(result) do
    capture_turn(agent, request_id, {:completed, result}, selected_lens(agent, request_id))
    {:ok, :continue}
  end

  def handle_signal(
        %Signal{
          type: "ai.request.failed",
          data: %{request_id: request_id, error: error}
        },
        %{agent: agent}
      )
      when is_binary(request_id) do
    capture_turn(agent, request_id, {:failed, error}, selected_lens(agent, request_id))
    {:ok, :continue}
  end

  def handle_signal(_signal, _context), do: {:ok, :continue}

  defp capture_turn(agent, request_id, outcome, lens) do
    events =
      agent.state
      |> Map.get(:__strategy__, %{})
      |> Map.get(:request_traces, %{})
      |> Map.get(request_id, %{events: []})
      |> Map.get(:events, [])

    session_id = thread_id(agent)

    cond do
      events == [] and match?({:completed, _result}, outcome) ->
        :ok

      is_nil(session_id) ->
        Logger.warning(
          "[jido_gralkor] skipping capture — no thread committed yet for agent #{inspect(agent.id)} (#{@no_thread_warning_hint})"
        )

        :ok

      true ->
        user_query =
          case Request.get_request(agent, request_id) do
            %{query: q} when is_binary(q) -> q
            _ -> ""
          end

        case Canonical.to_messages(user_query, events, outcome) do
          [] ->
            :ok

          messages ->
            user_name = user_name!(agent)

            result =
              case lens do
                nil ->
                  group_id = Client.sanitize_group_id(agent.id)

                  Client.impl().capture(
                    session_id,
                    group_id,
                    agent_name(agent),
                    user_name,
                    messages
                  )

                lens_name ->
                  Client.lens!(lens_name)
                  additional_lenses = additional_lenses(agent, lens_name)

                  case additional_lenses do
                    [] ->
                      Client.impl().capture(
                        session_id,
                        agent.id,
                        agent_name(agent),
                        user_name,
                        messages,
                        lens_name
                      )

                    lenses ->
                      Client.impl().capture(
                        session_id,
                        agent.id,
                        agent_name(agent),
                        user_name,
                        messages,
                        lens_name,
                        lenses
                      )
                  end
              end

            case result do
              :ok -> :ok
              {:error, reason} -> raise "Gralkor capture failed: #{inspect(reason)}"
            end
        end
    end
  end

  defp user_name!(agent) do
    case Map.get(agent.state, :user_name) do
      name when is_binary(name) ->
        if String.trim(name) == "" do
          raise ArgumentError,
                "JidoGralkor.Plugin: agent.state[:user_name] is blank — the consumer must populate it (e.g. from `tool_context[:name]` in `on_before_cmd`) before any turn that captures"
        else
          name
        end

      other ->
        raise ArgumentError,
              "JidoGralkor.Plugin: agent.state[:user_name] missing (got #{inspect(other)}) — the consumer must populate it (e.g. from `tool_context[:name]` in `on_before_cmd`) before any turn that captures"
    end
  end

  defp agent_name(agent) do
    case plugin_state(agent) do
      %{agent_name: name} when is_binary(name) -> name
      _ -> raise "JidoGralkor.Plugin state missing — mount/2 must run before recall/capture"
    end
  end

  defp lens_context(agent) do
    case plugin_state(agent) do
      %{ingestion_lens: lens, search_lenses: lenses} -> %{lens: lens, search_lenses: lenses}
      _ -> %{}
    end
  end

  defp selected_lens(agent, request_id) do
    request_lens(agent, request_id) ||
      case plugin_state(agent) do
        %{ingestion_lens: lens} -> lens
        _ -> nil
      end
  end

  defp request_lens(agent, request_id) do
    agent.state
    |> Map.get(:__thread__, %{})
    |> Map.get(:entries, [])
    |> Enum.find_value(fn
      %{refs: refs} when is_map(refs) ->
        if ref_value(refs, :request_id) == request_id,
          do: ref_value(refs, :jido_gralkor_lens)

      _entry ->
        nil
    end)
  end

  defp ref_value(refs, key), do: Map.get(refs, key) || Map.get(refs, Atom.to_string(key))

  defp additional_lenses(agent, selected_lens) do
    case plugin_state(agent) do
      %{generalise_lens: lens} when is_binary(lens) and lens != selected_lens -> [lens]
      _ -> []
    end
  end

  defp plugin_state(agent), do: Map.get(agent.state, :__memory__)

  defp thread_id(agent) do
    case Map.get(agent.state, :__thread__) do
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp merge_tool_context(%Signal{data: data} = signal, extras) when is_map(extras) do
    existing_context = Map.get(data, :tool_context, %{})

    new_context =
      case Map.fetch(existing_context, :lens) do
        {:ok, lens} ->
          Client.lens!(lens)
          extras |> Map.merge(existing_context) |> Map.merge(extras) |> Map.put(:lens, lens)

        :error ->
          Map.merge(existing_context, extras)
      end

    %{signal | data: Map.put(data, :tool_context, new_context)}
  end

  defp retain_request_lens(%Signal{data: %{tool_context: %{lens: lens}} = data} = signal)
       when is_binary(lens) do
    refs = data |> Map.get(:extra_refs, %{}) |> Map.put(:jido_gralkor_lens, lens)
    %{signal | data: Map.put(data, :extra_refs, refs)}
  end

  defp retain_request_lens(signal), do: signal
end
