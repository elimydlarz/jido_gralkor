defmodule Gralkor.Message do
  @moduledoc """
  Canonical message shape that Gralkor expects at its port boundary.

  One shape, three roles. Adapters normalise their harness's events into this
  form before calling the configured client's `capture/5`, `/6`, or `/7`.

    * `:role` — `"user" | "assistant" | "behaviour"`. `behaviour` collapses
      thinking, tool calls, tool results, and any other harness-internal
      activity into a single role; Gralkor does not branch on interior shape
      beyond role.
    * `:content` — a string. Adapters choose how to render their events;
      In implicit-operator mode Gralkor renders user and assistant content into
      the captured transcript and uses role labels in recall context. A
      selected Lens's ingestion process decides how its captured messages are
      persisted.
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
