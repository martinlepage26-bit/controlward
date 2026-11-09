# EMERAULD living archive in Projects

Open Projects → Living archive, connect the existing Project Control register in Sync, then Load / refresh history. Timeline, Evidence and Graph share a project filter and search. Loading is read-only. Governing project actions and native capture stay in the existing register.

Timeline reads every page to a fixed source high-water mark. The UI searches all loaded history and shows a bounded result set. The capture boundary is explicit: retained baseline records plus every committed business-table mutation since installation; earlier deleted history cannot be reconstructed.

Evidence includes complete notes and private document metadata (path, title, collection, content SHA-256). CT920 stores original source versions separately outside the two unchanged vaults. The UI never stores the archive stream in localStorage. Its existing owner connection is used; a CT920 archive reader must not be used as a dashboard owner token.

Graph includes explicit project/parent/note/intake/submission relationships and an optional approved published vault graph. The vault-graph request has a fixed destination and never forwards private queries or source data. Nodes are namespaced and inspectable. Publication remains separate from assistant exposure.

Server installation requires additive migration 0006 before enabling the new Worker. Roll back Worker/UI code independently; leave archive tables/triggers and private immutable source objects intact to preserve captured history. Do not erase capture tables as a routine rollback.
