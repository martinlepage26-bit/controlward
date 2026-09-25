import tsconfigPaths from 'vite-tsconfig-paths';
import { defineConfig } from 'vitest/config';

const TWENTY_API_URL = process.env.TWENTY_API_URL ?? 'http://localhost:2020';
// The API key comes only from the environment. Never hardcode or print it.
const TWENTY_API_KEY = process.env.TWENTY_API_KEY;
const hasApiKey = typeof TWENTY_API_KEY === 'string' && TWENTY_API_KEY.length > 0;

if (!hasApiKey) {
  console.warn(
    'Skipping Twenty integration tests: TWENTY_API_KEY is not set. ' +
      'Create an API key in your local Twenty workspace and export TWENTY_API_KEY to run them.',
  );
}

// Make env vars available to globalSetup (test.env only applies to workers)
process.env.TWENTY_API_URL = TWENTY_API_URL;

export default defineConfig({
  plugins: [
    tsconfigPaths({
      projects: ['tsconfig.spec.json'],
      ignoreConfigErrors: true,
    }),
  ],
  test: {
    testTimeout: 120_000,
    hookTimeout: 120_000,
    fileParallelism: false,
    include: hasApiKey ? ['src/**/*.integration-test.ts'] : [],
    passWithNoTests: !hasApiKey,
    globalSetup: hasApiKey ? ['src/__tests__/global-setup.ts'] : [],
    env: hasApiKey ? { TWENTY_API_URL, TWENTY_API_KEY } : { TWENTY_API_URL },
  },
});
