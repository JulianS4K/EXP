import { describe, it, expect, vi, afterEach } from 'vitest';
import { DoorTimeoutError, isServerAnswer, withDeadline } from './net';

afterEach(() => {
  vi.useRealTimers();
});

describe('withDeadline', () => {
  it('returns the result in time', async () => {
    await expect(withDeadline(async () => 7, 1000)).resolves.toBe(7);
  });

  it('aborts and rejects a request that hangs', async () => {
    vi.useFakeTimers();
    let signal: AbortSignal | undefined;
    const p = withDeadline((s) => {
      signal = s;
      return new Promise<number>(() => {});
    }, 4000);
    const check = expect(p).rejects.toBeInstanceOf(DoorTimeoutError);
    await vi.advanceTimersByTimeAsync(4000);
    await check;
    expect(signal?.aborted).toBe(true);
  });

  it('passes a request error through', async () => {
    await expect(withDeadline(async () => { throw new Error('boom'); }, 1000)).rejects.toThrow('boom');
  });
});

describe('isServerAnswer', () => {
  it('server errors: SQLSTATE and PostgREST codes', () => {
    expect(isServerAnswer({ code: '42501', message: 'not authorized' })).toBe(true);
    expect(isServerAnswer({ code: 'PGRST301', message: 'JWT expired' })).toBe(true);
    expect(isServerAnswer({ code: 'P0001' })).toBe(true);
  });

  it('network failures, aborts and timeouts are not', () => {
    expect(isServerAnswer({ code: '', message: 'TypeError: Failed to fetch' })).toBe(false);
    expect(isServerAnswer({ message: '<html>502</html>' })).toBe(false);
    expect(isServerAnswer(new DoorTimeoutError(4000))).toBe(false);
    expect(isServerAnswer(new TypeError('Failed to fetch'))).toBe(false);
    expect(isServerAnswer(null)).toBe(false);
  });
});
