Functional: destination-registration (src: none; functional: none)

when an application registers a valid Destination
  then Lenses and Reflections can reference that Destination by name
  and the Destination scope governs operator-local or global placement

where a Destination omits an ontology
  then the Destination uses jido_gralkor's built-in default ontology

where a Destination declares an application ontology
  then extraction for every episode contributed to that Destination uses the declared ontology

when multiple Lenses or Reflections reference the same Destination
  then every contributor writes into the same storage channel
  and every contribution retains the identity of the Lens or Reflection that produced it
  and selecting any contributor resolves storage through that shared Destination

where a replaceable Lens references a shared Destination
  then graph replacement changes only that Lens's contribution to the Destination

if the Destination registry is not a list
  then configuration resolution raises `ArgumentError` naming what it found instead

if an application registers an invalid Destination
  then configuration resolution raises `ArgumentError` before ingestion, Reflection, or search begins
  and a blank Destination name is identified
  and a duplicate Destination name is identified
  and an invalid Destination definition shape is identified
  and an invalid Destination scope is identified with its Destination
  and an invalid Destination ontology is identified with its Destination

if a Lens or Reflection references an unknown Destination
  then configuration resolution raises `ArgumentError` identifying the contributor and Destination
