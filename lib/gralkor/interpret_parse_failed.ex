defmodule Gralkor.InterpretParseFailed do
  @moduledoc """
  Raised when the LLM's interpret response cannot be parsed against the
  structured-output schema — typically because `:output_token_budget` was too
  small and the model's answer truncated mid-list, but also for any other
  schema mismatch.

  Distinct from `RuntimeError` so callers can recover (e.g. retry recall with
  a larger budget, or surface a typed error to the user) without catching
  every internal failure.

  See `test-trees/unit/interpret_TEST_TREES.md`.
  """

  defexception [:message, :raw_response]

  @impl true
  def exception(opts) do
    raw = Keyword.get(opts, :raw_response)

    %__MODULE__{
      message:
        Keyword.get(
          opts,
          :message,
          "interpret response could not be parsed against the schema (raw: #{inspect(raw)})"
        ),
      raw_response: raw
    }
  end
end
