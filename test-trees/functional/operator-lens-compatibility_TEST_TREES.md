Functional: operator-lens-compatibility (functional: test/functional/operator_lens_compatibility_functional_test.exs)

where an application has not registered or selected a named Lens
  then implicit-default memory uses the graph named `operator/<operator id>`
  and jido_gralkor's built-in ontology governs implicit-default extraction
  and legacy capture, explicit memory addition, and recall use that built-in ontology consistently
  and implicit-default capture, explicit memory addition, and recall work without a consumer ontology module

when implicit-default memory and a named Lens write for the same operator
  then both write to one graph named `operator/<operator id>`

if an application retains the removed deployment-wide `:jido_gralkor, :ontology` setting
  then the implicit `operator` Lens still uses jido_gralkor's built-in ontology
