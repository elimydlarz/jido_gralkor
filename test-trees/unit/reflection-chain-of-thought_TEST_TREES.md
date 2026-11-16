Unit: reflection-chain-of-thought (src: lib/gralkor/reflection/chain_of_thought.ex; unit: test/gralkor/reflection/chain_of_thought_test.exs)

when structured Chain of Thought configuration contains one or more ordered steps
  while the configuration and steps use maps
    then parsing returns the steps in declaration order
    and every parsed step retains its label, directions, and structured-output declaration
    and every parsed step names no model and no reasoning effort
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

if a structured-output declaration has an output name holding a brace
  then parsing identifies that step and invalid declaration

if any type within a structured-output declaration is unsupported
  then parsing identifies that step and type

if an output name is declared by more than one step
  then parsing identifies the output and both declaring steps

if an interpolation references an output not declared by an earlier step
  then parsing identifies the interpolation and current step
  and an interpolation is identified whatever characters other than braces it holds

when a value is checked against a consumed structured-output type
  then string, boolean, and integer declarations enforce their corresponding JSON value types
  and arrays and exact objects recursively enforce their declared consumed types
  while the value has the declared shape and types
    then it matches
  while an exact object has a missing, extra, or mistyped field
    then it does not match

when natural-language directions contain output interpolations
  then their referenced output names are returned in occurrence order
  and each name is the text between the double braces without its surrounding spaces, whatever characters other than braces it holds
  and double braces whose text reaches another brace before closing double braces hold no interpolation

when directions are filled in from a shared output space
  then each interpolation naming an output in the space is replaced by that output's value
  and a string value is inserted as it is
  and any other value is inserted as its JSON encoding
  and double braces inside an inserted value are not filled in again
  and double braces whose text reaches another brace before closing double braces are left as written
  if an interpolation names no output in the space
    then that interpolation is left as written
