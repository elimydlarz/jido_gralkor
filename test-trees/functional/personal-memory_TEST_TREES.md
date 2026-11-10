Functional: personal-memory (src: lib/gralkor/client.ex, lib/gralkor/client/native.ex; functional: test/functional/personal_memory_functional_test.exs)

when an application adds memory directly to an operator's personal graph without selecting a Lens
  then the graph named `personal/<operator id>` receives the conversation
  and jido_gralkor's built-in ontology governs extraction
  and public search returns the conversation without Lens or Reflection authorship
  and no packaged Lens ingestion process runs

when an application selects the packaged personal-chat Lens
  then its Store ingestion process writes to that operator's personal Destination
  and its built-in ontology applies to conversation and other supported source kinds
  and its stored episode identifies personal-chat as the originating Lens
  and no additional direct write occurs

when direct memory addition and a genuine consumer Lens target personal memory for the same operator
  then both routes use the same personal graph
  and each write retains its actual originating route

if an application selects the retired operator Lens or Destination
  then the request fails with an explicit migration error before graph access

if an application retains the removed deployment-wide `:jido_gralkor, :ontology` setting
  then personal-chat still uses jido_gralkor's built-in ontology
