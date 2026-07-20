Functional: default-lens-compatibility (functional: none)

where an application has not registered or selected a named Lens
  then the implicit `default` Lens preserves access to the operator's existing memory partition
  and the `:jido_gralkor, :ontology` value remains its ontology
  and an unset `:jido_gralkor, :ontology` preserves generic extraction
  and existing capture, memory addition, and recall preserve legacy behaviour
