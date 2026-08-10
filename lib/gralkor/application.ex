defmodule Gralkor.Application do
  @moduledoc false

  use Application

  require Logger

  alias Gralkor.CaptureBuffer
  alias Gralkor.Client.Native
  alias Gralkor.Config
  alias Gralkor.Distill
  alias Gralkor.GraphitiPool
  alias Gralkor.Ingest
  alias Gralkor.Reflection.Registry

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
      {CaptureBuffer,
       [
         flush_callback: build_flush_callback(spec),
         lens_flush_callback: build_lens_flush_callback(),
         reflections: Registry.configured!()
       ]}
    ]
  end

  @doc false
  def build_flush_callback(_config, deps \\ []) do
    add_episode_fn =
      Keyword.get(deps, :add_episode_fn, fn group_id, content, source, ontology, opts ->
        GraphitiPool.add_episode(GraphitiPool, group_id, content, source, ontology, opts)
      end)

    fn group_id, agent_name, user_name, ontology, turns ->
      body = Distill.format_transcript(turns, agent_name, user_name)

      if body == "" do
        :ok
      else
        t0 = System.monotonic_time(:millisecond)
        result = add_episode_fn.(group_id, body, "captured", ontology, [])
        ms = System.monotonic_time(:millisecond) - t0

        case result do
          :ok ->
            Logger.info(
              "[gralkor] capture flushed — group:#{group_id} bodyChars:#{String.length(body)} #{ms}ms"
            )

          {:error, reason} ->
            Logger.warning(
              "[gralkor] capture flush failed — group:#{group_id} #{inspect(reason)} (retrying)"
            )
        end

        if Application.get_env(:jido_gralkor, :test, false),
          do: Logger.info("[gralkor] [test] capture flush body: #{body}")

        result
      end
    end
  end

  @doc false
  def build_lens_flush_callback(deps \\ []) do
    ingest_fn = Keyword.get(deps, :ingest_fn, &Gralkor.Client.ingest_with_representation/1)

    fn operator_id, agent_name, user_name, lens, turns ->
      transcript = Distill.format_transcript(turns, agent_name, user_name)

      ingest_fn.(%Ingest{
        operator_id: operator_id,
        lens: lens,
        content: transcript,
        source_description: "captured"
      })
    end
  end
end
