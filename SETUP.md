# Setup

Follow these steps to get your app running locally.

## Prerequisites

- Node.js (version specified in `.nvmrc`)
- Yarn 4
- Docker (to run the local Twenty server)

## Steps

1. Install dependencies:

   ```bash
   yarn install
   ```

2. Start the local Twenty server:

   ```bash
   yarn twenty docker:start
   ```

   Check the server status at any time with `yarn twenty docker:status`.

3. Start the development server and sync your app:

   ```bash
   yarn twenty dev
   ```

4. Open [http://localhost:2020](http://localhost:2020) and log in with your local development account: `<your-dev-email>` / `<your-dev-password>`. If the seeded demo account is still active, change its password or disable it before exposing port 2020 beyond this Mac.

## Verifying your setup

- `yarn lint` - Lint the project with oxlint
- `yarn typecheck` - Type-check the project
- `yarn test:unit` - Run unit tests
- `yarn test` - Run integration tests

## Persistent local installation on this Mac

This workspace includes a project-local Node 24, Yarn 4, Lima VM, and Docker
engine under the ignored `.twenty/` directory. Twenty CRM data is stored in
persistent Docker volumes inside that workspace VM. No CT920 runtime is used.

Use the launcher from the project root:

```bash
./bin/twenty-local start    # Start the VM and CRM
./bin/twenty-local status   # Verify VM, container, and HTTP health
./bin/twenty-local open     # Start and open http://localhost:2020
./bin/twenty-local apply    # Build and sync this app once
./bin/twenty-local dev      # Start live app synchronization
./bin/twenty-local stop     # Stop everything while preserving CRM data
```

The launcher restores the local runtime after a reboot without requiring a
global Yarn installation or Docker Desktop. Deleting `.twenty/` deletes the
local VM and its CRM data; normal `stop` and `restart` operations preserve it.

The VM mounts only this project directory, read-only (`.twenty/lima/docker/lima.yaml`),
not your whole home folder. Lima reads that file when the VM boots, so the
restriction takes effect on the next `./bin/twenty-local start` (or
`limactl start docker`). If a running VM predates the change, stop and start it once.

For integration tests, export `TWENTY_API_KEY` with a key created in your local
workspace; without it, `yarn test` skips the integration suite.

## Troubleshooting

See the [troubleshooting guide](https://docs.twenty.com/developers/extend/apps/getting-started/troubleshooting) or ask on [Discord](https://discord.gg/cx5n4Jzs57).
