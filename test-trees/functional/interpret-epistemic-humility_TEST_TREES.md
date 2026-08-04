Functional: interpret-epistemic-humility (functional: test/functional/interpret_epistemic_humility_test.exs)

while a real language model interprets memory deterministically
  when relevant memory holds accounts drawn from sources of differing apparent veracity
    then every account needed to answer the query is retained with its source wording intact
    but no account is ranked as more or less reliable than another
    and no account is adjudicated as true or false
  when relevant memory holds conflicting accounts
    then the conflicting accounts are surfaced together
    but they are not resolved into a single asserted fact
  when a relevant memory fact carries no available source context
    then it is returned with a concise relevance reason
    but that reason carries no generic warning about proof, confidence, verification, or reliability
  when sourced memory holds both relevant and irrelevant facts
    then the irrelevant facts are omitted
    and the relevant fact keeps its natural source context

if the model credential is absent or blank
  then the suite fails before any model call is made
