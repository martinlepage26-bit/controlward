# ControlWard

A native macOS CRM and operations workspace that connects contact management, project intake, and selected external services. ControlWard emphasizes local persistence, explicit review before outbound updates, and documented connector boundaries.

## Technical review

| Focus | Evidence |
| --- | --- |
| Native application and data boundaries | [Native CRM guide](native-crm/README.md) |
| Edge API and retention | [Worker API guide](pharos-api/README.md) |
| Product scope and interface | [Product](PRODUCT.md), [design](DESIGN.md) |
| Automated checks | [CI workflow](.github/workflows/ci.yml) |
| Build and packaging | [macOS workflow](.github/workflows/build-macos-app.yml) |

**Stack:** Swift/macOS, WebKit, TypeScript, Cloudflare Workers, and D1. The operating guide distinguishes operational components, prototypes, and parked scaffolds.


## Setup and operating guide

The [existing detailed README](https://github.com/martinlepage26-bit/controlward/blob/b392e6746991cdbf2855c417e88b980fee655885/README.md) remains available at the revision preceding this presentation update. It contains setup, checks, operating requirements, and limitations.
