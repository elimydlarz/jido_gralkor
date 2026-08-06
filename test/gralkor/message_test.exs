defmodule Gralkor.MessageTest do
  use ExUnit.Case, async: true

  alias Gralkor.Message

  describe "when a canonical message is built from a role and content" do
    test "then it carries that role and that content unchanged" do
      message = Message.new("user", "hello there")

      assert message.role == "user"
      assert message.content == "hello there"
    end
  end

  describe "when a canonical message is built from a role and content > where the role is `user`, `assistant`, or `behaviour`" do
    test "then the message is built, those being the three roles Gralkor branches on" do
      for role <- ~w(user assistant behaviour) do
        assert %Message{role: ^role, content: "content"} = Message.new(role, "content")
      end
    end
  end

  describe "when a canonical message is built from a role and content > if the role is anything else" do
    test "then no message is built, an adapter having to collapse its harness's activity into one of the three first" do
      assert_raise FunctionClauseError, fn -> Message.new("system", "content") end
    end
  end

  describe "when a canonical message is built from a role and content > if the content is not a string" do
    test "then no message is built" do
      assert_raise FunctionClauseError, fn -> Message.new("user", :not_a_string) end
    end
  end
end
