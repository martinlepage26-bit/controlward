# ControlWard agent discovery

Use the agent's existing public web-search tools to discover businesses for Martin's target and the selected 99 CAD AI Governance Quick Scan. The desktop app receives the candidates directly, performs own-site verification, and prepares eligible unsent drafts in Pipeline. No search-provider credentials are copied into ControlWard.

1. Read capabilities with `python3 controlward-research.py capabilities`. For a review, pass `--review-id <UUID>`. Normal-workspace access requires explicit `--live`; do not select it merely because no review workspace is open.
2. Search public sources for the stated target. Use primary business websites as candidate URLs. Business names and URLs are discovery inputs, not verified contact details, AI-use claims, buying intent or consent. Do not guess email addresses or insert search snippets as evidence.
3. Write a JSON array containing only `name` and `url` for each of 1–10 candidates. Use an own-business page likely to contain relevant evidence when available.
4. Run `python3 controlward-research.py submit --query "<target>" --input <candidates.json> --review-id <UUID>`. The client batches three sites per request. The already-running app processes the inbox without pasting URLs or pressing a research button.
5. Read `status --batch-id <returned UUID> --review-id <UUID>` until finished. Pending and running are not success. A partial, failed or cancelled request is not a complete campaign. The app retains sources and unknowns; eligible drafts appear in Pipeline. Use `cancel --batch-id <UUID>` to stop a batch.
6. Review actual results and source evidence. Record which candidates lack evidence instead of inventing a qualification. No messages are sent, no deal value is entered automatically, and the user decides whether to contact a business.

The app must be open. This workflow depends on an agent with public search access; the native app does not claim an independent general web-search service. A published business mailbox is not a verified personal inbox or proof of deliverability. Existing source, freshness, suppression, robots, conflict and send-approval rules remain in force. Do not inspect Keychain or provider sessions, activate connectors, alter notification permissions, or send outreach as part of discovery.
