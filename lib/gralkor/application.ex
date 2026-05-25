defmodule Gralkor.Application do
  @moduledoc false

  use Application

  require Logger

  alias Gralkor.CaptureBuffer
  alias Gralkor.Client.Native
  alias Gralkor.Config
  alias Gralkor.Distill
  alias Gralkor.GraphitiPool

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: Gralkor.Supervisor)
  end

  @doc false
  def children do
    cond do
      Application.get_env(:jido_gralkor, :client) == Gralkor.Client.InMemory ->
        []

      true ->
        case Config.falkordb_spec() do
          nil -> []
          spec -> build_children(spec)
        end
    end
  end

  defp build_children(spec) do
    remote? = match?({:remote, _}, spec)

    [
      {Gralkor.Python, [reap_orphans: not remote?]},
      {GraphitiPool,
       [
         falkordb_spec: spec,
         llm_model: Config.llm_model(),
         embedder_model: Config.embedder_model(),
         interpret_fn: Native.interpret_callback()
       ]},
      {CaptureBuffer, [flush_callback: build_flush_callback(spec)]}
    ]
  end

  @doc false
  def build_flush_callback(_config, deps \\ []) do
    distill_fn = Keyword.get_lazy(deps, :distill_fn, &Native.distill_callback/0)
    add_episode_fn = Keyword.get(deps, :add_episode_fn, &GraphitiPool.add_episode/4)
    generalise_fn = Keyword.get(deps, :generalise_fn)

    fn group_id, agent_name, user_name, ontology, turns ->
      body = Distill.format_transcript(turns, distill_fn, agent_name, user_name)

      cond do
        body == "" ->
          :ok

        true ->
          t0 = System.monotonic_time(:millisecond)
          result = add_episode_fn.(group_id, body, "captured", ontology)
          ms = System.monotonic_time(:millisecond) - t0

          Logger.info(
            "[gralkor] capture flushed — group:#{group_id} bodyChars:#{String.length(body)} #{ms}ms"
          )

          if Application.get_env(:jido_gralkor, :test, false),
            do: Logger.info("[gralkor] [test] capture flush body: #{body}")

          if result == :ok && generalise_fn do
            Task.start(fn -> generalise_fn.(group_id, body) end)
          end

          result
      end
    end
  end
end
