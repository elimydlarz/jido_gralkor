defmodule Gralkor.Application do
  @moduledoc false

  use Application

  require Logger

  alias Gralkor.CaptureBuffer
  alias Gralkor.Config
  alias Gralkor.Distill
  alias Gralkor.GraphitiPool
  alias Gralkor.Ingest

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: Gralkor.Supervisor)
  end

  @doc false
  def children do
    validate_retired_config!()

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

  defp validate_retired_config! do
    if Application.get_env(:jido_gralkor, :reflection_storage) do
      raise ArgumentError,
            ":reflection_storage is retired; Destination outputs are the artefact memory boundary"
    end
  end

  defp build_children(spec) do
    remote? = match?({:remote, _}, spec)

    graphiti_opts =
      [
        falkordb_spec: spec,
        llm_model: Config.llm_model(),
        embedder_model: Config.embedder_model()
      ] ++ embedded_falkordb_options(spec)

    [
      {Gralkor.Python, [reap_orphans: not remote?]},
      {GraphitiPool, graphiti_opts},
      {CaptureBuffer,
       [
         flush_callback: build_flush_callback(spec),
         lens_flush_callback: build_lens_flush_callback()
       ]}
    ]
  end

  defp embedded_falkordb_options({:embedded, _data_dir}) do
    [embedded_falkordb_socket_timeout_ms: Config.embedded_falkordb_socket_timeout_ms()]
  end

  defp embedded_falkordb_options({:remote, _options}), do: []

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

        result =
          add_episode_fn.(group_id, body, "captured", ontology,
            source_kind: :conversation,
            lens: "operator"
          )

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
    runtime_ingest_fn =
      Keyword.get(deps, :runtime_ingest_fn, &Gralkor.Client.ingest_with_representation/2)

    fn operator_id, agent_name, user_name, lens, turns, ingestion_id, runtime_owner ->
      transcript = Distill.format_transcript(turns, agent_name, user_name)

      if transcript == "" do
        :ok
      else
        request = %Ingest{
          id: ingestion_id,
          operator_id: operator_id,
          lens: lens,
          source_kind: :conversation,
          content: transcript,
          source_description: "captured"
        }

        if runtime_owner,
          do: runtime_ingest_fn.(runtime_owner, request),
          else: ingest_fn.(request)
      end
    end
  end
end
