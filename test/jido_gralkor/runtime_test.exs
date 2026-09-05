defmodule JidoGralkor.RuntimeTest do
  use ExUnit.Case, async: false

  alias JidoGralkor.Runtime

  describe "if Destination delivery reports a retryable server failure > while no retry succeeds within twenty-four hours" do
    test "then delivery is abandoned without another attempt and the callback receives the artefact and abandonment" do
      clock = start_supervised!({Agent, fn -> 0 end})
      start_runtime(reflection_configuration())
      test_pid = self()
      artefact = Gralkor.Artefact.new("deadline-artefact", %{"summary" => "complete"})

      run_reflection = fn _reflection, _invocation, _opts -> {:ok, artefact} end

      deliver_artefact = fn _output, _reflection, _operator, delivered, _opts ->
        send(test_pid, {:delivery_attempt, delivered})
        {:error, %{status: 503, reason: :unavailable}}
      end

      assert {:ok, "deadline-invocation"} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("deadline-invocation"),
                 &send(test_pid, {:reflection_callback, &1}),
                 run_reflection: run_reflection,
                 deliver_artefact: deliver_artefact,
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
