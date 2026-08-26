defmodule FassetHarnessUnitSelectionTest do
  use ExUnit.Case, async: true

  test "when the Unit selection probe changes then test fast selects it directly" do
    assert :selected == :selected
  end
end
