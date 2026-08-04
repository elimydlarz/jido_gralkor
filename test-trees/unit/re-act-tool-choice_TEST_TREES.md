Unit: re-act-tool-choice (src: lib/jido_gralkor/re_act.ex; unit: test/jido_gralkor/re_act_test.exs)

when request-transformer overrides are folded on the first ReAct iteration
  while the overrides already carry llm options
    then a tool choice pinning the memory search function is folded into those llm options
    and the llm options the consumer already set survive alongside it
    and the other override keys are returned unchanged
  while the overrides carry no llm options
    then llm options are added holding only the tool choice pinning the memory search function

when request-transformer overrides are folded on any later ReAct iteration
  then the overrides are returned unchanged, leaving the model free to answer or call other tools
