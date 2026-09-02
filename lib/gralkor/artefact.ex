defmodule Gralkor.Artefact do
  @moduledoc "An immutable structured output produced by Gralkor work."

  import Bitwise

  @enforce_keys [:id, :payload]
  defstruct [:id, :payload]

  @type t :: %__MODULE__{id: String.t(), payload: map()}

  def new(id, payload), do: %__MODULE__{id: id, payload: payload}

  def id_for(operator_id, invocation_id, producer_name)
      when is_binary(operator_id) and is_binary(invocation_id) and is_binary(producer_name) do
    identity =
      [operator_id, invocation_id, producer_name]
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
