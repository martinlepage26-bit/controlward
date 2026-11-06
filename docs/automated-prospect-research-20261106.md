# Automated contact and AI-use research

Martin clarified on November 6 that finding contact details and evidence of AI use belongs to ControlWard. Asking him to perform those research steps manually did not satisfy that product goal.

## Behavior

Pipeline → Find prospects now runs public-site research after map discovery. For each selected business it follows the business's own contact, AI, team and agency/about links within the configured page budget. The run is cancellable, bounded to three minutes and saves completed observations.

The website queue also accepts business names and URLs found by an agent or another search. Each line is `Business name | https://website`. These inputs contain no verified contact or AI claim: ControlWard obtains that evidence from the websites itself. Queue inputs receive no geographic-fit points and no invented map coordinates.

The review shows:

- Public email and phone routes with the exact supporting text or link, source URL and retrieval time.
- Named people and titles found on the business site.
- Explicit statements of actual AI use, with literal excerpts and source URLs.
- Unreadable pages, policy refusals and missing evidence.
- Qualification results and a grounded 99 CAD Quick Scan draft when the existing draft checks pass.

Unreviewed research is saved separately from CRM leads in the private `quick-scan-research.json` cache. Adding a researched lead saves the structured evidence and unsent draft together. Repeating research preserves owner edits and reuses the existing business rather than creating another lead or signal.

Business contact routes remain distinct from verified personal inboxes. During reviewed conversion, a published company mailbox or phone is not assigned to the named person unless separately entered by the owner. Finding a route on a website does not establish deliverability, consent to a particular message or buying intent.

## Qualification

Generic AI mentions, online booking, privacy notices, future plans, negated use, questions and quoted third-party testimonials do not establish AI use for this campaign. English and French first-party use statements are supported. This conservative local matcher can miss differently phrased genuine uses; the result then states that use was not established on the pages checked.

The existing configured segment, named-person, provenance, freshness, suppression, conflict and RBQ checks continue to apply. A no-solicitation statement on any checked page prevents a publication-based draft. Robots exclusions and bot challenges are respected. No additional requests start after cancellation during a pacing wait.

Martin explicitly selected the 99 CAD Quick Scan. A structured offer designation allows only its exact approved price wording through the draft pricing rule. Other prices remain blocked, and the designation is bound to the per-message approval hash. The existing send gate remains closed to unapproved external outreach. The offer price does not populate deal value or sent history.

## Verification

- Full macOS native suite: existing lead pipeline 92/92, CRM workflow 24/24, plus Quick Scan research 15/15 and discovery/save/cache 5/5.
- Full SwiftUI debug and release builds on the local pinned Swift 6.3 toolchain.
- WebKit workspace-module checks and source-list consistency.
- Isolated running-app public-site research: three supplied business websites, two explicit AI-use statements, one complete qualification with a priced unsent draft. These websites were discovered through agent web search, not by the app's map provider.
- DVCOM: the app extracted a business-published email, a named partner/title and an explicit AI-use statement from its own site. It created a reviewable Quick Scan draft with no entered deal amount and no contact history.
- artlequin: own-site AI-use evidence found; no supported email was found in the pages checked.
- Bingo Charlie: published contact routes found; the conservative matcher did not establish AI use from the pages checked. This is a recall limitation, not a claim that the business does not use AI.

These public-site checks do not prove market demand, email deliverability, a sent campaign or revenue. Native tests use synthetic sites and an in-memory transport; the running-app checks made actual public HTTP requests without mailbox credentials or outbound messages.

## Remaining discovery work

The map search returned zero marketing agencies within 10 km of the tested Montréal center. It remains a limited discovery source. A website queue supports an agent-assisted discovery-to-research workflow, but ControlWard still has no configured general web-search provider or verified unattended campaign runner. This change completes the automated verification step; it does not close the broader all-promises goal.

The new app remains a review build until its separate release handoff. Installed build 186 and notification-delivery deferral are unchanged by the research tests.
