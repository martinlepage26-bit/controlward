# Lead-related mailbox actions use the standing sender route

Email review can associate messages with existing CRM leads. Its mailbox-native
reply actions previously still offered a Gmail send, creating a route around the
standing instruction to send lead outreach through Resend from ml@pharos-ai.ca.

The mailbox UI now withholds Reply, Reply all and Forward for a reviewed lead
association or an exact sender-address match, and explains the lead-editor Resend
path. A second guard derives the restriction again at action time from the current
local message, CRM relationships and compose To/Cc recipients. An old compose or
changed recipient cannot bypass it. Missing or mismatched local messages are also
refused and audited. No message body is copied automatically into a lead draft.

The guard writes one refusal audit and makes zero mailbox requests. It grants no
Resend send permission: the existing privacy gate, exact-recipient/message review,
durable request, receipt and duplicate handling remain required. Ordinary personal
mail without a known lead relationship keeps its existing connector, as do
non-send actions such as Archive. This is a route restriction, not a claim that a
prospect replied or an additional send was approved.

`bin/test-native-app --mail-control` exercises confirmed Reply/Reply all/Forward,
zero-HTTP refusal, audit results, ordinary personal replies and non-send behavior
with injected transport. `--mail-leads` checks sender/association and edited To/Cc
classification. Complete packaging and native UI acceptance are recorded in the
[release receipt](https://pharos-ai.ca/artifacts/controlward/automatic-prospect-research)
when executed. No live send is needed to verify refusal.
