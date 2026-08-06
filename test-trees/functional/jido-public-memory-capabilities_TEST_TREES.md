Functional: jido-public-memory-capabilities (src: lib/jido_gralkor/lifecycle.ex, lib/jido_gralkor/actions/memory_build_indices.ex, lib/jido_gralkor/actions/memory_build_communities.ex, lib/jido_gralkor/actions/memory_search.ex, lib/jido_gralkor/re_act.ex; functional: test/functional/jido_public_memory_capabilities_functional_test.exs)

when an application gracefully stops an agent with a committed thread
  then the configured memory client flushes that thread without delaying termination

when an operator runs the build-indices memory action
  then the action reports the backend status after one unscoped index build
  and a backend failure is returned unchanged

when an operator runs the build-communities memory action
  then the action reports the backend counts after one build for the operator's sanitised group
  and a backend failure is returned unchanged

if an agent invokes memory search without a usable query
  then no backend is queried and the agent receives an explicit non-result

if an agent invokes memory search without a committed session
  then no backend is queried and the agent receives an explicit non-result

when a consumer prepares the first ReAct iteration
  then memory search is forced while every existing request override is preserved

when a consumer prepares a later ReAct iteration
  then every request override is returned unchanged
