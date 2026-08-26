defmodule JidoGralkor.ReAct do
  @moduledoc """
  Helpers for `Jido.AI.Reasoning.ReAct` consumers that want Gralkor-aware
  request shaping.

  `maybe_force_memory_search/2` pins `tool_choice` to the `memory_search`
  tool on the first ReAct iteration so the agent itself authors a focused
  search query (in the same thread, with the same model, as part of the
  same turn) rather than the harness embedding raw user text against the
  graph. From iteration 2 onward the override is omitted so the model is
  free to answer or call further tools.

  Workaround: `Jido.AI.Reasoning.ReAct.Config.tool_choice` is one value
  applied uniformly across the loop. Returning the override per-iteration
  through `RequestTransformer` is the cheapest way to vary it without
  forking the strategy. A first-class `:preamble_tool` config in ReAct
  would supersede this.
  """

  # OpenAI-style tool_choice — what ReqLLM's NimbleOptions schema accepts (map | atom | string)
  # and what the Google provider's `build_google_tool_config/1` translates to
  # `functionCallingConfig: %{mode: "ANY", allowedFunctionNames: ["memory_search"]}`.
  @memory_search_choice %{type: "function", function: %{name: "memory_search"}}

  @doc """
  Fold the iter-1 OpenAI-style `memory_search` tool-choice override into
  the consumer's existing transformer overrides map.

  On `state.iteration > 1` returns the overrides untouched. Matches on
  any struct or map exposing `:iteration` so tests don't need to build a
  full `Jido.AI.Reasoning.ReAct.State`.
  """
  @spec maybe_force_memory_search(map(), %{:iteration => integer(), optional(any) => any}) ::
          map()
  def maybe_force_memory_search(overrides, %{iteration: 1}) when is_map(overrides) do
    base_llm_opts = Map.get(overrides, :llm_opts, [])
    Map.put(overrides, :llm_opts, Keyword.put(base_llm_opts, :tool_choice, @memory_search_choice))
  end

  def maybe_force_memory_search(overrides, %{iteration: iter})
      when is_map(overrides) and is_integer(iter),
      do: overrides
end
