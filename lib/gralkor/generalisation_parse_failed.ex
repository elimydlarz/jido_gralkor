defmodule Gralkor.GeneralisationParseFailed do
  @moduledoc """
  Raised when a string cannot be decoded as a generalisation — the `GEN|v1|`
  prefix is missing, the JSON metadata is malformed, or required fields are
  absent.

  Distinct from `RuntimeError` so callers can distinguish "this graphiti fact
  is not a generalisation" (skip) from "the data is corrupted" (log and raise).

  See `ex-generalisation` in `TEST_TREES.md`.
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
