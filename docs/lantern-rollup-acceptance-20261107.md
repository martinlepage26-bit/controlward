# Lantern weighted assessment repair — 2026-11-07

An isolated running-app probe of build205 reproduced a scoring defect: FR20 with one sample and FR100 with three samples displayed French100 and a40-point gap against English60. The correct sample-weighted French score is80 and the gap20. The original source used the final row as the aggregate. Probe workspace58A16328-F330-41A2-8966-CC6BC61AA69A is synthetic and retained separately from the earlier import acceptance workspace.

The repair computes each language's five dimensions using positive sample weights, retains per-row counts and fractional values, and excludes zero-weight rows from the mean. Canonical transcript rows each have weight1. Missing language evidence, missing dimensions, zero samples and explicitly withheld assessments produce no numeric comparison or remediation task. Actual measured zero remains valid. Legacy integer data still decodes; old multi-row data without weights requires reimport or owner review before comparison. Reimport preserves an owner's explicit incomplete-assessment decision.

The editor exposes each assessment's completion state and explains an unavailable comparison. Gap averages exclude unscored audits. Fractional data survives native backup, restore and restart. An older integer-only app cannot read all new fractional records; restoring a version-appropriate backup is required before a downgrade.

## Evidence at source checkpoint

- Native import suite:57/57 including the large-weight boundary regression and fractional backup/restore/restart; full native suite passed. The earlier SwiftUI debug build also passed.
- Replacing Models.swift and AppStore.swift with the original205 scorer makes9 targeted regression cases fail (47/56); measured zero and legacy integer controls pass. The harness's expected failure is a test-process failure, not a running-app crash.
- The large-count numerical boundary control confirms that finite0–100 inputs keep their mathematical mean within0–100 despite floating-point rounding. Packaged UI/release evidence is recorded in the PR and published report after verification.

Running-app acceptance must cover weighted CSV and canonical workbook means, visible fractional dimensions, missing/partial assessment labels, owner withholding and source refresh, genuine-zero comparison, backup/restore and exact quit/reopen. No notification permissions, owner sign-ins or live connector actions are part of this check.

The prior205 QA session unintentionally started a staged app in normal mode through a stale UI binding. Its startup migrated the normal workspace. The exact original was restored from the automatic pre-migration backup; all15 baseline hashes and the complete owner file set match again. The migrated copy and generated startup files are retained privately. Background activity during that startup was not independently verified. Subsequent review must launch explicitly, verify the live process and review banner, and discard UI bindings after quit.

The full product goal remains open. Separate follow-up: backup validation currently omits identities in some persisted collections; reproduce and repair before claiming complete malformed-backup coverage. Notifications remain explicitly deferred by Martin, and fixture checks do not establish live provider integration or revenue.
