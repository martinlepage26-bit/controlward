# KAIROS context in Discovery

Discovery keeps broad prospect coverage in ControlWard's map search, agent-supplied
websites and own-site research. KAIROS adds account context and recorded enquiries.
It does not turn a content impression into a buying signal.

In **Pipeline → Find prospects**, use **Refresh KAIROS context** with an existing
customer-account API connection. This reads `/v1/strategy`, `/v1/inbox` and
`/v1/insights`. The audience/positioning brief can be copied for a search. Content
topics and aggregate performance support further experiments. Inbox platform
pauses are shown explicitly: an empty paused inbox means unavailable evidence,
not zero interest. Browser operator sign-in is separate from the native API key.

All three reads and imported enquiries commit as one local transaction. A failed
read or save retains the preceding snapshot. A connection change or workspace
restore during a refresh rejects that response. The existing inbox-only import
continues to work without requiring the new context routes.

The business list groups duplicate findings only after own-site research, using
normalized host and organisation identity. Unresearched inputs and shared platform
roots retain separate source identities. Original source aliases are retained.
Only an evidenced business website can receive a confirmed enquiry link.

**Review enquiry links** shows incoming text, channel and source time. A domain or
website-published mailbox in that text can suggest a business. Similar names and
handles alone cannot. A suggestion requires confirmation; a manual association
requires an explanation. The saved link retains that reason, incoming excerpt,
source time and business source. An explicit unlink survives merging older
research. CRM identities, contacts, sent history and unsent drafts are retained.

Each business has three independent assessments:

- **Fit:** an explained owner review against the audience and offer. A changed
  KAIROS strategy invalidates the previous fit decision until reviewed again.
- **Interest:** confirmed, source-backed incoming enquiries. Open enquiries with
  recorded text, a matching source date within 30 days, and current lead
  classification in the inbox snapshot receive current attention. Ignored or
  reclassified entries stay historical. Absence from the bounded inbox window
  preserves records and means unknown current classification, not retraction.
  Closed, older, undated or incomplete records remain historical/unknown.
- **Contactability:** contact routes supported by the checked business website.
  Publication does not establish deliverability or ownership of a personal inbox.

Attention order favors recent open enquiries, then reviewed fit and supported
contact routes; outside-offer businesses come last. There is no blended buyer
score. Likes, impressions and content scores never change individual interest.

Context, reviews, link evidence and source aliases are part of private local
backup/recovery. Fields added in this feature are optional for older workspaces.
The refresh sends no replies, publishes nothing, changes no provider permissions
and makes no LLM request. KAIROS retains its existing Gemini and approval policy.

Fresh collection is a separate KAIROS concern. Its current configuration pauses
six platforms. Fresh collection needs separate KAIROS capability and access
restoration. This feature displays those limits. Collector restoration,
activation and production flag changes remain outside this change.

Validation entry point: `bin/test-native-app --discovery-intelligence`. Full native
tests include the same suite. Complete application compilation and a running Mac
journey are required before this feature is described as delivered.

Pre-release checks on 7 November: all nine Discovery intelligence cases and the
complete native runner passed. A running acceptance-only Mac preview verified
two synthetic enquiries, three raw findings grouped into two businesses,
confirmed and explained manual links, independent fit, visible source evidence,
unlink and exact workspace bytes through restart. Original synthetic CRM leads
remained exact. This is synthetic preview evidence; packaged-release and live
nonempty account acceptance are separate gates.
