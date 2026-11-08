# Reviewed mail associations and next actions

Email previously linked only contacts and companies. Its task action could create
work separate from the lead's next action. The local review inbox now offers exact
sender-address suggestions for existing leads, a reviewed lead association and an
action that reuses existing lead work. Shared addresses remain ambiguous choices.
Owner addresses, name similarity, matching domains and subject text do not produce
suggestions. A sender match is not authentication or evidence of buying interest.

Saving a review retains the message's source metadata and copies only the chosen
lead's existing relationship IDs. Conflicting relationships or another task's
ownership are refused atomically. The operation changes no lead status, draft,
sent history or follow-up date. No message is sent. The lead editor shows only mail
explicitly associated with that lead; unrelated or unlinked metadata stays out.

Next-action reuse keeps titles, dates, reminders and completion intact. Deleted
task receipts are not recreated. A new review task is possible only for an open
lead without existing next-action or other open task; it retains the lead's date
and links. Closed records are not reopened. Metadata imports cannot supply local
lead IDs, and refreshes preserve the reviewed association. Lead deletion clears
the live association while retaining the task receipt.

The same change set corrects an executive-title extraction edge case found in the
preceding release: a role keyword inside `not CEO` or `future CEO` was insufficient
to prove a current role. The whole extracted title must now be an affirmative
combination of supported roles. Negated, prospective, former and explanatory
phrases stay withheld. The selected live prospect roles remain affirmative.

Focused checks:

- `bin/test-native-app --mail-leads` exercises matches, ambiguity, owner-address
  exclusions, conflicts, task reuse, completion/deletion, import boundaries and
  reopen persistence in isolated stores. Disabling reuse makes the regression fail.
- `bin/test-native-app --quickscan-research` exercises full research and drafting;
  the added post-name negation fails against the preceding parser (20/21 cases).
- Full native, SwiftUI, packaging and installed UI evidence is recorded in the
  [current release receipt](https://pharos-ai.ca/artifacts/controlward/automatic-prospect-research)
  when executed; a focused model test alone does not prove live mailbox acceptance.

No live pilot reply was present at the check. A fixture can verify the complete
UI path, but cannot establish that a prospect replied, expressed interest or paid.
The standing sender remains Resend from ml@pharos-ai.ca, and this work authorizes
no additional messages or recipients. Notification delivery remains deferred.
