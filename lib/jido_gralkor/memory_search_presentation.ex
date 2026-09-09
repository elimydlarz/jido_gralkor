defmodule JidoGralkor.MemorySearchPresentation do
  @moduledoc """
  Select complete memory results for a model-facing JSON byte budget.

  Measures the complete Jido success envelope. Omission metadata is outside
  the result list; source content and Reflection payloads are never sliced.
  Canonical `Gralkor.Client.search/1,2` results remain independent of this
  explicit presentation operation.
  """

  @type output :: %{result: [map()], omissions: %{byte_budget: non_neg_integer()}}

  @spec validate_max_bytes!(term()) :: pos_integer()
  def validate_max_bytes!(max_bytes) when is_integer(max_bytes) and max_bytes > 0, do: max_bytes

  def validate_max_bytes!(max_bytes) do
    raise ArgumentError,
          "memory_search_max_bytes must be a positive integer, got: #{inspect(max_bytes)}"
  end

  @spec for_model([map()], pos_integer()) :: {:ok, output()} | {:error, term()}
  def for_model(results, max_bytes) do
    validate_max_bytes!(max_bytes)
    total = length(results)
    minimum_bytes = envelope_bytes(output([], total))

    if minimum_bytes > max_bytes do
      {:error,
       {:memory_search_budget_too_small, %{max_bytes: max_bytes, minimum_bytes: minimum_bytes}}}
    else
      selected =
        Enum.reduce(results, [], fn result, selected ->
          candidate = selected ++ [result]
          if envelope_bytes(output(candidate, total)) <= max_bytes, do: candidate, else: selected
        end)

      {:ok, output(selected, total)}
    end
  end

  defp output(results, _total) do
    groups = Enum.group_by(results, fn %{fact: fact} -> hd(fact.sources).lens end)
    text = Enum.map_join(groups, "\n\n", fn {lens, facts} ->
      "Lens: #{lens}\n" <> Enum.map_join(facts, "\n", &"- #{&1.fact.fact}")
    end)
    %{result: text}
  end

  defp envelope_bytes(output), do: byte_size(Jason.encode!(%{ok: true, result: output}))
end
