defmodule Gralkor.Reflection.ChainOfThought do
  @moduledoc false

  defmodule Step do
    @moduledoc false
    @enforce_keys [:label, :directions, :output]
    defstruct [:label, :directions, :output]
  end

  @enforce_keys [:path, :steps]
  defstruct [:path, :steps]

  @type t :: %__MODULE__{path: String.t(), steps: [Step.t()]}

  def load(path) do
    with {:ok, yaml} <- YamlElixir.read_from_file(path),
         {:ok, steps} <- parse_steps(yaml) do
      {:ok, %__MODULE__{path: path, steps: steps}}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp parse_steps(%{"steps" => steps}) when is_list(steps) and steps != [] do
    Enum.reduce_while(steps, {:ok, {[], MapSet.new()}}, fn raw, {:ok, {parsed, outputs}} ->
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
    duplicate = Enum.find(names, &MapSet.member?(prior_outputs, &1))
    reference = Enum.find(interpolations(directions), &(not MapSet.member?(prior_outputs, &1)))

    cond do
      duplicate -> {:error, {:duplicate_output, duplicate, label}}
      reference -> {:error, {:unknown_interpolation, reference, label}}
      Enum.any?(output, fn {name, type} -> not non_blank?(name) or not valid_type_declaration?(type) end) ->
        {:error, {:invalid_output_type, label}}
      true ->
        step = %Step{label: label, directions: directions, output: output}
        {:ok, step, Enum.reduce(names, prior_outputs, &MapSet.put(&2, &1))}
    end
  end

  def interpolations(directions) do
    ~r/\{\{\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\}\}/
    |> Regex.scan(directions, capture: :all_but_first)
    |> List.flatten()
  end

  defp valid_type_declaration?(type), do: non_blank?(type)
  defp non_blank?(value), do: is_binary(value) and String.trim(value) != ""
end
