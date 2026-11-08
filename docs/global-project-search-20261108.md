# Global project search

The installed261 top bar already routes a submitted query to Overview and
searches native CRM records and imported mail metadata. The earlier diagnostic
claim that it performed no search was too broad. The actual gap was project
coverage: Project Control's loaded register was absent from the global results,
despite the prompt explicitly naming projects.

The repair retains the native query/filter/sort behavior and adds title,
workspace and status matching from the loaded connected Project Control
snapshot. Matching ignores case and diacritics and requires every query word.
Typing performs no provider refresh, credential read, capture or write.
Unloaded/disconnected project coverage is labelled; an offline connected cache
is labelled as such. Counts include every match, and each group's eight-row
display limit is explained with a request to refine the query.

A project result retains the register it came from. Selection checks that
register and opens the project within one synchronous JavaScript turn. A
same-ID project in a replacement register is refused. IDs remain typed WebKit
arguments, never JavaScript source. Existing saved-record project links now
use the same atomic destination check. Changing the query or leaving Overview
cancels pending native routing; an already-issued read-only WebKit action is
not represented as undone.

Local checks: complete native suite passes, with43 Overview assertions; base
WebKit integration passes13 assertions. New cases cover project/native mixed
matches, unchanged CRM/mail results, multiword/case/diacritic matching,
unloaded/disconnected/offline data, blank/no-match queries, complete counts,
typed quoted IDs, changed/disconnected registers, absent IDs and blank register
identities. The WKWebView fixture uses isolated storage and synthetic data.

The [release receipt](https://pharos-ai.ca/artifacts/controlward/automatic-prospect-research)
records packaging, exact-source CI, mutation checks and the separately scoped
running-app witness when performed. Its native acceptance must search a real
loaded project and open that exact project without a capture or provider write.
Source inspection or the model tests alone do not establish that witness.

The packaged owner-only recipient gate, Resend sender, collector settings and
notification permissions are unchanged by this repair. The full product goal
remains open, including the owner privacy ruling and remaining live evidence.
