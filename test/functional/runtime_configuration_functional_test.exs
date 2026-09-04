defmodule Gralkor.RuntimeConfigurationFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  defmodule ConsumerAgent do
    use Jido.Agent,
      name: "runtime_configuration_consumer",
      default_plugins: false,
      plugins: [
        {JidoGralkor.Plugin,
         %{
           agent_name: "Runtime Configuration Consumer",
           runtime_config: %{
             destinations: [],
             lenses: [],
             reflections: []
           }
         }}
      ]
  end

  defmodule ConsumerOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open
  end

  describe "when a consumer starts a Jido agent with the Gralkor plugin" do
    test "then the plugin starts one Gralkor runtime under that agent" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-consumer",
           register_global: false}
        )

      assert {:ok, state} = Jido.AgentServer.state(agent_server)

      assert %{
               {:plugin, JidoGralkor.Plugin, JidoGralkor.Runtime} => %{
                 pid: runtime
               }
             } = state.children

      assert Process.alive?(runtime)
    end

    test "and that runtime owns the agent's runtime configuration" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-owner",
           register_global: false}
        )

      assert %{
               destinations: [],
               lenses: [],
               reflections: []
             } = JidoGralkor.Runtime.snapshot(agent_server)
    end
  end

  describe "when a consumer replaces one agent's runtime configuration with complete valid Destination, Lens, and Reflection collections" do
    test "then the complete consumer configuration becomes active as one snapshot for that agent" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-replacement",
           register_global: false}
        )

      configuration = %{
        destinations: [%{name: "project"}],
        lenses: [
          %{
            name: "observations",
            destination: "project",
            write: :append,
            ingestion: Gralkor.Lens.Ingestion.Store,
            ontology: ConsumerOntology
          }
        ],
        reflections: [
          %{
            name: "review",
            outputs: [
              %{
                kind: :destination,
                destination: "project",
                ontology: ConsumerOntology
              }
            ],
            chain_of_thought: %{
              steps: [
                %{
                  label: "review",
                  directions: "Review the supplied evidence.",
                  output: %{"summary" => "string"}
                }
              ]
            }
          }
        ]
      }

      assert :ok = JidoGralkor.Runtime.replace(agent_server, configuration)
      assert configuration == JidoGralkor.Runtime.snapshot(agent_server)
    end
  end

  describe "if a replacement is invalid" do
    test "then the call returns the validation failure" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-invalid-replacement",
           register_global: false}
        )

      assert {:error, {:invalid_collection, :destinations, :not_a_list}} =
               JidoGralkor.Runtime.replace(agent_server, %{
                 destinations: :not_a_list,
                 lenses: [],
                 reflections: []
               })
    end
  end
end
