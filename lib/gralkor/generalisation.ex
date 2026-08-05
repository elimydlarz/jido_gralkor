defmodule Gralkor.Generalisation do
  @moduledoc """
  Struct and wire format for generalisations stored as graphiti episodes in a
  dedicated group (`"\#{group_id}_gen"`).

  The struct `:id` doubles as the graphiti episode UUID — `add_episode` accepts
  an optional `uuid` parameter, so we control identity. This gives us update
  (re-add with same uuid) and delete (`remove_episode(uuid)`) on generalisations.

  ## Wire format

  Episode content uses a single-line metadata prefix followed by the free-text
  generalisation:

      GEN|v1|{"id":"abc123","level":2,"confidence":0.85,"generalises":["def456"]}
      Eli prefers concise, structured responses by default.

  The prefix is part of the text that graphiti embeds, so generalisations are
  searchable by their content while remaining parseable on read.

  See `test-trees/unit/generalisation_TEST_TREES.md`.
  """

  alias Gralkor.GeneralisationParseFailed

  @enforce_keys [:id, :content, :level, :confidence]
  defstruct [
    :id,
    :content,
    :level,
    :confidence,
    generalises: [],
    created_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          content: String.t(),
          level: non_neg_integer(),
          confidence: float(),
          generalises: [String.t()],
          created_at: String.t() | nil
        }

  @prefix_v1 "GEN|v1|"

  @doc """
  Encodes a `%Generalisation{}` struct into an episode body string suitable for
  `GraphitiPool.add_episode/5`. The returned string has the metadata prefix as
  its first line, followed by the free-text content.
  """
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = gen) do
    meta = %{
      "id" => gen.id,
      "level" => gen.level,
      "confidence" => gen.confidence,
      "generalises" => gen.generalises
    }

    "#{@prefix_v1}#{Jason.encode!(meta)}\n#{gen.content}"
  end

  @doc """
  Decodes a raw fact string (from a graphiti search result) into a
  `%Generalisation{}` struct and the plain content.

  Returns `{:ok, %Generalisation{}, plain_content}` on success,
  `{:error, :not_a_generalisation}` for strings without the prefix,
  or raises `GeneralisationParseFailed` for malformed metadata.
  """
  @spec decode(String.t()) :: {:ok, t(), String.t()} | {:error, :not_a_generalisation}
  def decode(raw) when is_binary(raw) do
    case String.split(raw, "\n", parts: 2) do
      [first_line, rest] ->
        case String.starts_with?(first_line, @prefix_v1) do
          true ->
            json = String.replace_prefix(first_line, @prefix_v1, "")
            meta = Jason.decode!(json)

            gen = %__MODULE__{
              id: Map.fetch!(meta, "id"),
              content: String.trim(rest),
              level: Map.fetch!(meta, "level"),
              confidence: Map.fetch!(meta, "confidence"),
              generalises: Map.get(meta, "generalises", [])
            }

            {:ok, gen, String.trim(rest)}

          false ->
            {:error, :not_a_generalisation}
        end

      _ ->
        {:error, :not_a_generalisation}
    end
  rescue
    e in Jason.DecodeError ->
      raise GeneralisationParseFailed,
        message: "generalisation metadata JSON is malformed: #{Exception.message(e)}",
        raw: raw

    e in KeyError ->
      raise GeneralisationParseFailed,
        message:
          "generalisation metadata missing required field #{inspect(e.key)} (raw: #{inspect(raw)})",
        raw: raw
  end
end
