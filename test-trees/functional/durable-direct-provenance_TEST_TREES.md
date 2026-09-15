Functional: durable-direct-provenance (src: lib/gralkor/graphiti_pool.ex, lib/gralkor/destination/storage/graphiti.ex, lib/gralkor/client/native.ex; functional: test/functional/durable_direct_provenance_functional_test.exs)

when direct memory is stored in a real graph
  then ordinary direct writes retain durable writer metadata through public episode and fact search
  and deterministic direct writes retain durable writer metadata through public episode and fact search
  and historical marker-like text without durable metadata stays unchanged and unclassified
