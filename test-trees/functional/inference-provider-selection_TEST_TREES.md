Functional: inference-provider-selection (functional: none)

when the deployment configures an inference LLM and an embedder
  then the provider for each role is selected from that role's own configuration
  and OpenAI and Google are each accepted for either role
  and the memory runtime starts with the configured pair

while the configured LLM provider is OpenAI
  then knowledge-graph extraction sends its inference calls to OpenAI
  and reranking of search candidates is sent to OpenAI
  and recall interpretation, learning, and generalisation are sent to OpenAI

while the configured LLM provider is Google
  then knowledge-graph extraction sends its inference calls to Google
  and reranking of search candidates is sent to Google
  and recall interpretation, learning, and generalisation are sent to Google

while the configured embedder provider is OpenAI
  then episode and query embeddings are requested from OpenAI

while the configured embedder provider is Google
  then episode and query embeddings are requested from Google

while the configured LLM provider and the configured embedder provider differ
  then both clients are constructed and the runtime starts
  and the provider chosen for one role does not constrain the provider chosen for the other

where the deployment configures no LLM or embedder override
  then Google models are used for both roles
  and only the Google credential is required for the runtime to start

if a configured provider is neither OpenAI nor Google
  then the runtime refuses to start before any inference client is constructed
  and the failure names both configured model specs
  and the failure names the providers that are supported

if the credential for a configured provider is absent
  then the runtime refuses to start before any inference client is constructed
  and the failure names the absent credential
  and the failure names the role whose configuration required it

where a provider is named by neither role's configuration
  then its absent credential does not prevent the runtime from starting
