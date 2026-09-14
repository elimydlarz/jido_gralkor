defmodule Gralkor.PersonalGraphMigration do
  @moduledoc """
  Prepares and verifies the explicit migration of historical private graphs.

  Operator identifiers remain unchanged. Connections and configuration references
  are supplied explicitly so migration never selects a running application's store.
  """

  @type connection :: keyword()
  @type manifest :: %{String.t() => term()}

  @spec plan(connection(), [String.t()], map()) :: {:ok, manifest()} | {:error, String.t()}
  def plan(_connection, operator_ids, _configuration_references) do
    {:ok,
     %{
       "graphs" =>
         Enum.map(operator_ids, fn identifier ->
           %{
             "source_logical" => "operator/" <> identifier,
             "target_logical" => "personal/" <> identifier
           }
         end)
     }}
  end
end
