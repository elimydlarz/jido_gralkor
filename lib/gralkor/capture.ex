defmodule Gralkor.Capture do
  @moduledoc """
  One conversation turn captured through an explicit route.

  `{:direct, destination}` writes the conversation to a registered Destination
  without Lens authorship. `{:lenses, names}` runs each distinct selected Lens
  with its own Destination, ontology, and ingestion process. The operator
  identifier is supplied separately and never contains a resolved graph name.
  """

  alias Gralkor.Destination
  alias Gralkor.Lens
  alias JidoGralkor.Runtime

  @enforce_keys [:session_id, :operator_id, :agent_name, :user_name, :messages, :route]
  defstruct [:session_id, :operator_id, :agent_name, :user_name, :messages, :route]

  @type route :: {:direct, String.t()} | {:lenses, [String.t()]}
  @type resolved_route :: {:direct, String.t(), module()} | {:lens, Lens.t()}
  @type t :: %__MODULE__{
          session_id: String.t(),
          operator_id: String.t(),
          agent_name: String.t(),
          user_name: String.t(),
          messages: [Gralkor.Message.t()],
          route: route()
        }

  @spec validate!(t()) :: :ok
  def validate!(%__MODULE__{} = request) do
    for field <- [:session_id, :operator_id, :agent_name, :user_name] do
      non_blank!(field, Map.fetch!(request, field))
    end

    Destination.validate_operator_id!(request.operator_id)

    unless is_list(request.messages) and
             Enum.all?(request.messages, fn
               %Gralkor.Message{role: role, content: content}
               when role in ["user", "assistant", "behaviour"] and is_binary(content) ->
                 true

               _ ->
                 false
             end) do
      raise ArgumentError, "capture messages must be canonical Gralkor.Message values"
    end

    case request.route do
      {:direct, destination} ->
        non_blank!(:destination, destination)

      {:lenses, [_ | _] = names} ->
        Enum.each(names, &non_blank!(:lens, &1))

      invalid ->
        raise ArgumentError,
              "invalid capture route #{inspect(invalid)}; use {:direct, destination} or {:lenses, names}"
    end

    :ok
  end

  @spec resolve!(pid(), t()) :: [resolved_route()]
  def resolve!(owner, %__MODULE__{} = request) do
    validate!(request)

    case request.route do
      {:direct, name} ->
        destination = Runtime.destination!(owner, name)

        [
          {:direct, Destination.graph_id(destination, request.operator_id),
           Gralkor.DefaultOntology}
        ]

      {:lenses, names} ->
        owner
        |> Runtime.lenses!(Enum.uniq(names))
        |> Enum.map(fn
          %Lens{} = lens ->
            {:lens, lens}

          lens ->
            raise ArgumentError, "Lens #{inspect(lens.name)} accepts only whole-graph replacement"
        end)
    end
  end

  @spec non_blank!(atom(), term()) :: :ok
  defp non_blank!(field, value) do
    unless is_binary(value) and String.trim(value) != "" do
      raise ArgumentError, "capture #{field} must be a non-blank string, got #{inspect(value)}"
    end

    :ok
  end
end
