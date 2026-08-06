Unit: complete-test-command (src: mix.exs; unit: test/complete_test_command_test.mjs)

when a maintainer asks Mix to run the complete test suite
  then `mix test.all` runs Unit, Integration, Functional, and Journey coverage in one ExUnit virtual machine
  and the publish-skill contract runs after ExUnit succeeds
  and every stage runs even when another stage fails, so the output contains all test failures
  and the completion gate fails after every stage finishes if any stage failed
