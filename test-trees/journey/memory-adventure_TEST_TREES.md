Journey: memory-adventure (journey: test/journey/memory_adventure_journey_test.exs)

# Adventure: one operator adds default-ontology direct personal memory, captures direct and personal-chat turns without duplicate writes, flushes completed turns through an appending Lens, asynchronously triggers an ERL Learning, evolves a shared generalisation, and publishes global memory.
# The same operator's appending and replaceable Lenses save to one Destination before the replaceable Lens replaces its earlier graph.
# Fresh sessions then use default and Destination-selected memory search across packaged and application Destinations; both operators check shared and personal visibility.

when two operators use direct personal memory, Lenses, asynchronously triggered Reflections, and shared-Destination replacement
  then default-ontology direct personal memory remains recallable
  and direct conversation capture remains searchable without Lens or Reflection authorship
  and personal-chat processing records its actual Lens provenance
  and alternating direct and personal-chat turns writes one episode for each selected route
  and captured appending-Lens information remains searchable
  and ERL writes a structured Learning artefact through its Destination output
  and ERL remains absent from the other operator's personal Destination
  and the global graph is visible to both operators
  and each operator's selector-free search returns that operator's personal memory
  and each operator's selector-free search excludes the other operator's personal memory
  and direct memory uses the graph named `personal/<operator id>`
  and appending Lenses use that same graph
  and replaceable Lenses use that same graph
  and replacing one Lens's graph preserves information written by another Lens
  and fresh retrieval returns the current replacement graph
  and fresh retrieval omits the superseded replacement graph

when the Journey consumer triggers generalisation after successive ingestions containing related observations
  then the first resulting generalisation exposes non-blank content, an integer level, and a lineage list
  and a later resulting generalisation exposes non-blank content, an integer level, and non-empty lineage
  and every later lineage snapshot exposes non-blank content and an integer level

when distinct ingestions use Lenses backed by different Destinations
  then the `work-notes` input is searchable through the `personal` Destination
  and the `published` input is searchable through the `global` Destination
  and each consumer-supplied invocation identifier resolves a completed artefact of the `generalisations` Reflection
  and each completed generalisation artefact is searchable through the `generalisations` Destination by both operators
  and no generalisation artefact is searchable through the `global` Destination

when the Journey consumer triggers a consumer-defined Reflection with a Destination output
  then its artefact is searchable through its Destination
  and its invocation callback eventually receives that exact artefact and successful delivery outcome

when a fresh agent handles a request related to an evolved generalisation
  then one MemorySearch call is made without selectors
  and every accessible registered Destination is searched
  and its results include relevant memory from the `personal`, `global`, and an application Destination
  and its results include relevant Lens-authored memory and relevant stored generalisations
  and its readable fact bullets are grouped under the named originating Lens or Reflection
  and the answer uses retrieved facts relevant to the requested migration
  and the recommendation applies the retrieved reversible limited-scope lesson to the requested migration

when the agent searches with a Destination selector
  then relevant memory from the selected Destination is returned
  and no memory from an unselected Destination is returned
  and a subsequent selector-free search returns relevant memory from a Destination omitted by the earlier Destination selector

when the Journey consumer searches with a Lens selector
  then only episodes written through the selected Lens are returned
  and no episode written directly, through another Lens, or by a Reflection is returned
  and memory written by a replaceable Lens's graph replacement is returned for that Lens
  and a subsequent Lens-free search returns the memory written directly or through the other Lenses

when the Journey ingests conversation, document, and structured-record episodes
  then every retrieved conversation fact identifies every originating episode
  and every retrieved conversation fact identifies its conversation source kind
  and every retrieved conversation fact identifies its captured-turn source description
  and every retrieved document fact identifies every originating episode
  and every retrieved document fact identifies its document source kind
  and a retrieved document fact identifies its deployment-policy source description
  and every retrieved structured-record fact identifies every originating episode
  and every retrieved structured-record fact identifies its structured-record source kind
  and every retrieved structured-record fact identifies its dependency-registry source description
