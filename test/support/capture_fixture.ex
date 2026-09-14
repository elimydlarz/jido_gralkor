defmodule Gralkor.CaptureFixture do
  @moduledoc false

  @spec capture(module(), String.t(), String.t(), String.t(), String.t(), [Gralkor.Message.t()]) :: term()
  def capture(adapter, session, destination, agent, user, messages) do
    request(adapter, session, "operator-one", agent, user, messages, {:direct, destination})
  end

  @spec capture(module(), String.t(), String.t(), String.t(), String.t(), [Gralkor.Message.t()], String.t()) :: term()
  def capture(adapter, session, operator, agent, user, messages, lens) do
    capture(adapter, session, operator, agent, user, messages, lens, [])
  end

  @spec capture(module(), String.t(), String.t(), String.t(), String.t(), [Gralkor.Message.t()], String.t(), [String.t()]) :: term()
  def capture(adapter, session, operator, agent, user, messages, lens, additional) do
    request(adapter, session, operator, agent, user, messages, {:lenses, [lens | additional]})
  end

  @spec capture_arguments(module(), [term()]) :: term()
  def capture_arguments(adapter, arguments), do: apply(__MODULE__, :capture, [adapter | arguments])

  defp request(adapter, session, operator, agent, user, messages, route) do
    case GenServer.whereis({:global, {JidoGralkor.Runtime, self()}}) do
      nil ->
        ExUnit.Callbacks.start_supervised!({JidoGralkor.Runtime,
          owner: self(),
          configuration: %{
            destinations: Enum.map(["g", "g1", "g-1", "with-hyphens", "group-1", "operator_one"], &%{name: &1}),
            lenses: Enum.map(["observations", "generalisations", "decisions"], &%{name: &1, destination: "personal", write: :append, ingestion: Gralkor.Lens.Ingestion.Store}),
            reflections: []
          }
        })
      _ -> :ok
    end

    adapter.capture(self(), %Gralkor.Capture{session_id: session, operator_id: operator, agent_name: agent, user_name: user, messages: messages, route: route})
  end
end
