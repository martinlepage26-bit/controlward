import { describe, expect, it } from 'vitest';
import { load } from './helpers';

describe('adapter is off by default (criterion 4)', () => {
  it('createAdapter() with no env returns a disabled no-op adapter', async () => {
    const { createAdapter } = await load.adapter();
    const a = createAdapter({});
    expect(a.enabled).toBe(false);
    expect(await a.requestApproval({ id: 'c1' }, 'contact.outreach', { x: 1 })).toEqual({ disabled: true });
    expect(await a.status('any')).toEqual({ disabled: true });
    expect(await a.consume('any', { x: 1 })).toEqual({ disabled: true });
  });

  it('only PHAROS_CORE_ENABLED=true enables it; other values stay disabled', async () => {
    const { createAdapter } = await load.adapter();
    for (const v of ['', 'false', '0', 'TRUE ', 'yes', '1']) {
      expect(createAdapter({ PHAROS_CORE_ENABLED: v }).enabled).toBe(false);
    }
    expect(createAdapter({ PHAROS_CORE_ENABLED: 'true' }).enabled).toBe(true);
  });

  it('the enabled adapter refuses a non-loopback base URL', async () => {
    const { createAdapter } = await load.adapter();
    expect(() => createAdapter({ PHAROS_CORE_ENABLED: 'true', PHAROS_CORE_URL: 'http://10.0.0.5:8787' })).toThrow(/loopback/);
  });

  it('the disabled adapter makes no network call', async () => {
    const { createAdapter } = await load.adapter();
    const calls: unknown[] = [];
    const a = createAdapter({}, (async (...args: unknown[]) => { calls.push(args); throw new Error('network'); }) as any);
    await a.requestApproval({ id: 'c1' }, 'contact.outreach', {});
    expect(calls).toHaveLength(0);
  });
});
