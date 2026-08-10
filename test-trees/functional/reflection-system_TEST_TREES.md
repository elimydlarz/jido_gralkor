Functional: reflection-system (functional: none)

when Reflection declarations are validated
  while every Reflection has a non-blank name
  and every Reflection name is unique
  and every Reflection supplies a valid Chain of Thought
  and every Reflection supplies a valid destination
    then validation succeeds

  if a Reflection name is blank
    then validation fails identifying the blank name

  if Reflection names are duplicated
    then validation fails identifying the duplicate name

  if a Reflection has no Chain of Thought
    then validation fails identifying that Reflection

  if a Reflection supplies an invalid Chain of Thought
    then validation fails identifying that Reflection and Chain of Thought

  if a Reflection has no destination
    then validation fails identifying that Reflection

  if a Reflection supplies an invalid destination
    then validation fails identifying that Reflection and destination

when an ingestion operation successfully stores information through one or more Lenses
  while Reflections are declared
    then every stored representation retains its evidence identifier and Lens identity
    and the ingestion caller receives success without waiting for Reflection
    and every declared Reflection is scheduled once for the completed ingestion operation
    and no Reflection begins before every intended Lens ingestion has completed

when a scheduled Reflection runs
  then its declared Chain of Thought is started for the operator and completed ingestion operation
  and the Chain of Thought receives every ingested representation with its evidence identifier and Lens identity

when a Reflection's Chain of Thought completes
  then its artefact is stored at the Reflection's declared destination
  and the artefact identifies its declaring Reflection
  and the artefact retains its supporting evidence identifiers

  where the declared destination is operator-scoped
    then the artefact is available only to the operator whose ingestion triggered the Reflection

  where the declared destination is global
    then the artefact is available through the shared global destination

when multiple declared Reflections process one completed ingestion operation
  then every Reflection runs independently
  and failure of one Reflection does not prevent another Reflection from completing

if any intended Lens ingestion fails
  then no Reflection is scheduled for the incomplete ingestion operation

if a Reflection's Chain of Thought returns no artefact
  then the Reflection fails identifying the missing artefact
  and the successful ingestion result remains unchanged

if a Reflection's Chain of Thought fails
  then the Reflection failure identifies its name and reason
  and the successful ingestion result remains unchanged
  and every other declared Reflection remains eligible to complete

if storing a Reflection artefact at its destination fails
  then the Reflection failure identifies its name, destination, and reason
  and the successful ingestion result remains unchanged
  and every other declared Reflection remains eligible to complete

when memory is searched for a stored Reflection artefact
  then the artefact is returned from its declared destination
  and the artefact identifies its declaring Reflection
  and the artefact retains its supporting evidence identifiers
