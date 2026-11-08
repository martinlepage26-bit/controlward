# Executive names embedded in own-site prose

A Quick Scan prospect could have a published business route, an explicit AI-use
statement and a complete address, while remaining held because its named executive
appeared inside a sentence instead of a standalone name/title line.

The researcher now also recognizes a French notice that explicitly identifies the
privacy officer for the exact researched organisation and states an executive
title. The full name and title must be printed. The organisation is matched
literally; the statement must describe a current role and begin its own line.
Quoted blocks and navigation are excluded. A privacy role alone does not establish
an executive title. Existing structured name/title extraction remains unchanged.

The qualification predicate, named-person requirement, address/source checks,
suppression, conflict/licence holds, closed privacy gate and send approval are
unchanged. No business-only exception was added. A business mailbox is still not
assigned to a named person's personal email field during conversion.

Quick Scan research version advances to 3 so a new research request rechecks
version-2 findings rather than reusing a cached parsing failure. Older records
remain readable; no bulk rewrite or automatic outreach is introduced.

Validation:

- The new complete research/draft regression fails on the original parser:
  20/21 Quick Scan cases, with the explicit executive statement missed.
- The fixed source passes the complete native runner, including 21/21 Quick Scan
  cases. Negative cases retain the hold for another organisation, future or
  negated appointments, former roles, privacy-only roles, unnamed contacts and
  client-reported statements. No-approval send refusal remains verified.
- Packaging, exact-source CI and the updated running-app case are recorded in
  the [current release receipt](https://pharos-ai.ca/artifacts/controlward/automatic-prospect-research)
  when executed. The test result alone does not establish those runtime results.

Tests use synthetic sites, injected transport and isolated stores. No owner
credential or provider is contacted by this regression.
