Functional: default-lens-compatibility (functional: test/functional/default_lens_compatibility_functional_test.exs)

where an application has not registered or selected a named Lens
  then the implicit `default` Lens preserves access to the operator's existing group
  and the `:jido_gralkor, :ontology` value remains its ontology
  and an unset `:jido_gralkor, :ontology` preserves generic extraction
  and existing capture, memory addition, and recall preserve legacy behaviour
