defmodule Gralkor.GeneralisationParseFailed do
  @moduledoc """
  Raised when a `GEN|v1|` generalisation contains malformed JSON metadata or
  omits required fields.

  Distinct from `RuntimeError` so callers can distinguish "this graphiti fact
  is not a generalisation" (skip) from "the data is corrupted" (log and raise).

  See `test-trees/unit/generalisation_TEST_TREES.md`.
  """

  defexception [:message, :raw]

  @impl true
  def exception(opts) do
    raw = Keyword.get(opts, :raw)

    %__MODULE__{
      message:
        Keyword.get(
          opts,
          :message,
          "generalisation metadata could not be parsed (raw: #{inspect(raw)})"
        ),
      raw: raw
    }
  end
end
