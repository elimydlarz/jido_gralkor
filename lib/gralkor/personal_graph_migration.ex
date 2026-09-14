defmodule Gralkor.PersonalGraphMigration do
  @moduledoc """
  Prepares and verifies the explicit migration of historical private graphs.

  Operator identifiers remain unchanged. Connections and configuration references
  are supplied explicitly so migration never selects a running application's store.
  """

  @type connection :: keyword()
  @type manifest :: %{String.t() => term()}

  @python_path Path.expand("../../priv/python/personal_graph_migration.py", __DIR__)
  @external_resource @python_path

  @spec plan(connection(), [String.t()], map()) :: {:ok, manifest()} | {:error, String.t()}
  def plan(connection, operator_ids, configuration_references) do
    execute(connection, %{
      action: "plan",
      operator_ids: operator_ids,
      configuration_references: configuration_references
    })
  end

  defp execute(connection, request) do
    :ok = Gralkor.Python.ensure_initialised()

    {result, _globals} =
      Pythonx.eval(
        """
        import importlib.util, json
        spec = importlib.util.spec_from_file_location('gralkor_personal_migration', module_path.decode())
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        json.dumps(module.execute(json.loads(payload.decode())))
        """,
        %{
          "module_path" => Application.app_dir(:jido_gralkor, "priv/python/personal_graph_migration.py"),
          "payload" => Jason.encode!(Map.put(request, :connection, Map.new(connection)))
        }
      )

    {:ok, result |> Pythonx.decode() |> Jason.decode!()}
  rescue
    error in Pythonx.Error -> {:error, Exception.message(error)}
  end
end
