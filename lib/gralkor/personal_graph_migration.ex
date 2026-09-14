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

  @spec prepare(connection(), [String.t()], map(), String.t()) ::
          {:ok, manifest()} | {:error, String.t()}
  def prepare(connection, operator_ids, configuration_references, journal_path) do
    execute(connection, %{
      action: "prepare",
      operator_ids: operator_ids,
      configuration_references: configuration_references,
      journal_path: journal_path
    })
  end

  @spec apply(connection(), String.t(), map()) :: {:ok, manifest()} | {:error, String.t()}
  def apply(connection, journal_path, quiescence) do
    execute(connection, %{action: "apply", journal_path: journal_path, quiescence: quiescence})
  end

  @spec advance(connection(), String.t(), map()) :: {:ok, manifest()} | {:error, String.t()}
  def advance(connection, journal_path, quiescence) do
    execute(connection, %{action: "advance", journal_path: journal_path, quiescence: quiescence})
  end

  defp execute(connection, request) do
    :ok = Gralkor.Python.ensure_initialised()

    {result, _globals} =
      Pythonx.eval(
        """
        import json
        namespace = {}
        path = module_path.decode()
        with open(path) as source:
            exec(compile(source.read(), path, 'exec'), namespace)
        json.dumps(namespace['execute'](json.loads(payload.decode())))
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
