Unit: memory-search-presentation (src: lib/jido_gralkor/memory_search_presentation.ex; unit: test/jido_gralkor/memory_search_presentation_test.exs)

when the memory search formatter is called
  then facts from every Destination appear first under a `Facts` heading, then entities under an `Entities` heading, then episodes under an `Episodes` heading
  and a section with nothing to show is left out
  and the formatter adds no Destination, artefact level, or lineage metadata
  and the structured input remains unchanged
  while no facts, entities, or episodes are supplied
    then the text explicitly states that no matching memory was found

when the formatter presents facts
  then Lens groups use `Lens: <name>` headings
  and Reflection groups use `Reflection: <name>` headings
  and each fact is presented as one bullet with its complete text
  and groups retain first-appearance order with retrieval order inside each group
  and repeated provenance for one source adds no duplicate bullet for that fact
  and facts with several named sources appear under each distinct source
  and known direct provenance identifies its source kind without a Lens or Reflection heading
  and unnamed provenance is grouped under `Source: unknown`

when the formatter presents entities
  then each entity is presented as one bullet with its complete name, summary, and attributes

when the formatter presents episodes
  then each episode is presented as one bullet labelled with its originating Lens, Reflection, or source kind
  and an episode's text is cut to a bounded excerpt marked as truncated
  and a Reflection episode is summarised by its artefact identifier and a bounded excerpt of its payload
  and an episode with no named writer is labelled `Source: unknown`

when formatted results must fit response limits
  then an exact-fit response retains every complete fact, entity, and episode bullet
  and headings and omission notices count towards the 16384-character ceiling
  and UTF-8 bytes and JSON escaping count towards the complete-envelope byte budget
  and a bullet that exceeds either limit is omitted whole while later fitting bullets remain eligible
  and the omission notice counts excluded facts, entities, and episodes separately, each fact once regardless of its source count
  while the budget cannot contain the empty response and required notice
    then an explicit error reports the required minimum bytes
  if the byte budget is not a positive integer
    then an argument error identifies the invalid budget

when the action validates a model byte budget before search
  then a positive integer is returned unchanged
  if the budget is not a positive integer
    then an argument error identifies the invalid budget
