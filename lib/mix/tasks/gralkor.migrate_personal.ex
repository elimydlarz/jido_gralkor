defmodule Mix.Tasks.Gralkor.MigratePersonal do
  use Mix.Task

  alias Gralkor.PersonalGraphMigration

  @shortdoc "Migrate explicitly identified historical private graphs"
  @moduledoc """
  Runs `plan`, `prepare`, `advance`, `apply`, or `rollback` using an explicit
  JSON request file. See `PERSONAL_MEMORY_MIGRATION.md` for request shapes,
  quiescence requirements, verification, and coordinated application rollback.

  This task loads application configuration but does not start consumers.
  It prints the resulting manifest as JSON and never selects a default store.
  """

  @operations ~w(plan prepare advance apply rollback)
  @connection_fields ~w(host port username password ssl unix_socket_path db socket_timeout socket_connect_timeout)a
  @usage "usage: mix gralkor.migrate_personal <plan|prepare|advance|apply|rollback> <request.json>"

  @impl true
  def run([operation, request_path]) when operation in @operations do
    Mix.Task.run("app.config")
    request = request_path |> File.read!() |> Jason.decode!()
    connection = connection!(request)

    result =
      case operation do
        "plan" ->
          PersonalGraphMigration.plan(
            connection,
            Map.fetch!(request, "operator_ids"),
            Map.fetch!(request, "configuration_references")
          )

        "prepare" ->
          PersonalGraphMigration.prepare(
            connection,
            Map.fetch!(request, "operator_ids"),
            Map.fetch!(request, "configuration_references"),
            Map.fetch!(request, "journal_path")
          )

        operation ->
          apply(PersonalGraphMigration, operation_atom(operation), [
            connection,
            Map.fetch!(request, "journal_path"),
            Map.fetch!(request, "quiescence")
          ])
      end

    case result do
      {:ok, manifest} -> Mix.shell().info(Jason.encode!(manifest, pretty: true))
      {:error, reason} -> Mix.raise(reason)
    end
  end

  def run(_args), do: Mix.raise(@usage)

  defp operation_atom("advance"), do: :advance
  defp operation_atom("apply"), do: :apply
  defp operation_atom("rollback"), do: :rollback

  defp connection!(%{"connection" => fields}) when is_map(fields) do
    Enum.map(fields, fn {key, value} ->
      case Enum.find(@connection_fields, &(Atom.to_string(&1) == key)) do
        nil -> Mix.raise("unsupported graph connection field: #{key}")
        field -> {field, value}
      end
    end)
  end

  defp connection!(_), do: Mix.raise("an explicit graph connection object is required")
end
