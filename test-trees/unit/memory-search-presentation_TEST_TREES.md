Unit: memory-search-presentation (src: lib/jido_gralkor/memory_search_presentation.ex; unit: test/jido_gralkor/memory_search_presentation_test.exs)

when the memory search formatter is called
  then every memory is one line of plain text under the heading of its writer
  and whole Reflection artefacts come first, then facts, then episodes
  and headings keep first-appearance order with retrieval order inside each heading
  and the same text appears once under one heading
  and entities come last under an `Entities` heading
  and nothing is labelled as a fact, an episode, or an artefact
  and the formatter adds no Destination, artefact identifier, level, or lineage metadata
  and the structured input remains unchanged
  while no memories are supplied
    then the text explicitly states that no matching memory was found

when the formatter names a writer
  then a Lens uses a `Lens: <name>` heading
  and a Reflection uses a `Reflection: <name>` heading
  and known direct provenance identifies its source kind
  and unnamed provenance uses `Source: unknown`

when the formatter presents facts
  then each fact is one bullet with its complete text
  and repeated provenance for one source adds no duplicate bullet for that fact
  and a fact with several named sources appears under each distinct source
  while a fact has an invalidation date
    then its bullet ends with `(invalidated at <date>)`
  while a fact has only an expiry date
    then its bullet ends with `(invalidated at <date>)`

when the formatter presents entities
  then each entity is one bullet with its complete name, summary, and attributes

when the formatter presents a Reflection artefact
  then its payload is presented whole as readable text
  and each item of a top-level list is its own bullet
  and an object with a `content` string presents only that text
  and an object with one field presents only that field's value
  and any other object presents `key: value` pairs separated by semicolons
  and an empty payload presents nothing

when the formatter presents episodes
  then an episode's text is presented whole on one line
  and a structured-record episode is presented as readable text the same way as a Reflection artefact
  and a structured-record episode whose content is not JSON keeps its text

when one memory is longer than 4,000 characters
  then it is cut to 4,000 characters and marked as truncated
  and a memory of exactly 4,000 characters is not cut
  and an invalidated fact keeps its invalidation date

when formatted results must fit response limits
  then an exact-fit response retains every memory
  and headings and omission notices count towards the 16384-character ceiling
  and UTF-8 bytes and JSON escaping count towards the complete-envelope byte budget
  and a bullet that exceeds either limit is omitted whole while later fitting bullets remain eligible
  and the omission notice gives the total omitted, each fact once regardless of its source count
  while the budget cannot contain the empty response and required notice
    then an explicit error reports the required minimum bytes
  if the byte budget is not a positive integer
    then an argument error identifies the invalid budget

when the action validates a model byte budget before search
  then a positive integer is returned unchanged
  if the budget is not a positive integer
    then an argument error identifies the invalid budget
