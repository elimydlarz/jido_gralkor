Unit: memory-build-communities-action (src: lib/jido_gralkor/actions/memory_build_communities.ex; unit: test/jido_gralkor/actions/memory_build_communities_test.exs)

when a model reads the build-communities tool's description
  then it is told not to call the tool unless the operator explicitly asks

when the build-communities tool runs
  then the operator's sanitised group id from the tool context is passed to the backend
  while the backend reports how many communities and edges it built
    then the action result reports both counts
  if the backend fails
    then the failure reason is returned to the caller unchanged
