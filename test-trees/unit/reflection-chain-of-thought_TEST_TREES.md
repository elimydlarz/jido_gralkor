Unit: reflection-chain-of-thought (src: lib/gralkor/reflection/chain_of_thought.ex; unit: test/gralkor/reflection/chain_of_thought_test.exs)

when structured Chain of Thought configuration contains one or more ordered steps
  while the configuration and steps use maps
    then parsing returns the steps in declaration order
    and every parsed step retains its label, directions, and structured-output declaration
  while the configuration and steps use keyword lists
    then parsing returns the same structured Chain of Thought

if Chain of Thought configuration has no non-empty steps list
  then parsing reports missing steps

if a Chain of Thought step is not structured configuration
  then parsing identifies that step

if a Chain of Thought step has a missing or blank label
  then parsing identifies the invalid label

if a Chain of Thought step has missing or blank natural-language directions
  then parsing identifies that step's invalid directions

if a Chain of Thought step has a missing or empty structured-output declaration
  then parsing identifies that step's invalid output

if a structured-output declaration has a blank output name
  then parsing identifies that step and invalid declaration

if a structured-output declaration uses an unsupported type
  then parsing identifies that step and type

if an output name is declared by more than one step
  then parsing identifies the output and both declaring steps

if an interpolation references an output not declared by an earlier step
  then parsing identifies the interpolation and current step

when a value is checked against a consumed structured-output type
  then string, boolean, and integer declarations enforce their corresponding JSON value types
  and arrays and exact objects recursively enforce their declared consumed types
  while the value has the declared shape and types
    then it matches
  while an exact object has a missing, extra, or mistyped field
    then it does not match

when natural-language directions contain output interpolations
  then their referenced output names are returned in occurrence order
