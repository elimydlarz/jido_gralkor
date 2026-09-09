Unit: memory-search-presentation (src: lib/jido_gralkor/memory_search_presentation.ex; unit: test/jido_gralkor/memory_search_presentation_test.exs)

when structured fact results are formatted for the model
  then Lens groups use `Lens: <name>` headings
  and Reflection groups use `Reflection: <name>` headings
  and each fact is presented as one bullet with its complete text
  and groups retain first-appearance order with retrieval order inside each group
  and repeated provenance for one source adds no duplicate bullet for that fact
  and facts with several named sources appear under each distinct source
  and unnamed provenance is grouped under `Source: unknown`
  and the formatter adds no Destination, artefact, level, or lineage metadata
  and the structured input remains unchanged
  while no facts are supplied
    then the text explicitly states that no matching facts were found

when formatted fact results must fit response limits
  then an exact-fit response retains every complete fact
  and headings and omission notices count towards the 16384-character ceiling
  and UTF-8 bytes and JSON escaping count towards the complete-envelope byte budget
  and a fact that exceeds either limit is omitted whole while later fitting facts remain eligible
  and the omission notice counts excluded input facts once regardless of their source count
  while the budget cannot contain the empty response and required notice
    then an explicit error reports the required minimum bytes
  if the byte budget is not a positive integer
    then an argument error identifies the invalid budget

when the action validates a model byte budget before search
  then a positive integer is returned unchanged
  if the budget is not a positive integer
    then an argument error identifies the invalid budget
