Unit: memory-search-presentation (src: lib/jido_gralkor/memory_search_presentation.ex; unit: test/jido_gralkor/memory_search_presentation_test.exs)

when memory results are selected for a model byte budget
  then an exact-fit complete success envelope retains the unchanged result
  and UTF-8 bytes and JSON escaping count towards the budget
  and an oversized result is omitted whole while later fitting results retain their order
  and omission metadata counts every excluded result outside the result list
  while the result list is empty
    then the minimum budget returns an empty result list with zero omissions
  while the budget cannot contain the empty envelope and its omission count
    then an explicit error reports the required minimum bytes
  if the budget is not a positive integer
    then an argument error identifies the invalid budget

when the action validates a model byte budget before search
  then a positive integer is returned unchanged
  if the budget is not a positive integer
    then an argument error identifies the invalid budget
