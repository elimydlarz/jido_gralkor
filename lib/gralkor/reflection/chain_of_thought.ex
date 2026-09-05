defmodule Gralkor.Reflection.ChainOfThought do
  @moduledoc false

  defmodule Step do
    @moduledoc false
    @enforce_keys [:label, :directions, :output]
    defstruct [:label, :directions, :output]
  end

  @enforce_keys [:steps]
  defstruct [:steps]

  @type t :: %__MODULE__{steps: [Step.t()]}

  def from_config(config) do
    steps =
      config
      |> field(:steps)
      |> case do
        definitions when is_list(definitions) ->
          Enum.map(definitions, fn definition ->
            if is_map(definition) or is_list(definition) do
              %{
                "label" => field(definition, :label),
                "directions" => field(definition, :directions),
                "output" => field(definition, :output)
              }
            else
              definition
            end
          end)

        invalid ->
          invalid
      end

    case parse_steps(%{"steps" => steps}) do
      {:ok, parsed} -> {:ok, %__MODULE__{steps: parsed}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_steps(%{"steps" => steps}) when is_list(steps) and steps != [] do
    Enum.reduce_while(steps, {:ok, {[], %{}}}, fn raw, {:ok, {parsed, outputs}} ->
      case parse_step(raw, outputs) do
        {:ok, step, next_outputs} -> {:cont, {:ok, {parsed ++ [step], next_outputs}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, {parsed, _}} -> {:ok, parsed}
      error -> error
    end
  end

  defp parse_steps(_), do: {:error, :missing_steps}

  defp parse_step(raw, prior_outputs) when is_map(raw) do
    label = raw["label"]
    directions = raw["directions"]
    output = raw["output"]

    cond do
      not non_blank?(label) -> {:error, {:invalid_step_label, label}}
      not non_blank?(directions) -> {:error, {:invalid_step_directions, label}}
      not is_map(output) or map_size(output) == 0 -> {:error, {:invalid_step_output, label}}
      true -> validate_step(label, directions, output, prior_outputs)
    end
  end

  defp parse_step(raw, _), do: {:error, {:invalid_step, raw}}

  defp validate_step(label, directions, output, prior_outputs) do
    names = Map.keys(output)
    duplicate = Enum.find(names, &Map.has_key?(prior_outputs, &1))
    reference = Enum.find(interpolations(directions), &(not Map.has_key?(prior_outputs, &1)))

    invalid_output =
      Enum.find(output, fn {name, type} ->
        not non_blank?(name) or match?({:error, _}, parse_type(type))
      end)

    cond do
      duplicate ->
        {:error, {:duplicate_output, duplicate, Map.fetch!(prior_outputs, duplicate), label}}

      reference ->
        {:error, {:unknown_interpolation, reference, label}}

      invalid_output ->
        {name, type} = invalid_output

        if non_blank?(name) do
          {:error, {:invalid_output_type, label, type}}
        else
          {:error, {:invalid_output_name, label, name}}
        end

      true ->
        step = %Step{label: label, directions: directions, output: output}
        {:ok, step, Enum.reduce(names, prior_outputs, &Map.put(&2, &1, label))}
    end
  end

  def interpolations(directions) do
    ~r/\{\{\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\}\}/
    |> Regex.scan(directions, capture: :all_but_first)
    |> List.flatten()
  end

  def matches_type?(value, declaration) do
    case parse_type(declaration) do
      {:ok, type} -> matches?(value, type)
      {:error, _} -> false
    end
  end

  defp parse_type(declaration) when is_binary(declaration) do
    declaration = String.trim(declaration)

    cond do
      declaration in ["string", "boolean", "integer"] ->
        {:ok, String.to_atom(declaration)}

      String.starts_with?(declaration, "Array<") and String.ends_with?(declaration, ">") ->
        declaration
        |> String.slice(6, String.length(declaration) - 7)
        |> parse_type()
        |> wrap(:array)

      String.starts_with?(declaration, "{") and String.ends_with?(declaration, "}") ->
        declaration |> String.slice(1, String.length(declaration) - 2) |> parse_object()

      true ->
        {:error, declaration}
    end
  end

  defp parse_type(other), do: {:error, other}

  defp parse_object(body) do
    fields = split_top_level(body, ";") |> Enum.reject(&(String.trim(&1) == ""))

    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case String.split(field, ":", parts: 2) do
        [name, type] ->
          name = String.trim(name)

          case parse_type(type) do
            {:ok, parsed} when name != "" -> {:cont, {:ok, Map.put(acc, name, parsed)}}
            _ -> {:halt, {:error, field}}
          end

        _ ->
          {:halt, {:error, field}}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, {:object, fields}}
      error -> error
    end
  end

  defp split_top_level(value, separator) do
    {parts, current, _depth, _quote} =
      value
      |> String.graphemes()
      |> Enum.reduce({[], "", 0, nil}, fn char, {parts, current, depth, quote} ->
        cond do
          char in ["\"", "'"] and is_nil(quote) -> {parts, current <> char, depth, char}
          char == quote -> {parts, current <> char, depth, nil}
          not is_nil(quote) -> {parts, current <> char, depth, quote}
          char in ["<", "{"] -> {parts, current <> char, depth + 1, quote}
          char in [">", "}"] -> {parts, current <> char, depth - 1, quote}
          char == separator and depth == 0 -> {parts ++ [current], "", depth, quote}
          true -> {parts, current <> char, depth, quote}
        end
      end)

    parts ++ [current]
  end

  defp wrap({:ok, value}, tag), do: {:ok, {tag, value}}
  defp wrap(error, _tag), do: error

  defp matches?(value, :string), do: is_binary(value)
  defp matches?(value, :boolean), do: is_boolean(value)
  defp matches?(value, :integer), do: is_integer(value)

  defp matches?(value, {:array, type}),
    do: is_list(value) and Enum.all?(value, &matches?(&1, type))

  defp matches?(value, {:object, fields}) when is_map(value) do
    normalized = Map.new(value, fn {key, item} -> {to_string(key), item} end)

    MapSet.new(Map.keys(normalized)) == MapSet.new(Map.keys(fields)) and
      Enum.all?(fields, fn {key, type} -> matches?(normalized[key], type) end)
  end

  defp matches?(_, _), do: false

  defp non_blank?(value), do: is_binary(value) and String.trim(value) != ""

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(keyword, key) when is_list(keyword), do: Keyword.get(keyword, key)
  defp field(_, _), do: nil
end
