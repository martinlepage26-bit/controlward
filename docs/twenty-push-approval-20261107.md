# Twenty push approval across asynchronous work

A confirmed preview authorizes the mapped CRM content shown at that time.
Credential access, HTTP pacing and earlier object writes can suspend a push while
the owner continues editing local records.

The push retains an immutable approved workspace and the preview's original link
map. After credential access and before each later operation, it compares current
mapped content against that same approval. A changed connection or mapped record
stops further operations and requires a new preview. Business payloads are built
from the approved workspace; only durable remote identities from completed work
are used to resolve dependent records. Progress receipts do not expand approval.
Concurrent pushes are refused. No remote record is deleted.

Two controlled tests use entirely in-memory credentials and HTTP:

- Editing a company while its key read is held causes zero HTTP requests.
- Editing a contact while the company response is held stops before people are
  sent, retains the completed company receipt, and resumes without duplicates
  only after a fresh preview. The newly approved contact value is then exported.

These extend the credential-focused suite from seven to nine cases. The complete
native suite also checks lost responses, failed local saves, missing remote
records and converted-deal identities. Canonical CI and packaging remain release
gates. No owner credential or live Twenty destination is used by these tests.
The [current release receipt](https://pharos-ai.ca/artifacts/controlward/automatic-prospect-research)
records the installed build and actual runtime scope. Production destination
acceptance and the full product objective remain separate requirements.
