defmodule Gralkor.Reflection.Registry do
  @moduledoc false

  alias Gralkor.Reflection
  alias Gralkor.Reflection.ChainOfThought

  def load(definitions, opts \\ []) when is_list(definitions) do
    root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()

    with :ok <- validate_names(definitions),
         {:ok, reflections} <- load_all(definitions, root) do
      {:ok, reflections}
    end
  end

  def load(definitions, _opts), do: {:error, {:invalid_reflections, definitions}}

  def load!(definitions, opts \\ []) do
    case load(definitions, opts) do
      {:ok, reflections} -> reflections
      {:error, reason} -> raise ArgumentError, "invalid Reflection declaration: #{inspect(reason)}"
    end
  end

  defp validate_names(definitions) do
    names = Enum.map(definitions, &field(&1, :name))

    cond do
      invalid = Enum.find(names, &(not non_blank?(&1))) -> {:error, {:blank_name, invalid}}
      duplicate = duplicate(names) -> {:error, {:duplicate_name, duplicate}}
      true -> :ok
    end
  end

  defp load_all(definitions, root) do
    Enum.reduce_while(definitions, {:ok, []}, fn definition, {:ok, acc} ->
      case load_one(definition, root) do
        {:ok, reflection} -> {:cont, {:ok, acc ++ [reflection]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp load_one(definition, root) do
    name = field(definition, :name)
    scope = field(definition, :scope)
    relative = field(definition, :chain_of_thought)

    cond do
      is_nil(relative) -> {:error, {:missing_chain_of_thought, name}}
      not non_blank?(relative) -> {:error, {:invalid_chain_of_thought_file, name, relative}}
      scope not in [:operator, :global, "operator", "global"] -> {:error, {:invalid_destination_scope, name, scope}}
      true -> load_cot(name, scope, relative, root)
    end
  end

  defp load_cot(name, scope, relative, root) do
    path = Path.expand(relative, root)

    cond do
      not repository_path?(path, root) or Path.extname(path) not in [".yaml", ".yml"] ->
        {:error, {:invalid_chain_of_thought_file, name, relative}}

      true ->
        case ChainOfThought.load(path) do
          {:ok, cot} -> {:ok, %Reflection{name: name, scope: normalize_scope(scope), chain_of_thought: cot}}
          {:error, reason} -> {:error, {:invalid_chain_of_thought, name, relative, reason}}
        end
    end
  end

  defp repository_path?(path, root), do: path == root or String.starts_with?(path, root <> "/")
  defp normalize_scope("operator"), do: :operator
  defp normalize_scope("global"), do: :global
  defp normalize_scope(scope), do: scope

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp field(keyword, key) when is_list(keyword), do: Keyword.get(keyword, key)
  defp field(_, _), do: nil

  defp duplicate(values) do
    values |> Enum.frequencies() |> Enum.find_value(fn {value, count} -> if count > 1, do: value end)
  end

  defp non_blank?(value), do: is_binary(value) and String.trim(value) != ""
end
