Journey: memory-adventure (journey: test/journey/memory_adventure_journey_test.exs)

# Adventure: one operator adds default-ontology direct personal memory, adds a direct conversation, remembers chat transcripts through the personal-chat and an appending Lens without duplicate writes, and publishes global memory.
# Fresh sessions then use default and Destination-selected memory search across packaged and application Destinations; both operators check shared and personal visibility.

when two operators use direct personal memory, Lenses, and asynchronously triggered Reflections
  then default-ontology direct personal memory remains recallable
  and recall presents that memory in the memory search format inside an untrusted memory block
  and a direct conversation remains searchable without Lens or Reflection authorship
  and personal-chat processing records its actual Lens provenance
  and the direct conversation and the personal-chat transcript each write one episode
  and appending-Lens transcript information remains searchable
  and the global graph is visible to both operators
  and each operator's selector-free search returns that operator's personal memory
  and each operator's selector-free search excludes the other operator's personal memory
  and direct memory uses the graph named `personal/<operator id>`
  and appending Lenses use that same graph

when distinct ingestions use Lenses backed by different Destinations
  then the `work-notes` input is searchable through the `personal` Destination
  and the `published` input is searchable through the `global` Destination

when the Journey consumer triggers a consumer-defined Reflection with a Destination output
  then its artefact is searchable through its Destination
  and its invocation callback eventually receives that exact artefact and successful delivery outcome

when a fresh agent handles a request related to stored deployment lessons
  then one MemorySearch call is made without selectors
  and every accessible registered Destination is searched
  and its results include relevant memory from the `personal`, `global`, and an application Destination
  and its readable memory names the originating Lens
  and the answer uses retrieved facts relevant to the requested migration
  and the recommendation applies the retrieved reversible limited-scope lesson to the requested migration

when the agent searches with a Destination selector
  then relevant memory from the selected Destination is returned
  and no memory from an unselected Destination is returned
  and a subsequent selector-free search returns relevant memory from a Destination omitted by the earlier Destination selector

when the Journey consumer searches including one Lens as a writer
  then only episodes written through that Lens are returned
  and no episode written directly, through another Lens, or by a Reflection is returned
  and a subsequent search including no writer returns the memory written directly or through the other Lenses

when the Journey ingests conversation, document, and structured-record episodes
  then every retrieved conversation fact identifies every originating episode
  and every retrieved conversation fact identifies its conversation source kind
  and every retrieved conversation fact identifies its chat-transcript source description
  and every retrieved document fact identifies every originating episode
  and every retrieved document fact identifies its document source kind
  and a retrieved document fact identifies its deployment-policy source description
  and every retrieved structured-record fact identifies every originating episode
  and every retrieved structured-record fact identifies its structured-record source kind
  and every retrieved structured-record fact identifies its dependency-registry source description
