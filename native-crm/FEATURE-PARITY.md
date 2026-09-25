# FollowUp OS Native Feature Parity

Reference inspected: `https://followupos.pages.dev/`, as linked by
`/Users/pharos_ai/Downloads/FollowUp OS CRM.desktop`.

| Reference capability | Native implementation |
| --- | --- |
| Business onboarding and industry selection | `OnboardingView` |
| New, Contacted, Quote Sent, Won, Lost stages | `LeadStatus` and lead editor |
| Close rate, won revenue, open pipeline | `AppStore` metrics and pipeline cards |
| Due and overdue follow-ups | `dueLeads` and due section |
| Search and Open/All/Won/Lost filters | `filteredLeads` and native controls |
| Add, edit, save, and delete leads | `LeadEditorView` |
| Contact, company, service, amount, date, notes | Native lead form |
| CSV import with flexible headers | `CSVParser` and native open panel |
| Follow-up drafting | On-device Apple Intelligence with local template fallback |
| Copy and email message | macOS clipboard and default mail application |
| 1, 3, 7, 14-day sequence | `FollowUpCadence` and follow-up logging |
| Follow-up history | Persisted `FollowUpEvent` records |
| Privacy workspace review | Native Security view and review receipt |
| Six PHAROS protection lenses | Expandable native disclosures |
| Business settings | Native Settings view |
| Full reset with confirmation | Native destructive confirmation |
| Persistent local data | Atomic JSON file under `native-crm/data` |
| Browser-independent operation | Native SwiftUI/AppKit executable; no HTTP server |
| People/Contacts object | Dedicated `Contact` records with company and lead relationships |
| Companies object | Dedicated `Company` records with domain, industry, phone, and notes |
| Opportunities object | Dedicated revenue records with stages, amount, close date, and relationships |
| Tasks object | Dedicated task records with status, due date, and opportunity relationships |
| Notes object | Dedicated notes with contact/company/opportunity relationships |
| Workspace navigation | Native sidebar for each object and settings/security |
| Saved views | Default local views for all contacts, open opportunities, and tasks |
| Backward compatibility | Existing FollowUp OS JSON workspaces migrate with new collections empty/defaulted |

The deployed reference tries a remote Anthropic request and falls back to a
standard template when it cannot complete. The native build improves privacy
and offline behavior by using Apple's on-device model when available, with the
same kind of deterministic local fallback.
