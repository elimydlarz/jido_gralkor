defmodule Gralkor.Message do
  @moduledoc """
  Canonical message shape that Gralkor expects at its port boundary.

  One shape, three roles. Consumers normalise their chat turns into this form
  before rendering them with `Gralkor.Distill.format_transcript/3`.

    * `:role` — `"user" | "assistant" | "behaviour"`. `behaviour` collapses
      thinking, tool calls, tool results, and any other harness-internal
      activity into a single role; Gralkor does not branch on interior shape
      beyond role.
    * `:content` — a string. `Gralkor.Distill.format_transcript/3` renders
      user and assistant content into the transcript.
  """

  @enforce_keys [:role, :content]
  defstruct [:role, :content]

  @type role :: String.t()
  @type t :: %__MODULE__{role: role(), content: String.t()}

  @valid_roles ~w(user assistant behaviour)

  @spec new(role(), String.t()) :: t()
  def new(role, content) when role in @valid_roles and is_binary(content) do
    %__MODULE__{role: role, content: content}
  end
end
