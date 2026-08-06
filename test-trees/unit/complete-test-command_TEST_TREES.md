Unit: complete-test-command (src: mix.exs; unit: test/complete_test_command_test.mjs)

when a maintainer asks Mix to run all tests
  then `mix test.all` runs all Unit, Integration, Functional, Journey, and publish-skill contract tests
  if the ExUnit suite fails
    then the Node contract tests still run
    and the complete command fails
  if the Node contract tests fail
    then the complete command fails
  if both test runners pass
    then the complete command succeeds
