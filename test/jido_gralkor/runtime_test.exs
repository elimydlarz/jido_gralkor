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

  describe "when a runtime starts for an owning AgentServer PID with valid complete configuration" do
    test "then one runtime owns that agent's active configuration" do
      configuration = reflection_configuration()
      start_runtime(configuration)

      assert Runtime.snapshot(self()) == configuration
      assert Runtime.destination!(self(), "reviews").name == "reviews"
    end

    test "and the packaged Destinations, operator Lens, and Reflections are available beside consumer definitions" do
      start_runtime(reflection_configuration())

      assert Enum.map(Runtime.destinations(self()), & &1.name) == [
               "operator",
               "global",
               "reviews"
             ]

      assert Runtime.lens!(self(), "operator").name == "operator"
      assert Runtime.reflection!(self(), "generalisations").name == "generalisations"
      assert Runtime.reflection!(self(), "review").name == "review"
    end

    test "and admitted Reflection production and delivery run asynchronously under that runtime" do
      start_runtime(reflection_configuration())
      test_pid = self()

      assert {:ok, "async-invocation"} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("async-invocation"),
                 &send(test_pid, {:reflection_callback, &1}),
                 run_reflection: fn _reflection, _invocation, _opts ->
                   send(test_pid, :production_started)
                   {:ok, Gralkor.Artefact.new("async", %{})}
                 end,
                 deliver_artefact: fn _output, _reflection, _operator, _artefact, _opts ->
                   :ok
                 end
               )

      assert_receive :production_started
      assert_receive {:reflection_callback, %{outcome: :delivered}}
    end
  end

  describe "when a consumer replaces complete valid configuration" do
    test "then every definition is validated and resolved before activation" do
      start_runtime(reflection_configuration())
      replacement = reflection_configuration() |> Map.put(:destinations, [%{name: "new"}])

      assert :ok = Runtime.replace(self(), replacement)
      assert Runtime.snapshot(self()) == replacement
      assert Runtime.destination!(self(), "new").name == "new"
    end

    test "and replacement returns only after the new snapshot is active" do
      start_runtime(reflection_configuration())
      replacement = reflection_configuration() |> Map.put(:destinations, [%{name: "new"}])

      assert :ok = Runtime.replace(self(), replacement)
      assert Runtime.destination!(self(), "new").name == "new"
    end

    test "if replacement configuration is invalid then replacement returns the validation error and the previously active snapshot remains unchanged" do
      configuration = reflection_configuration()
      start_runtime(configuration)

      assert {:error, {:missing_collection, :lenses}} =
               Runtime.replace(self(), Map.delete(configuration, :lenses))

      assert Runtime.snapshot(self()) == configuration
    end
  end

  describe "when search definitions are resolved from an active runtime" do
    test "while no Destination names are supplied then every accessible Destination and every selected Lens resolve from one snapshot" do
      configuration = %{reflection_configuration() | lenses: [lens_configuration()]}
      start_runtime(configuration)

      assert {lenses, destinations} = Runtime.resolve_search!(self(), ["custom"], [])
      assert Enum.map(lenses, & &1.name) == ["custom"]
      assert Enum.map(destinations, & &1.name) == ["operator", "global", "reviews"]
    end

    test "while Destination and Lens names are supplied then those definitions resolve from one snapshot in first-selected order without duplicates" do
      configuration = %{reflection_configuration() | lenses: [lens_configuration()]}
      start_runtime(configuration)

      assert {lenses, destinations} =
               Runtime.resolve_search!(self(), ["custom", "custom"], [
                 "reviews",
                 "global",
                 "reviews"
               ])

      assert Enum.map(lenses, & &1.name) == ["custom"]
      assert Enum.map(destinations, & &1.name) == ["reviews", "global"]
    end

    test "if any selected name is unknown then resolution fails without returning a partial result" do
      start_runtime(reflection_configuration())

      assert_raise ArgumentError, ~r/unknown_definition/, fn ->
        Runtime.resolve_search!(self(), [], ["missing"])
      end
    end
  end

  describe "when Reflection production and Destination delivery succeed" do
    test "then the artefact is written once through the declared Destination output and the callback receives the invocation identifier, artefact, and delivered outcome" do
      start_runtime(reflection_configuration())
      test_pid = self()
      artefact = Gralkor.Artefact.new("success", %{})

      assert {:ok, "success-invocation"} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("success-invocation"),
                 &send(test_pid, {:reflection_callback, &1}),
                 run_reflection: fn _reflection, _invocation, _opts -> {:ok, artefact} end,
                 deliver_artefact: fn output, "review", "operator-one", ^artefact, _opts ->
                   send(test_pid, {:delivered, output.destination.name})
                   :ok
                 end
               )

      assert_receive {:delivered, "reviews"}

      assert_receive {:reflection_callback,
                      %{
                        invocation_id: "success-invocation",
                        artefact: ^artefact,
                        outcome: :delivered
                      }}
    end
  end

  describe "when a valid named Reflection submission is admitted" do
    test "then callback, invocation identifier, operator identifier, and Reflection existence are validated before work starts" do
      start_runtime(reflection_configuration())

      assert {:error, {:invalid_invocation_callback, :invalid}} =
               Runtime.submit_reflection(self(), "review", invocation("valid"), :invalid, [])

      assert {:error, {:invalid_operator_id, nil}} =
               Runtime.submit_reflection(self(), "review", %{id: "missing-operator"}, fn _ -> :ok end, [])

      assert {:error, {:unknown_definition, :reflections, "missing"}} =
               Runtime.submit_reflection(self(), "missing", invocation("unknown"), fn _ -> :ok end, [])
    end

    test "and submission returns the invocation identifier without waiting for production" do
      start_runtime(reflection_configuration())
      parent = self()

      assert {:ok, "admitted"} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("admitted"),
                 fn result -> send(parent, {:callback, result}) end,
                 run_reflection: fn _reflection, _invocation, _opts ->
                   send(parent, :ran)
                   {:ok, Gralkor.Artefact.new("admitted", %{})}
                 end,
                 deliver_artefact: fn _output, _reflection, _operator, _artefact, _opts -> :ok
               )

      assert_receive :ran
      assert_receive {:callback, %{invocation_id: "admitted"}}
    end
  end

  describe "if Reflection production reports a retryable server failure" do
    test "while a retry succeeds before twenty-four hours then delivery proceeds and the callback receives the terminal outcome" do
      start_runtime(reflection_configuration())
      parent = self()
      attempts = Agent.start_link(fn -> 0 end) |> elem(1)

      assert {:ok, _} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("retry-success"),
                 fn result -> send(parent, {:callback, result}) end,
                 run_reflection: fn _reflection, _invocation, _opts ->
                   attempt = Agent.get_and_update(attempts, fn n -> {n + 1, n + 1} end)
                   if attempt == 1, do: {:error, %{status: 503}}, else: {:ok, Gralkor.Artefact.new("retry", %{})}
                 end,
                 deliver_artefact: fn _output, _reflection, _operator, _artefact, _opts -> :ok,
                 sleep: fn _delay -> :ok
               )

      assert_receive {:callback, %{outcome: :delivered}}
      assert Agent.get(attempts, & &1) == 2
    end
  end

  describe "if Reflection production fails without a retryable server or non-retryable client status" do
    test "then no Destination output is attempted and the callback receives the production failure" do
      start_runtime(reflection_configuration())
      test_pid = self()

      assert {:ok, _} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("production-failure"),
                 &send(test_pid, {:reflection_callback, &1}),
                 run_reflection: fn _reflection, _invocation, _opts -> {:error, :bad_output} end,
                 deliver_artefact: fn _output, _reflection, _operator, _artefact, _opts ->
                   send(test_pid, :unexpected_delivery)
                   :ok
                 end
               )

      assert_receive {:reflection_callback, %{outcome: {:production_failed, :bad_output}}}
      refute_receive :unexpected_delivery
    end
  end

  describe "if Destination delivery reports a non-retryable client failure" do
    test "then no retry or error artefact is written and the callback receives abandonment with the produced artefact" do
      start_runtime(reflection_configuration())
      test_pid = self()
      artefact = Gralkor.Artefact.new("client-failure", %{})

      assert {:ok, _} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("client-failure"),
                 &send(test_pid, {:reflection_callback, &1}),
                 run_reflection: fn _reflection, _invocation, _opts -> {:ok, artefact} end,
                 deliver_artefact: fn _output, _reflection, _operator, ^artefact, _opts ->
                   send(test_pid, :delivery_attempt)
                   {:error, %{status: 400, reason: :invalid}}
                 end
               )

      assert_receive :delivery_attempt

      assert_receive {:reflection_callback,
                      %{artefact: ^artefact, outcome: {:abandoned, %{stage: :delivery}}}}

      refute_receive :delivery_attempt
    end
  end

  describe "when the owning runtime terminates during unfinished Reflection work" do
    test "then the unfinished work terminates with that runtime and its invocation callback is not invoked" do
      start_runtime(reflection_configuration())
      runtime = :global.whereis_name({Runtime, self()})
      test_pid = self()

      assert {:ok, _} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("cancelled"),
                 &send(test_pid, {:reflection_callback, &1}),
                 run_reflection: fn _reflection, _invocation, _opts ->
                   receive do
                     :never -> {:ok, Gralkor.Artefact.new("never", %{})}
                   end
                 end
               )

      Process.exit(runtime, :kill)
      refute_receive {:reflection_callback, _}, 100
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

  defp lens_configuration do
    %{
      name: "custom",
      write: :append,
      destination: "reviews",
      ingestion: Gralkor.Lens.Ingestion.Store
    }
  end

  defp invocation(id) do
    %{id: id, operator_id: "operator-one", invocation_context: %{}, representations: []}
  end
end
