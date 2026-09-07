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
                   send(test_pid, {:production_started, self()})

                   receive do
                     :release -> {:ok, Gralkor.Artefact.new("async", %{})}
                   end
                 end,
                 deliver_artefact: fn _output, _reflection, _operator, _artefact, _opts ->
                   :ok
                 end
               )

      assert_receive {:production_started, worker}
      refute_receive {:reflection_callback, _}
      send(worker, :release)
      assert_receive {:reflection_callback, %{outcome: :delivered}}
    end
  end

  describe "when a consumer replaces complete valid configuration" do
    test "then every definition is validated and resolved before activation" do
      start_runtime(reflection_configuration())
      replacement = replacement_configuration("new")

      assert :ok = Runtime.replace(self(), replacement)
      assert Runtime.snapshot(self()) == replacement
      assert Runtime.destination!(self(), "new").name == "new"
    end

    test "and the complete configuration becomes active as one snapshot" do
      start_runtime(reflection_configuration())
      replacement = replacement_configuration("new")
      assert :ok = Runtime.replace(self(), replacement)
      assert Runtime.snapshot(self()) == replacement
    end

    test "and package-owned definitions remain active" do
      start_runtime(reflection_configuration())
      assert :ok = Runtime.replace(self(), replacement_configuration("new"))
      assert Runtime.destination!(self(), "operator").name == "operator"
      assert Runtime.reflection!(self(), "generalisations").name == "generalisations"
    end

    test "and replacement returns only after the new snapshot is active" do
      start_runtime(reflection_configuration())
      replacement = replacement_configuration("new")

      assert :ok = Runtime.replace(self(), replacement)
      assert Runtime.destination!(self(), "new").name == "new"
    end

    test "and another owner's runtime remains unchanged" do
      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      start_supervised!(
        {Runtime,
         owner: owner,
         configuration: reflection_configuration(),
         packaged_reflections: fn -> [packaged_reflection()] end,
         parse_chain_of_thought: fn _ -> {:ok, %Gralkor.Reflection.ChainOfThought{steps: []}} end},
        id: :other_runtime
      )

      start_runtime(reflection_configuration())

      assert :ok = Runtime.replace(self(), replacement_configuration("new"))
      assert Runtime.destination!(owner, "reviews").name == "reviews"
      send(owner, :stop)
    end
  end

  describe "if replacement configuration is invalid" do
    test "then replacement returns the validation error" do
      configuration = reflection_configuration()
      start_runtime(configuration)

      assert {:error, {:missing_collection, :lenses}} =
               Runtime.replace(self(), Map.delete(configuration, :lenses))
    end

    test "and the previously active snapshot remains unchanged" do
      configuration = reflection_configuration()
      start_runtime(configuration)

      assert {:error, {:missing_collection, :lenses}} =
               Runtime.replace(self(), Map.delete(configuration, :lenses))

      assert Runtime.snapshot(self()) == configuration
    end
  end

  describe "when search definitions are resolved from an active runtime > while no Destination names are supplied" do
    test "then every accessible Destination and every selected Lens resolve from one snapshot" do
      configuration = %{reflection_configuration() | lenses: [lens_configuration()]}
      start_runtime(configuration)

      assert {lenses, destinations} = Runtime.resolve_search!(self(), ["custom"], [])
      assert Enum.map(lenses, & &1.name) == ["custom"]
      assert Enum.map(destinations, & &1.name) == ["operator", "global", "reviews"]
    end
  end

  describe "when search definitions are resolved from an active runtime > while Destination and Lens names are supplied" do
    test "then those definitions resolve from one snapshot in first-selected order without duplicates" do
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
  end

  describe "when search definitions are resolved from an active runtime > if any selected name is unknown" do
    test "then resolution fails without returning a partial result" do
      start_runtime(reflection_configuration())

      assert_raise ArgumentError, ~r/unknown_definition/, fn ->
        Runtime.resolve_search!(self(), [], ["missing"])
      end
    end
  end

  describe "when search definitions are resolved from an active runtime" do
    test "and later replacement does not mutate the returned definitions" do
      start_runtime(reflection_configuration())
      original = Runtime.destination!(self(), "reviews")
      assert :ok = Runtime.replace(self(), replacement_configuration("new"))
      assert original.name == "reviews"
      assert Runtime.destination!(self(), "new").name == "new"
    end
  end

  describe "when Reflection production and Destination delivery succeed" do
    test "then the artefact is written once through the declared Destination output" do
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

    test "and the callback receives the invocation identifier, artefact, and delivered outcome" do
      start_runtime(reflection_configuration())
      test_pid = self()
      artefact = Gralkor.Artefact.new("success", %{})

      assert {:ok, "success-callback"} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("success-callback"),
                 &send(test_pid, {:reflection_callback, &1}),
                 run_reflection: fn _reflection, _invocation, _opts -> {:ok, artefact} end,
                 deliver_artefact: fn _output, _reflection, _operator, ^artefact, _opts -> :ok end
               )

      assert_receive {:reflection_callback,
                      %{
                        invocation_id: "success-callback",
                        artefact: ^artefact,
                        outcome: :delivered
                      }}
    end
  end

  describe "when a valid named Reflection submission is admitted" do
    test "then callback, invocation identifier, operator identifier, and Reflection existence are validated before work starts" do
      start_runtime(reflection_configuration())
      parent = self()

      assert {:ok, "valid"} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("valid"),
                 fn result -> send(parent, {:callback, result}) end,
                 run_reflection: fn reflection, %{id: "valid", operator_id: "operator-one"}, _opts ->
                   send(parent, {:producer, reflection.name})
                   {:ok, Gralkor.Artefact.new("valid", %{})}
                 end,
                 deliver_artefact: fn _output, "review", "operator-one", _artefact, _opts -> :ok end
               )

      assert_receive {:producer, "review"}
      assert_receive {:callback, %{invocation_id: "valid", outcome: :delivered}}
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
                   send(parent, {:ran, self()})

                   receive do
                     :release -> {:ok, Gralkor.Artefact.new("admitted", %{})}
                   end
                 end,
                 deliver_artefact: fn _output, _reflection, _operator, _artefact, _opts ->
                   :ok
                 end
               )

      assert_receive {:ran, worker}
      refute_receive {:callback, _}
      send(worker, :release)
      assert_receive {:callback, %{invocation_id: "admitted"}}
    end

    test "and the work retains the Reflection definition active at admission" do
      start_runtime(reflection_configuration())
      parent = self()

      assert {:ok, "retained"} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("retained"),
                 &send(parent, {:callback, &1}),
                 run_reflection: fn reflection, _invocation, _opts ->
                   destination =
                     reflection.outputs |> hd() |> Map.fetch!(:destination) |> Map.fetch!(:name)

                   send(parent, {:reflection, destination, self()})

                   receive do
                     :release -> {:ok, Gralkor.Artefact.new("retained", %{})}
                   end
                 end,
                 deliver_artefact: fn output, _reflection, _operator, _artefact, _opts ->
                   send(parent, {:delivered_destination, output.destination.name})
                   :ok
                 end
               )

      assert_receive {:reflection, "reviews", worker}
      assert :ok = Runtime.replace(self(), replacement_configuration("new"))
      send(worker, :release)
      assert_receive {:delivered_destination, "reviews"}
      assert_receive {:callback, %{outcome: :delivered}}
    end

    test "and later submission uses a subsequently installed definition" do
      start_runtime(reflection_configuration())
      assert :ok = Runtime.replace(self(), replacement_configuration("new"))

      parent = self()

      assert {:ok, "later"} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("later"),
                 &send(parent, {:callback, &1}),
                 run_reflection: fn reflection, _invocation, _opts ->
                   destination =
                     reflection.outputs |> hd() |> Map.fetch!(:destination) |> Map.fetch!(:name)

                   send(parent, {:reflection, destination})
                   {:error, :stop}
                 end
               )

      assert_receive {:reflection, "new"}
    end
  end

  describe "if the callback is invalid, an invocation or operator identifier is missing or blank, or the Reflection is unknown" do
    test "then submission returns the identified failure before production starts" do
      start_runtime(reflection_configuration())

      assert {:error, {:invalid_invocation_callback, :invalid}} =
               Runtime.submit_reflection(self(), "review", invocation("bad"), :invalid, [])
    end
  end

  describe "if Reflection production reports a retryable server failure" do
    test "then production retries with exponential backoff" do
      start_runtime(reflection_configuration())
      parent = self()
      attempts = Agent.start_link(fn -> 0 end) |> elem(1)
      sleeps = Agent.start_link(fn -> [] end) |> elem(1)

      assert {:ok, _} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("retry-success"),
                 fn result -> send(parent, {:callback, result}) end,
                 run_reflection: fn _reflection, _invocation, _opts ->
                   attempt = Agent.get_and_update(attempts, fn n -> {n + 1, n + 1} end)

                   if attempt <= 2,
                     do: {:error, %{status: 503}},
                     else: {:ok, Gralkor.Artefact.new("retry", %{})}
                 end,
                 deliver_artefact: fn _output, _reflection, _operator, _artefact, _opts ->
                   :ok
                 end,
                 sleep: fn delay -> Agent.update(sleeps, &[delay | &1]) end
               )

      assert_receive {:callback, %{outcome: :delivered}}
      assert Agent.get(attempts, & &1) == 3
      assert Agent.get(sleeps, &Enum.reverse/1) == [1_000, 2_000]
    end
  end

  describe "if Reflection production reports a retryable server failure > while a retry succeeds before twenty-four hours" do
    test "then delivery proceeds and the callback receives the terminal outcome" do
      start_runtime(reflection_configuration())
      parent = self()
      attempts = start_supervised!({Agent, fn -> 0 end})

      assert {:ok, _} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("retry-terminal"),
                 &send(parent, {:callback, &1}),
                 run_reflection: fn _r, _i, _o ->
                   attempt = Agent.get_and_update(attempts, fn n -> {n + 1, n + 1} end)

                   if attempt == 1,
                     do: {:error, %{status: 503}},
                     else: {:ok, Gralkor.Artefact.new("terminal", %{})}
                 end,
                 sleep: fn _ -> :ok end,
                 deliver_artefact: fn _o, _r, _op, _a, _opts -> :ok end
               )

      assert_receive {:callback, %{outcome: :delivered}}
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

  describe "if Reflection production reports a non-retryable client failure" do
    test "then it is not retried or delivered and the callback receives immediate production abandonment" do
      start_runtime(reflection_configuration())
      parent = self()

      assert {:ok, _} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("production-client"),
                 &send(parent, {:callback, &1}),
                 run_reflection: fn _reflection, _invocation, _opts ->
                   {:error, %{status: 400, reason: :invalid}}
                 end,
                 deliver_artefact: fn _output, _reflection, _operator, _artefact, _opts ->
                   send(parent, :unexpected_delivery)
                   :ok
                 end
               )

      assert_receive {:callback,
                      %{outcome: {:abandoned, %{stage: :production, reason: %{status: 400}}}}}

      refute_receive :unexpected_delivery
    end
  end

  describe "if Reflection production reports a retryable server failure > while no retry succeeds within twenty-four hours" do
    test "then production is abandoned without another attempt and the callback receives abandonment" do
      start_runtime(reflection_configuration())
      parent = self()
      clock = start_supervised!({Agent, fn -> 0 end})

      assert {:ok, _} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("production-deadline"),
                 &send(parent, {:callback, &1}),
                 run_reflection: fn _reflection, _invocation, _opts ->
                   send(parent, :production_attempt)
                   {:error, %{status: 503}}
                 end,
                 clock: fn -> Agent.get(clock, & &1) end,
                 sleep: fn _delay -> Agent.update(clock, &(&1 + 86_400_000)) end
               )

      assert_receive :production_attempt
      assert_receive {:callback, %{outcome: {:abandoned, %{stage: :production}}}}
      refute_receive :production_attempt
    end
  end

  describe "if Destination delivery reports a retryable server failure" do
    test "then delivery retries the same artefact with exponential backoff" do
      start_runtime(reflection_configuration())
      parent = self()
      attempts = start_supervised!({Agent, fn -> 0 end})
      sleeps = start_supervised!({Agent, fn -> [] end}, id: :delivery_retry_sleeps)
      artefact = Gralkor.Artefact.new("delivery-retry", %{})

      assert {:ok, _} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("delivery-retry"),
                 &send(parent, {:callback, &1}),
                 run_reflection: fn _reflection, _invocation, _opts -> {:ok, artefact} end,
                 deliver_artefact: fn _output, _reflection, _operator, ^artefact, _opts ->
                   attempt = Agent.get_and_update(attempts, fn n -> {n + 1, n + 1} end)
                   if attempt <= 2, do: {:error, %{status: 503}}, else: :ok
                 end,
                 sleep: fn delay -> Agent.update(sleeps, &[delay | &1]) end
               )

      assert_receive {:callback, %{artefact: ^artefact, outcome: :delivered}}
      assert Agent.get(attempts, & &1) == 3
      assert Agent.get(sleeps, &Enum.reverse/1) == [1_000, 2_000]
    end
  end

  describe "if Destination delivery reports a retryable server failure > while a retry succeeds before twenty-four hours" do
    test "then the callback receives the delivered outcome" do
      start_runtime(reflection_configuration())
      parent = self()

      assert {:ok, _} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("delivery-terminal"),
                 &send(parent, {:callback, &1}),
                 run_reflection: fn _r, _i, _o -> {:ok, Gralkor.Artefact.new("terminal", %{})} end,
                 deliver_artefact: fn _o, _r, _op, _a, _opts -> :ok end
               )

      assert_receive {:callback, %{outcome: :delivered}}
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
    test "then the unfinished work terminates with that runtime" do
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
                   send(test_pid, {:work_started, self()})

                   receive do
                     :never -> {:ok, Gralkor.Artefact.new("never", %{})}
                   end
                 end
               )

      assert_receive {:work_started, worker}
      monitor_ref = Process.monitor(worker)
      Process.exit(runtime, :kill)
      assert_receive {:DOWN, ^monitor_ref, :process, ^worker, _reason}
    end

    test "and its invocation callback is not invoked" do
      start_runtime(reflection_configuration())
      runtime = :global.whereis_name({Runtime, self()})
      test_pid = self()

      assert {:ok, _} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("cancelled-callback"),
                 &send(test_pid, {:reflection_callback, &1}),
                 run_reflection: fn _reflection, _invocation, _opts ->
                   send(test_pid, {:work_started, self()})

                   receive do
                     :never -> {:ok, Gralkor.Artefact.new("never", %{})}
                   end
                 end
               )

      assert_receive {:work_started, worker}
      monitor_ref = Process.monitor(worker)
      Process.exit(runtime, :kill)
      assert_receive {:DOWN, ^monitor_ref, :process, ^worker, _reason}
      refute_receive {:reflection_callback, _}, 100
    end
  end

  describe "when a runtime-targeted call receives a live owning AgentServer PID" do
    test "then the runtime registered for that owner receives the call" do
      start_runtime(reflection_configuration())

      assert Runtime.ensure_available!(self()) == self()
      assert Runtime.destination!(self(), "reviews").name == "reviews"
    end
  end

  describe "when a runtime-targeted call receives a live owning AgentServer PID > while runtime registration is not yet visible" do
    test "then target lookup synchronizes once with the owner before deciding availability" do
      owner = start_supervised!({RuntimeSyncOwner, self()})

      assert_raise ArgumentError, ~r/runtime unavailable for owning AgentServer/, fn ->
        Runtime.ensure_available!(owner)
      end

      assert_receive {:state_sync, ^owner}
      refute_receive {:state_sync, ^owner}
    end
  end

  describe "if a runtime target is not an owning AgentServer PID" do
    test "then target lookup raises an argument error identifying the invalid target" do
      assert_raise ArgumentError, ~r/must be an owning AgentServer PID/, fn ->
        Runtime.ensure_available!(:not_a_pid)
      end
    end
  end

  describe "if no runtime is available after owner synchronization or the runtime call exits" do
    test "then target lookup raises an argument error identifying the unavailable runtime" do
      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert_raise ArgumentError, ~r/runtime unavailable for owning AgentServer/, fn ->
        Runtime.destination!(owner, "reviews")
      end

      send(owner, :stop)
    end
  end

  describe "when independently submitted Reflection invocations run" do
    test "then each invocation progresses without waiting for another invocation" do
      start_runtime(reflection_configuration())
      parent = self()

      run_reflection = fn _reflection, invocation, _opts ->
        case invocation.id do
          "one" ->
            send(parent, {:blocked, self()})

            receive do
              :release -> {:ok, Gralkor.Artefact.new(invocation.id, %{})}
            end

          "two" ->
            send(parent, :second_started)
            {:ok, Gralkor.Artefact.new(invocation.id, %{})}
        end
      end

      deliver_artefact = fn _output, _reflection, _operator, _artefact, _opts -> :ok end

      assert {:ok, "one"} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("one"),
                 &send(parent, {:callback, &1}),
                 run_reflection: run_reflection,
                 deliver_artefact: deliver_artefact
               )

      assert {:ok, "two"} =
               Runtime.submit_reflection(
                 self(),
                 "review",
                 invocation("two"),
                 &send(parent, {:callback, &1}),
                 run_reflection: run_reflection,
                 deliver_artefact: deliver_artefact
               )

      assert_receive {:blocked, first_worker}
      assert_receive :second_started
      assert_receive {:callback, %{invocation_id: "two"}}
      refute_receive {:callback, %{invocation_id: "one"}}
      send(first_worker, :release)
      assert_receive {:callback, %{invocation_id: "one"}}
    end
  end

  defp start_runtime(configuration) do
    start_supervised!(
      {Runtime,
       owner: self(),
       configuration: configuration,
       packaged_reflections: fn -> [packaged_reflection()] end,
       parse_chain_of_thought: fn _configuration ->
         {:ok, %Gralkor.Reflection.ChainOfThought{steps: []}}
       end}
    )
  end

  defp packaged_reflection do
    %{
      name: "generalisations",
      outputs: [%{kind: :destination, destination: "global"}],
      chain_of_thought: %{steps: []}
    }
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

  defp replacement_configuration(destination) do
    configuration = reflection_configuration()

    reflection =
      put_in(hd(configuration.reflections), [:outputs, Access.at(0), :destination], destination)

    %{
      configuration
      | destinations: [%{name: destination}],
        reflections: [reflection]
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

defmodule RuntimeSyncOwner do
  use GenServer

  def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

  @impl GenServer
  def init(test_pid), do: {:ok, test_pid}

  @impl GenServer
  def handle_call(:get_state, _from, test_pid) do
    send(test_pid, {:state_sync, self()})
    {:reply, {:error, :not_registered}, test_pid}
  end
end
