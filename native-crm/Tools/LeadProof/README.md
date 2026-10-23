# Lead pipeline (Slice 3): Mac steps and live proof

ControlWard's lead pipeline finds prospects, reads each business's own website, scores the record and writes a
local draft. It never sends. Leads stay in ControlWard's own Leads list and are never pushed to Project Control.

## Tests (no network)

    bin/test-portable        # Linux or Mac: pipeline tests plus "expected 41 failures, got 41: OK"
    bin/test-native-app      # Mac: the full smoke suite, which now includes the same lead suites

## Live proof in one command (Mac)

    bin/prove-lead-pipeline                         # every segment around Montréal, 3 sites each
    bin/prove-lead-pipeline --segment clinic --limit 5
    bin/prove-lead-pipeline --lat 46.8139 --lon -71.2080 --radius 5000
    bin/prove-lead-pipeline --rbq-refresh           # also fetch the RBQ JSON (fixed link only, at most daily)

The command builds the same sources the app uses, creates a new empty leads folder under the temp directory,
writes a `launch` audit line with the store count (0), runs the search, ingests into the Leads store, saves drafts to
`drafts.json`, then checks Earth's bar against the folder's own `cw-audit.log`:

1. Leads list and store empty at launch (`action=launch ... receipt=store-0`).
2. `action=search source=controlward`, `action=fetch source=own-site` and `action=score` lines whose register and
   `ts` match each record's source URL and fetch time.
3. The drafted record's address appears verbatim in its own-site snapshot.
4. Each draft carries the sender ID, the rue de Rouen mailing address, an unsubscribe and a consent basis.
5. No `action=send` line and no request to a host outside icp.json's allowlist or the prospect's own domain.

It prints PASS or FAIL for each check, then `LEAD PIPELINE PROOF PASSED` (exit 0) or `FAILED` (exit 1). The log is
saved under `native-crm/.build/lead-proof/logs/`. A run with no Ready prospect fails checks 3 and 4 honestly; try
another segment, area or a higher `--limit`.

## Proof from the app itself

1. Quit ControlWard. Move the leads folder away so the store is empty:
   `~/Library/Containers/com.pharos.contextward/Data/Library/Application Support/ControlWard/leads`
2. Build and open the app (`bin/build-native-app`), go to Pipeline, press **Leads**. Opening the sheet writes the
   launch line. Choose a segment and press **Search**.
3. Verify the app's own folder, with no network:
   `bin/prove-lead-pipeline --verify-app "$HOME/Library/Containers/com.pharos.contextward/Data/Library/Application Support/ControlWard/leads"`

## Sources

- Discovery: Overpass (`overpass.private.coffee` primary, `overpass-api.de` fallback), then Photon (`photon.komoot.io`).
  Only OSM tags and coordinates are sent, with the identifying User-Agent from icp.json.
  - Query areas (`etiquette.discovery_query.tile_radius_meters`, default 1000): a search circle larger than one cell is
    split into 1 km cells on a grid spaced r·√2, so the cells cover the whole circle; one Overpass query per cell, centre
    first, until the limit. Hits outside the requested circle are dropped, so coverage is the same circle as before.
  - Timeout (Water 7:49 and 8:20): each query carries `[timeout:N]` (`overpass_query_timeout_seconds`, 60) and the
    client waits N + `client_timeout_margin_seconds` (10) = 70 s. Both come from the one config block.
  - Retries (`etiquette.discovery_retry`): on a timeout, network error, 429 or 5xx, each host gets one try plus
    `retries_per_host` (2) retries, backoff 5 s then 10 s per host (doubling, stretched by up to `jitter_fraction` 25 %,
    capped at 60 s, Retry-After honoured), then the next host. Every attempt (Overpass and Photon) writes a
    `discovery-attempt` audit line beside its `fetch` line, with its real result (`ok`, `error:network`, `error:504`, a
    refusal code) and receipt `attempt-k-of-n,wait-<ms>ms` (the measured wait for that request, Earth 8:20). Once both hosts are used up in a segment search, its remaining cells and
    selectors go straight to Photon.
  - Audit (Earth 8:19): one `action=search` line per selector names the provider that actually answered in `register`
    (an Overpass server or Photon) with `result=ok`; when none answered, `register=-` and the real error. Every skipped
    candidate gets `action=skip register=<provider endpoint> target=<OSM id> source=<provider host>
    result=skipped:<reason>` (e.g. `skipped:no-own-website-on-the-listing`).
  Photon (unchanged) is asked only when Overpass found nothing inside the circle for a selector. Photon results carry no website, so a
  Photon-only run finds no own site to read.
- People, titles, addresses and triggers come only from the business's own site (robots.txt honoured, 10 s per host).
  `allowed_contact_sources` for clinics and trades lists `own_site`, `registraire_des_entreprises` and
  `professional_order_directory`, but only `own_site` is enabled; the other two are disabled in config and never fetched.
  A Cloudflare or other bot challenge is a hard fail for that site; it is never bypassed.
- RBQ open data (Source: RBQ / Données Québec, CC BY 4.0): only the two fixed download links in icp.json, used for
  discovery and for the conflict hold by licence category. Courriel, phone, Mandataire, address and NEQ are never stored.
  The field names are taken from the published field sheet; confirm them against the first real download.
- Refused: LinkedIn, REQ, pes.rbq.gouv.qc.ca, connexence, the psychologues directory, algolia, OMVQ, and the held
  professional-order sites (CMQ, ODQ, OPQ, OPPQ, optométristes, chiropraticiens).

## Research objects and the funnel

Each prospect stores its own-site research as two objects:

- `observed_facts`: company name, service categories, service areas, languages seen (`fr`/`en`), contact page URL, booking URL (or `null`), and an `evidence` map of `{url, excerpt}` per fact.
- `assessment`: potential offer, `supporting_evidence` (`{url, excerpt}`), unknowns, `requires_manual_review`.

A draft quotes only an excerpt that is verbatim in a stored snapshot. Any other quote or URL above the footer is refused (`refused:research:unsupported-claim`), and a prospect that needs manual review gets no draft (`refused:research:manual-review`).

Discovery dedupes by place id and normalized domain and drops closed places (OSM lifecycle tags such as `disused:*` / `was:*`, `opening_hours=closed`, `end_date`, a "(fermé)" name, or an own-site closure notice). The Overview and the Leads sheet show the funnel from local files only: businesses discovered → with a usable website → appropriate contact found → evidence-backed opportunity. Everything runs on the Mac; no hosted APIs or data providers.
