Unit: memory-search-presentation (src: lib/jido_gralkor/memory_search_presentation.ex; unit: test/jido_gralkor/memory_search_presentation_test.exs)

when the memory search formatter is called
  then every memory is one bullet under the heading of its writer, its first line its main text and each other field on its own indented line
  and whole Reflection artefacts come first, then facts, then episodes
  and headings keep first-appearance order with retrieval order inside each heading
  and the same text appears once under one heading
  and a memory whose whole text is another memory's first line under the same heading is left out beside it
  and entities come last under an `Entities` heading
  and nothing is labelled as a fact, an episode, or an artefact
  and the formatter adds no record metadata such as a Destination, an artefact identifier, or a uuid
  and level and lineage appear only as fields the payload itself carries
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

when the formatter shows when a memory was true and where it came from
  then a fact or episode with a start date ends with `(valid from <date>)`
  and the start date is when it became true, or when it was recorded if that is missing
  and an invalidated or expired fact ends with `(valid from <date> to <date>)`
  and an invalidated fact with no start date ends with `(valid until <date>)`
  and a memory's source descriptions follow its dates, as in `(valid from <date>; source: <description>)`
  and a fact drawn from several episodes lists each distinct source description once
  and a source description never repeats its Lens marker
  and a source description that only names a Reflection is left out
  and a memory with no dates or source description ends with no parentheses

when the formatter presents entities
  then each entity's first line is `name: summary`, or only its name when it has no summary
  and each attribute is its own indented `key: value` line, not an inline bracket
  and entities with different attributes each show all of their own
  and internal `_gralkor` attributes are not shown

when the formatter presents a Reflection artefact
  then its payload is presented whole as readable text
  and each item of a top-level list is its own bullet
  and a payload object with exactly one key is presented as that key's value, once, at the outer level only
  and an object's `content` string is its first line and every other field follows
  and an object without `content` puts its first field on the first line as `key: value`
  and one-line fields come first in alphabetical order, then multi-line fields in alphabetical order
  and a number or boolean is written as it is
  and a list of plain values is one `key: a, b, c` line
  and a list containing an object is a `key:` line followed by one nested bullet per item, laid out the same way
  and a nested object is a `key:` line followed by its own fields two spaces further in
  and a nested object with one field keeps its field name
  and null, empty strings, empty lists, empty objects, and fields containing only those are left out
  and the generalisation, erl, and entity examples render exactly as specified
  and an empty payload presents nothing

when the formatter presents episodes
  then an episode that is not a structured record is presented whole on one line
  and a structured-record episode is presented as readable text the same way as a Reflection artefact
  and a structured-record episode whose content is not JSON keeps its text

when the formatter shows a memory with several lines
  then its date and source suffix ends its first line

when one memory is longer than 4,000 characters
  then it is cut to 4,000 characters and marked as truncated
  and its length counts every line with its indentation and line breaks
  and the truncation marker ends the last line that is kept
  and a memory of exactly 4,000 characters is not cut
  and its dates and source still follow the cut without counting toward it

when formatted results must fit response limits
  then an exact-fit response retains every memory
  and a caller that supplies no byte budget gets the 65,536-byte default that every model-facing presentation shares
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
