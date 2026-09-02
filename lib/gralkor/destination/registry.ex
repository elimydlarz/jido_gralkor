defmodule Gralkor.Destination.Registry do
  @moduledoc false

  alias Gralkor.Destination

  @packaged [
    %Destination{name: "operator"},
    %Destination{name: "global"}
  ]

  def configured! do
    case Application.get_env(:jido_gralkor, :destinations, []) do
      definitions when is_list(definitions) ->
        destinations = @packaged ++ Enum.map(definitions, &resolve!/1)
        validate_unique_names!(destinations)
        destinations

      invalid ->
        raise ArgumentError, "Destination registry must be a list, got #{inspect(invalid)}"
    end
  end

  def fetch!(name) when is_binary(name) do
    case Enum.find(configured!(), &(&1.name == name)) do
      nil -> raise ArgumentError, "unknown Destination #{inspect(name)}"
      destination -> destination
    end
  end

  defp resolve!(definition) when is_list(definition) do
    unless Keyword.keyword?(definition) do
      raise ArgumentError, "invalid Destination definition #{inspect(definition)}"
    end

    name = Keyword.get(definition, :name)

    unless is_binary(name) and String.trim(name) != "" do
      raise ArgumentError, "invalid Destination name #{inspect(name)}"
    end

    if String.starts_with?(name, "operator/") do
      raise ArgumentError,
            "invalid Destination #{inspect(name)}: name uses reserved \"operator/\" graph namespace"
    end

    validate_fields!(name, definition)
    %Destination{name: name}
  end

  defp resolve!(definition),
    do: raise(ArgumentError, "invalid Destination definition #{inspect(definition)}")

  defp validate_fields!(name, definition) do
    case Keyword.keys(definition) -- [:name] do
      [] -> :ok
      [field | _] -> raise ArgumentError, "invalid Destination #{inspect(name)} #{field} setting"
    end
  end

  defp validate_unique_names!(destinations) do
    destinations
    |> Enum.group_by(& &1.name)
    |> Enum.find(fn {_name, definitions} -> length(definitions) > 1 end)
    |> case do
      nil -> :ok
      {name, _} -> raise ArgumentError, "duplicate Destination #{inspect(name)}"
    end
  end
end
