Unit: memory-build-indices-action (src: lib/jido_gralkor/actions/memory_build_indices.ex; unit: test/jido_gralkor/actions/memory_build_indices_test.exs)

when a model reads the build-indices tool's description
  then it is told not to call the tool unless the operator explicitly asks

when the build-indices tool runs
  then the backend is asked to build indices once, unscoped to any operator
  while the backend reports a status
    then the action result reports success carrying that status
  if the backend fails
    then the failure reason is returned to the caller unchanged
