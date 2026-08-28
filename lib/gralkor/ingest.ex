defmodule Gralkor.Ingest do
  @moduledoc """
  A request to ingest content through a registered `Gralkor.Lens`.

  `operator_id` identifies the operator whose local Lens group is used; global
  Lenses ignore it for storage placement. `lens` is the registered Lens name.
  Gralkor resolves that definition before invoking its ingestion process, so
  callers provide content and source context rather than ontology or group
  details. `source_kind` is the deterministic origin enum: conversations and
  documents carry text, while structured records carry a JSON-compatible map
  or list. It describes provenance, not credibility or truth.
  """

  @enforce_keys [:operator_id, :lens, :source_kind, :content, :source_description]
  defstruct [:id, :operator_id, :lens, :source_kind, :content, :source_description, :evidence_id]

  @type source_kind :: :conversation | :document | :structured_record

  @spec validate_source!(source_kind() | term(), term()) :: :ok
  def validate_source!(kind, content) do
    validate_source_kind!(kind)
    validate_source_content!(kind, content)
  end

  @spec encode_content!(source_kind(), String.t() | map() | list()) :: String.t()
  def encode_content!(:structured_record, content), do: Jason.encode!(content)
  def encode_content!(_kind, content), do: content

  defp validate_source_kind!(kind) when kind in [:conversation, :document, :structured_record],
    do: :ok

  defp validate_source_kind!(kind) do
    raise ArgumentError,
          "invalid source kind #{inspect(kind)}; expected :conversation, :document, or :structured_record"
  end

  defp validate_source_content!(kind, content)
       when kind in [:conversation, :document] and is_binary(content),
       do: :ok

  defp validate_source_content!(:structured_record, content)
       when is_map(content) or is_list(content) do
    case Jason.encode(content) do
      {:ok, _json} -> :ok
      {:error, _reason} -> invalid_source_content!(:structured_record, content)
    end
  end

  defp validate_source_content!(kind, content), do: invalid_source_content!(kind, content)

  defp invalid_source_content!(kind, content) do
    raise ArgumentError,
          "invalid source content for #{kind}: #{inspect(content)}"
  end

  @type t ::
          %__MODULE__{
            id: String.t(),
            operator_id: String.t(),
            lens: String.t(),
            source_kind: :conversation,
            content: String.t(),
            source_description: String.t(),
            evidence_id: String.t() | nil
          }
          | %__MODULE__{
              id: String.t(),
              operator_id: String.t(),
              lens: String.t(),
              source_kind: :document,
              content: String.t(),
              source_description: String.t(),
              evidence_id: String.t() | nil
            }
          | %__MODULE__{
              id: String.t(),
              operator_id: String.t(),
              lens: String.t(),
              source_kind: :structured_record,
              content: map() | list(),
              source_description: String.t(),
              evidence_id: String.t() | nil
            }
end
