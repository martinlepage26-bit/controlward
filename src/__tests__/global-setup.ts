import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

import { appDevOnce, appUninstall } from 'twenty-sdk/cli';

const APP_PATH = process.cwd();
const CONFIG_DIR = path.join(os.homedir(), '.twenty');

function validateEnv(): { apiUrl: string; apiKey: string } {
  const apiUrl = process.env.TWENTY_API_URL;
  const apiKey = process.env.TWENTY_API_KEY;

  if (!apiUrl || !apiKey) {
    throw new Error(
      'TWENTY_API_URL and TWENTY_API_KEY must be set.\n' +
        'Start a local server: yarn twenty docker:start\n' +
        'Then export TWENTY_API_KEY with a key from your local workspace.',
    );
  }

  return { apiUrl, apiKey };
}

async function checkServer(apiUrl: string) {
  let response: Response;

  try {
    response = await fetch(`${apiUrl}/healthz`);
  } catch {
    throw new Error(
      `Twenty server is not reachable at ${apiUrl}. ` +
        'Make sure the server is running before executing integration tests.',
    );
  }

  if (!response.ok) {
    throw new Error(`Server at ${apiUrl} returned ${response.status}`);
  }
}

function writeConfig(apiUrl: string, apiKey: string) {
  const payload = JSON.stringify(
    {
      remotes: {
        local: { apiUrl, apiKey, accessToken: apiKey },
      },
      defaultRemote: 'local',
    },
    null,
    2,
  );

  // The file holds the API key: owner-only directory and file.
  fs.mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
  fs.chmodSync(CONFIG_DIR, 0o700);
  const configPath = path.join(CONFIG_DIR, 'config.test.json');
  fs.writeFileSync(configPath, payload, { mode: 0o600 });
  fs.chmodSync(configPath, 0o600);
}

export async function setup() {
  const { apiUrl, apiKey } = validateEnv();

  await checkServer(apiUrl);

  writeConfig(apiUrl, apiKey);

  await appUninstall({ appPath: APP_PATH }).catch(() => {});

  const result = await appDevOnce({
    appPath: APP_PATH,
    onProgress: (message: string) => console.log(`[dev] ${message}`),
  });

  if (!result.success) {
    throw new Error(
      `Dev sync failed: ${result.error?.message ?? 'Unknown error'}`,
    );
  }
}

export async function teardown() {
  const uninstallResult = await appUninstall({ appPath: APP_PATH });

  if (!uninstallResult.success) {
    console.warn(
      `App uninstall failed: ${uninstallResult.error?.message ?? 'Unknown error'}`,
    );
  }
}
