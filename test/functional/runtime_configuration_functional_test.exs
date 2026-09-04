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
  end
end
