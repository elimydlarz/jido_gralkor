defmodule Gralkor.Reflection.Artefact do
  @moduledoc "One structured result produced by one completed Reflection run."

  import Bitwise

  @enforce_keys [:id, :reflection, :payload, :evidence_ids]
  defstruct [:id, :reflection, :payload, :evidence_ids]

  @type t :: %__MODULE__{
          id: String.t(),
          reflection: String.t(),
          payload: map(),
          evidence_ids: [String.t()]
        }

  def new(reflection, payload, evidence_ids) do
    id = "reflection-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    %__MODULE__{id: id, reflection: reflection, payload: payload, evidence_ids: evidence_ids}
  end

  def new(id, reflection, payload, evidence_ids) do
    %__MODULE__{id: id, reflection: reflection, payload: payload, evidence_ids: evidence_ids}
  end

  def id_for(operator_id, ingestion_id, reflection_name)
      when is_binary(operator_id) and is_binary(ingestion_id) and is_binary(reflection_name) do
    identity =
      [operator_id, ingestion_id, reflection_name]
      |> Enum.map_join(fn value -> "#{byte_size(value)}:#{value}" end)

    <<part1::32, part2::16, part3::16, part4::16, part5::48, _::binary>> =
      :crypto.hash(:sha256, identity)

    version = bor(band(part3, 0x0FFF), 0x5000)
    variant = bor(band(part4, 0x3FFF), 0x8000)

    :io_lib.format(
      ~c"~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [part1, part2, version, variant, part5]
    )
    |> IO.iodata_to_binary()
  end
end
