defmodule JidoGralkor.RuntimeTest do
  use ExUnit.Case, async: false

  alias JidoGralkor.Runtime

  defmodule RetryableStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(_, _, _, _, _, _), do: {:ok, []}

    @impl true
    def put_artefact(_, _, _, artefact) do
      test_pid = Application.fetch_env!(:jido_gralkor, :runtime_unit_test_pid)
      send(test_pid, {:delivery_attempt, artefact})
      {:error, %{status: 503, reason: :unavailable}}
    end

    @impl true
    def get_artefact(_, _, _, _), do: {:error, :not_found}
  end

  setup do
    previous = Application.get_env(:jido_gralkor, :runtime_unit_test_pid)
    Application.put_env(:jido_gralkor, :runtime_unit_test_pid, self())

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:jido_gralkor, :runtime_unit_test_pid)
      else
        Application.put_env(:jido_gralkor, :runtime_unit_test_pid, previous)
      end
    end)

    :ok
  end

  describe "if Destination delivery reports a retryable server failure > while no retry succeeds within twenty-four hours" do
    test "then delivery is abandoned without another attempt and the callback receives the artefact and abandonment" do
      clock = start_supervised!({Agent, fn -> 0 end})
      start_runtime(reflection_configuration())
      test_pid = self()

      assert {:ok, "deadline-invocation"} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("deadline-invocation"),
                 &send(test_pid, {:reflection_callback, &1}),
                 inference: fn _ -> {:ok, %{output: %{"summary" => "complete"}}} end,
                 storage: RetryableStorage,
                 clock: fn -> Agent.get(clock, & &1) end,
                 sleep: fn _delay -> Agent.update(clock, &(&1 + 86_400_000)) end
               )

      assert_receive {:delivery_attempt, artefact}

      assert_receive {:reflection_callback,
                      %{
                        invocation_id: "deadline-invocation",
                        artefact: ^artefact,
                        outcome:
                          {:abandoned,
                           %{stage: :delivery, reason: %{status: 503, reason: :unavailable}}}
                      }}

      refute_receive {:delivery_attempt, _}
    end
  end

  defp start_runtime(configuration) do
    start_supervised!({Runtime, owner: self(), configuration: configuration})
  end

  defp reflection_configuration do
    %{
      destinations: [%{name: "reviews"}],
      lenses: [],
      reflections: [
        %{
          name: "review",
          outputs: [%{kind: :destination, destination: "reviews"}],
          chain_of_thought: %{
            steps: [
              %{
                label: "review",
                directions: "Review.",
                output: %{"summary" => "string"}
              }
            ]
          }
        }
      ]
    }
  end

  defp invocation(id) do
    %{id: id, operator_id: "operator-one", invocation_context: %{}, representations: []}
  end
end
