defmodule JidoGralkor.PublishSkillTest do
  use ExUnit.Case, async: true

  @skill Path.expand("../../.agents/skills/publish/SKILL.md", __DIR__)
  @openai_yaml Path.expand("../../.agents/skills/publish/agents/openai.yaml", __DIR__)
  @env_example Path.expand("../../.env.example", __DIR__)

  describe "when an operator asks to publish jido_gralkor with a semantic-version change kind" do
    test "then the semantic-version change kind is the only required operator input" do
      skill = File.read!(@skill)
      openai_yaml = File.read!(@openai_yaml)

      assert skill =~ "Require exactly `<major|minor|patch>` from the operator's request."
      assert openai_yaml =~
               ~s(default_prompt: "Use $publish patch to publish the next jido_gralkor release.")
    end
  end
end
