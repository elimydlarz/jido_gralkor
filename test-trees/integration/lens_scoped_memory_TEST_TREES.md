Integration: Lens-scoped memory (integration: none)

when an operator configures a named Lens with a custom ontology
  then the Lens becomes an available memory channel bound to that ontology
  and each principal receives an isolated Graphiti partition for that Lens

where no named Lens is selected
  then the implicit `default` Lens preserves the principal's existing Graphiti partition
  and the `:jido_gralkor, :ontology` value remains the ontology for that Lens
  and an unset `:jido_gralkor, :ontology` preserves generic Graphiti extraction

when an explicit memory is ingested through a Lens
  then the information is added only to that principal's partition for the selected Lens
  and the selected Lens's ontology shapes entity and relationship extraction
  and no other Lens or principal receives the information

when a conversation turn is captured with an active Lens
  then the turn, its learning, and its generalisations stay in that principal's partition for the active Lens
  and the active Lens's ontology shapes every write derived from the turn
  when another turn in the same session uses a different active Lens
    then each Lens is flushed as a separate episode under its own ontology
    and no episode combines information from different Lenses

when memory is searched with a non-empty selection of Lenses
  then regular facts, learnings, and generalisations are searched only in that principal's partitions for the selected Lenses
  and results from the selected Lenses are combined into one memory response for interpretation
  and memory from unselected Lenses or another principal cannot appear in the response

where ingestion omits a Lens
  then the turn's active Lens is used
  where the turn has no active Lens
    then the implicit `default` Lens is used

where search omits its Lens selection
  then only the turn's active Lens is searched
  where the turn has no active Lens
    then only the implicit `default` Lens is searched

if ingestion names an unknown Lens
  then ingestion fails before any Graphiti write is attempted

if search names an unknown Lens, supplies a blank Lens name, or supplies an empty explicit selection
  then search fails before any Graphiti query is attempted
  and no valid subset is searched

if a named Lens is configured with a blank name or a module that is not declared with `use Gralkor.Ontology`
  then configuration resolution raises `ArgumentError` naming the invalid Lens before ingestion or search begins
