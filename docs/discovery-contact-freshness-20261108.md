# Discovery contact quality and recheck freshness

Own-site research previously admitted partial `tel:` values and the North American
555-0100–0199 fictional block as contact routes. It also reused a result when an
agent requested a different page on the same business, and a newer negative
recheck did not consistently govern a lead's earlier unsent draft.

Phone contactability now requires a structurally complete route. NANP routes use
the administrator's NXX-NXX-XXXX shape and exclude its explicitly fictional block.
Other international routes receive a structural check only; this does not verify
country assignment, subscriber ownership or reachability. Literal source text is
retained, equivalent NANP formats share a comparison key, and extensions remain
separate. Other 555 ranges are not blanket rejected. The same checks apply when
older cached contacts are displayed. Rejected raw candidates remain available for
audit redaction and existing snapshots are retained.

Sources: [NANPA numbering plan](https://nanpa.com/about),
[NANPA fictional-number range](https://www.nanpa.com/numbering/555-line-numbers).

Research version 5 adds complete email identity and source-evidence checks.
The extractor preserves supported address punctuation and decodes published
HTML entities and `mailto:` escapes before checking the complete token.
Unsupported Unicode and extracted ASCII suffixes cannot become a different
published address. Email evidence must identify the complete route in the
original snapshot line or stored `mailto:` link; a matching substring alone is
insufficient. A cached contact is checked with the same source rule.

The native Resend preview also checks the original single supported recipient
before normalizing it, so an unsupported address cannot turn into another
ASCII destination. This does not authorize a message or prove deliverability.

Version 5 retains the requested-page and freshness rules introduced by version 4.
Research records the actual requested page. Reuse requires that page,
the same business name, the current parser, a complete result less than one hour
old and the same local calendar day. Missing older provenance causes a recheck.
The output distinguishes fresh attempts from cached reuse; neither label asserts
that a website request succeeded. Earlier parser results remain readable but
require a recheck before using a cold-outreach draft.

The newest saved source assessment is copied to an existing associated lead,
including after recovery from a failed save. Owner text, sent history, status,
relationships and dates are retained. A newer negative or incomplete assessment
blocks the older draft. The coordinator also uses the winning saved result for
promotion and its reported outcome, so an older slow positive fetch cannot
publish a false ready result after a newer negative check.

Focused checks:

```sh
bin/test-native-app --quickscan-research
bin/test-native-app --agent-research
```

The cases exercise complete published email routes, suffix-only and encoded
source evidence, raw recipient normalization, fresh and cached rejected phones, literal format/extension
handling, requested page and business identity, parser provenance, hour/future
boundaries, local midnight in UTC+14 and UTC-11, direct and recovered negative
rechecks, overlap ordering, exact owner-field retention and reopen persistence.
Transport fixtures send no mail. Original-behavior and disabled-propagation runs
are retained privately to establish that the regressions detect these failures.

Packaging, installed native UI acceptance, public-site rechecks and their exact
build scope are recorded in the [release receipt](https://pharos-ai.ca/artifacts/controlward/automatic-prospect-research)
after execution. Automated checks alone do not establish those runtime results.
Resend from ml@pharos-ai.ca remains the lead-outreach route. This change approves
no recipient, send, campaign, personal identity, buying interest or revenue.
