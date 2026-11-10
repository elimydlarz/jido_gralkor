defmodule Gralkor.Application do
  @moduledoc false

  use Application

  alias Gralkor.Config
  alias Gralkor.GraphitiPool

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [{Task.Supervisor, name: Gralkor.SearchSupervisor} | children()],
      strategy: :one_for_one,
      name: Gralkor.Supervisor
    )
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
        embedder_model: Config.embedder_model(),
        reranker_model: Config.reranker_model(),
        llm_routes: Config.llm_routes(),
        llm_tuning: Config.llm_tuning(),
        embedder_dimension: Config.embedder_dimension(),
        embedder_batch_size: Config.embedder_batch_size(),
        graph_operation_deadline_ms: Config.graph_operation_deadline_ms()
      ] ++ falkordb_socket_options(spec)

    [
      {Gralkor.Python, [reap_orphans: not remote?]},
      {GraphitiPool, graphiti_opts}
    ]
  end

  defp falkordb_socket_options({:embedded, _data_dir}) do
    [embedded_falkordb_socket_timeout_ms: Config.embedded_falkordb_socket_timeout_ms()]
  end

  defp falkordb_socket_options({:remote, _options}) do
    [
      remote_falkordb_socket_timeout_ms: Config.remote_falkordb_socket_timeout_ms(),
      remote_falkordb_max_connections: Config.remote_falkordb_max_connections()
    ]
  end
end
