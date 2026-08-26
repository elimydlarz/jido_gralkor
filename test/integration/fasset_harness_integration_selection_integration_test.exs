defmodule FassetHarnessIntegrationSelectionIntegrationTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  test "when the Integration selection probe exists then test fast selects it directly" do
    assert :selected == :selected
  end
end
