defmodule JidoGralkor.Plugin do
  @moduledoc """
  Jido plugin that replaces `Jido.Memory.BasicPlugin` with Gralkor-backed
  memory. Claims the `:__memory__` slot so it is the only memory plugin
  attached to the agent.

  On `ai.react.query` the plugin plants the current thread's `:session_id`
  and the configured `:agent_name` on the signal's `tool_context`. A
  Lens-aware mount also plants its selected ingestion `:lens`:

    * `:session_id` — the current Jido thread id (read from
      `agent.state[:__thread__].id`). Absent when no thread is
      committed yet (first query of a fresh agent, before the ReAct
      strategy's `ThreadAgent.append` runs inside `@start`). Memory search
      remains available because it is scoped by operator rather than session.
    * `:agent_name` — the value supplied at mount.

  The plugin does **not** search memory on its own. Search is the LLM's job,
  invoked through `MemorySearch`, which calls runtime-targeted
  `Gralkor.Client.search/2` with the optional Destination selector supplied
  for that search invocation.
  Consumers force it on the first ReAct iteration via
  `JidoGralkor.ReAct.maybe_force_memory_search/2` from their
  `Jido.AI.Reasoning.ReAct.RequestTransformer`.

  The plugin captures nothing. A consumer keeps its own chat record and
  remembers it through `Gralkor.Client.ingest/2` with a Lens.
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

  alias JidoGralkor.Runtime
  alias Jido.Signal

  @impl Jido.Plugin
  def child_spec(config) do
    %{
      id: Runtime,
      start:
        {Runtime, :start_link,
         [
           [
             owner: self(),
             configuration:
               fetch_opt(config, :runtime_config) ||
                 %{destinations: [], lenses: [], reflections: []}
           ]
         ]}
    }
  end

  @impl Jido.Plugin
  def mount(_agent, opts) do
    agent_name = fetch_opt(opts, :agent_name)

    runtime_config =
      fetch_opt(opts, :runtime_config) || %{destinations: [], lenses: [], reflections: []}

    unless is_binary(agent_name) and String.trim(agent_name) != "" do
      raise ArgumentError,
            "JidoGralkor.Plugin requires :agent_name (non-blank string), got #{inspect(agent_name)}"
    end

    case Runtime.validate(runtime_config) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError, "invalid Gralkor runtime configuration: #{inspect(reason)}"
    end

    if fetch_opt(opts, :default_lens) != nil do
      raise ArgumentError, ":default_lens was removed; use :ingestion_lens instead"
    end

    if has_opt?(opts, :search_destinations) do
      raise ArgumentError,
            ":search_destinations was removed; use MemorySearch's per-search :destinations selector instead"
    end

    if has_opt?(opts, :capture_destination) do
      raise ArgumentError,
            "capture was removed in 18.0.0, so :capture_destination is no longer accepted; keep your own chat record and remember it with Gralkor.Client.ingest/2 through a Lens such as \"personal-chat\""
    end

    state = %{agent_name: agent_name}

    case fetch_opt(opts, :ingestion_lens) do
      nil ->
        {:ok, state}

      ingestion_lens ->
        validate_mount_lens!(runtime_config, ingestion_lens)
        {:ok, Map.put(state, :ingestion_lens, ingestion_lens)}
    end
  end

  defp validate_mount_lens!(runtime_config, lens_name) do
    if lens_name in ["operator", "default"] do
      raise ArgumentError,
            "Lens #{inspect(lens_name)} was retired; select \"personal-chat\" or omit :ingestion_lens for direct memory_add"
    end

    declared = Map.fetch!(runtime_config, :lenses)
    names = ["personal-chat"] ++ Enum.map(declared, &fetch_opt(&1, :name))

    unless lens_name in names do
      raise ArgumentError, "unknown Lens #{inspect(lens_name)}"
    end
  end

  defp fetch_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp fetch_opt(opts, key) when is_map(opts) do
    case Map.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Map.get(opts, Atom.to_string(key))
    end
  end

  defp fetch_opt(_, _), do: nil

  defp has_opt?(opts, key) when is_list(opts), do: Keyword.has_key?(opts, key)
  defp has_opt?(opts, key) when is_map(opts), do: Map.has_key?(opts, key)
  defp has_opt?(_, _), do: false

  @impl Jido.Plugin
  def handle_signal(%Signal{type: "ai.react.query"} = signal, %{agent: agent} = context) do
    agent_name = agent_name(agent)
    owner = owning_agent_server!(context)

    extras =
      case thread_id(agent) do
        nil -> %{agent_name: agent_name, gralkor_runtime: owner}
        id -> %{session_id: id, agent_name: agent_name, gralkor_runtime: owner}
      end
      |> Map.merge(lens_context(agent))

    {:ok, {:continue, merge_tool_context(signal, extras, owner)}}
  end

  def handle_signal(_signal, _context), do: {:ok, :continue}

  defp agent_name(agent) do
    case plugin_state(agent) do
      %{agent_name: name} when is_binary(name) -> name
      _ -> raise "JidoGralkor.Plugin state missing — mount/2 must run before a query"
    end
  end

  defp lens_context(agent) do
    case plugin_state(agent) do
      %{ingestion_lens: lens} ->
        %{lens: lens}

      _ ->
        %{lens: nil}
    end
  end

  defp plugin_state(agent), do: Map.get(agent.state, :__memory__)

  defp thread_id(agent) do
    case Map.get(agent.state, :__thread__) do
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp owning_agent_server!(context) do
    cond do
      Process.get(:"$initial_call") == {Jido.AgentServer, :init, 1} ->
        self()

      match?(%{jido_instance: instance} when is_atom(instance) and not is_nil(instance), context) ->
        registered_agent_server!(context)

      true ->
        raise ArgumentError,
              "JidoGralkor.Plugin cannot identify its owning Jido.AgentServer: synchronous signal delivery runs plugin hooks outside the AgentServer and requires a Jido instance"
    end
  end

  defp registered_agent_server!(%{agent: agent, jido_instance: jido_instance} = context) do
    case Jido.whereis(jido_instance, agent.id, partition: Map.get(context, :partition)) do
      pid when is_pid(pid) ->
        pid

      nil ->
        raise ArgumentError,
              "JidoGralkor.Plugin cannot identify its owning Jido.AgentServer: agent #{inspect(agent.id)} is not registered in Jido instance #{inspect(jido_instance)}"
    end
  end

  defp merge_tool_context(%Signal{data: data} = signal, extras, owner) when is_map(extras) do
    existing_context = Map.get(data, :tool_context, %{})

    new_context =
      case Map.fetch(existing_context, :lens) do
        {:ok, lens} ->
          runtime_lens!(owner, lens)
          extras |> Map.merge(existing_context) |> Map.merge(extras) |> Map.put(:lens, lens)

        :error ->
          Map.merge(existing_context, extras)
      end

    %{signal | data: Map.put(data, :tool_context, new_context)}
  end

  defp runtime_lens!(_owner, nil), do: :ok

  defp runtime_lens!(owner, lens) when is_binary(lens), do: Runtime.lens!(owner, lens)

  defp runtime_lens!(_owner, lens), do: raise(ArgumentError, "invalid Lens #{inspect(lens)}")
end
