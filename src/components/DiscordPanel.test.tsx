// @vitest-environment jsdom
// Org settings → Discord (mig 20261113130000): hidden until the operator turns
// Discord on; the webhook URL is checked before saving and never shown back;
// only an owner can turn sending on.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';

const h = vi.hoisted(() => ({
  toast: vi.fn(),
  cfg: { enabled: true, bot: true, writes: false },
  status: null as any,
  save: vi.fn(),
  options: vi.fn(),
  test: vi.fn(),
  reminder: vi.fn(),
  event: null as any,
}));
vi.mock('../context/ToastContext', () => ({ useToast: () => ({ toast: h.toast }) }));
vi.mock('../lib/supabase', () => ({ supabase: {}, initialAuthUrl: '' }));
vi.mock('../lib/discord', async (orig) => {
  const real = await orig<typeof import('../lib/discord')>();
  return {
    ...real,
    fetchDiscordConfig: async () => h.cfg,
    fetchDiscordStatus: async () => h.status,
    saveDiscordWebhook: (...a: unknown[]) => h.save(...a),
    setDiscordOptions: (...a: unknown[]) => h.options(...a),
    sendDiscordTest: (...a: unknown[]) => h.test(...a),
    setDiscordReminder: (...a: unknown[]) => h.reminder(...a),
    fetchDiscordEventStatus: async () => h.event,
    removeDiscordWebhook: async () => undefined,
    unlinkDiscordServer: async () => undefined,
    startDiscordInstall: async () => 'https://discord.com/oauth2/authorize?scope=bot',
  };
});

import DiscordPanel from './DiscordPanel';
import DiscordEventPanel from './DiscordEventPanel';
import { parseDiscordEventStatus, parseDiscordStatus } from '../lib/discord';

const ORG = '11111111-1111-4111-8111-111111111111';
const URL_OK = 'https://discord.com/api/webhooks/223456789012345679/' + 'T3' + 'aB9_-x'.repeat(11) + 'Zq';

beforeEach(() => {
  h.toast.mockReset();
  h.save.mockReset().mockResolvedValue('…5679');
  h.options.mockReset().mockResolvedValue(undefined);
  h.test.mockReset().mockResolvedValue({ status: 'dry_run', error: null });
  h.reminder.mockReset().mockResolvedValue(undefined);
  h.cfg = { enabled: true, bot: true, writes: false };
  h.status = parseDiscordStatus({ can_manage: true, is_owner: false, webhook: { set: false }, guild: { linked: false }, writes_enabled: false });
});
afterEach(cleanup);

describe('DiscordPanel', () => {
  it('stays hidden while Discord is off on this server', async () => {
    h.cfg = { enabled: false, bot: false, writes: false };
    const { container } = render(<DiscordPanel orgId={ORG} />);
    await new Promise((r) => setTimeout(r, 20));
    expect(container.innerHTML).toBe('');
  });

  it('checks the URL before saving, saves it, and clears the field', async () => {
    render(<DiscordPanel orgId={ORG} />);
    const input = await screen.findByLabelText('Channel webhook URL');
    expect((input as HTMLInputElement).type).toBe('password');
    fireEvent.change(input, { target: { value: 'https://evil.example/api/webhooks/1/2' } });
    expect(screen.getByText("That isn't a Discord channel webhook URL.")).toBeTruthy();
    expect((screen.getByRole('button', { name: 'Save webhook' }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(input, { target: { value: URL_OK } });
    fireEvent.click(screen.getByRole('button', { name: 'Save webhook' }));
    await waitFor(() => expect(h.save).toHaveBeenCalledWith(ORG, URL_OK));
    await waitFor(() => expect((input as HTMLInputElement).value).toBe(''));
    expect(screen.getByText(/Dry run/)).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Add Exos bot to your server' })).toBeTruthy();
  });

  it('a manager can\'t turn sending on; an owner can', async () => {
    render(<DiscordPanel orgId={ORG} />);
    const box = await screen.findByRole('checkbox', { name: /Send to Discord/ });
    expect((box as HTMLInputElement).disabled).toBe(true);
    cleanup();
    h.status = { ...h.status, isOwner: true };
    render(<DiscordPanel orgId={ORG} />);
    fireEvent.click(await screen.findByRole('checkbox', { name: /Send to Discord/ }));
    await waitFor(() => expect(h.options).toHaveBeenCalledWith(ORG, { writes: true }));
  });

  it('shows the linked server and never the webhook URL', async () => {
    h.status = parseDiscordStatus({ can_manage: true, is_owner: true, webhook: { set: true, hint: '…5679' },
      guild: { linked: true, name: 'Blue Room' }, writes_enabled: true, shown_events: 3 });
    h.cfg = { enabled: true, bot: true, writes: true };
    const { container } = render(<DiscordPanel orgId={ORG} />);
    await screen.findByText(/Linked to Blue Room/);
    expect(container.textContent).toContain('webhook …5679');
    expect(container.textContent).not.toContain('/api/webhooks/');
    expect(container.textContent).not.toMatch(/Dry run/);
    expect(screen.getByRole('button', { name: 'Disconnect server' })).toBeTruthy();
  });

  it('says when the bot lost access, the webhook was refused, or Discord is paused', async () => {
    h.status = parseDiscordStatus({ can_manage: true, is_owner: true, paused: true, webhook: { set: true, hint: '…5679', broken: true },
      guild: { linked: true, name: 'Blue Room', broken: true }, writes_enabled: true });
    render(<DiscordPanel orgId={ORG} />);
    await screen.findByText(/lost access to Blue Room/);
    expect(screen.getByRole('button', { name: 'Reconnect the bot' })).toBeTruthy();
    expect(screen.getByText(/Discord refused this webhook/)).toBeTruthy();
    expect(screen.getByText(/Discord is paused on this Exos server/)).toBeTruthy();
  });

  it('says when Discord is paused for this organization, and until when', async () => {
    h.status = parseDiscordStatus({ can_manage: true, is_owner: true, webhook: { set: true, hint: '…5679' }, guild: { linked: false },
      org_paused_until: '2026-11-12T14:30:00Z' });
    render(<DiscordPanel orgId={ORG} />);
    expect(await screen.findByText(/paused Discord for it until/)).toBeTruthy();
  });
});

// mig 20261114100000: Send a test, the automatic reminder, delete on delete.
describe('DiscordPanel: Send a test and the automatic reminder', () => {
  const saved = () => parseDiscordStatus({ can_manage: true, is_owner: true, webhook: { set: true, hint: '…5679' }, guild: { linked: false },
    writes_enabled: false });

  it('no test and no reminder before a webhook is saved', async () => {
    render(<DiscordPanel orgId={ORG} />);
    await screen.findByLabelText('Channel webhook URL');
    expect(screen.queryByRole('button', { name: 'Send a test' })).toBeNull();
    expect((screen.getByLabelText('Automatic reminder') as HTMLSelectElement).disabled).toBe(true);
  });

  it('sends a test, says it is a dry run, and the toast says so too', async () => {
    h.status = saved();
    render(<DiscordPanel orgId={ORG} />);
    const btn = await screen.findByRole('button', { name: 'Send a test' });
    expect(btn.getAttribute('aria-describedby')).toBe('discord-test-note');
    expect(screen.getByText(/Send a test is a dry run too/)).toBeTruthy();
    fireEvent.click(btn);
    await waitFor(() => expect(h.test).toHaveBeenCalledWith(ORG));
    await waitFor(() => expect(h.toast).toHaveBeenCalledWith({ kind: 'success', message: expect.stringMatching(/^Dry run/) }));
  });

  it('live: says it posts one message; a refusal is an error toast', async () => {
    h.cfg = { enabled: true, bot: true, writes: true };
    h.status = { ...saved(), writesEnabled: true };
    h.test.mockResolvedValue({ status: 'error', error: 'Discord: the webhook was deleted or its URL is wrong; paste a new one' });
    render(<DiscordPanel orgId={ORG} />);
    fireEvent.click(await screen.findByRole('button', { name: 'Send a test' }));
    expect(screen.getByText(/posts one message in the channel/)).toBeTruthy();
    await waitFor(() => expect(h.toast).toHaveBeenCalledWith({ kind: 'error', message: expect.stringMatching(/paste a new one/) }));
  });

  it('no test for a webhook Discord refused', async () => {
    h.status = parseDiscordStatus({ can_manage: true, is_owner: true, webhook: { set: true, hint: '…5679', broken: true }, guild: { linked: false } });
    render(<DiscordPanel orgId={ORG} />);
    await screen.findByText(/Discord refused this webhook/);
    expect(screen.queryByRole('button', { name: 'Send a test' })).toBeNull();
  });

  it('sets the reminder to 24 or 48 hours, or off', async () => {
    h.status = saved();
    render(<DiscordPanel orgId={ORG} />);
    const sel = (await screen.findByLabelText('Automatic reminder')) as HTMLSelectElement;
    expect(sel.value).toBe('');
    expect([...sel.options].map((o) => o.textContent)).toEqual(['Off', '24 hours before the start', '48 hours before the start']);
    fireEvent.change(sel, { target: { value: '48' } });
    await waitFor(() => expect(h.reminder).toHaveBeenCalledWith(ORG, 48));
    cleanup();
    h.status = { ...saved(), reminderHours: 24 };
    render(<DiscordPanel orgId={ORG} />);
    const sel2 = (await screen.findByLabelText('Automatic reminder')) as HTMLSelectElement;
    expect(sel2.value).toBe('24');
    fireEvent.change(sel2, { target: { value: '' } });
    await waitFor(() => expect(h.reminder).toHaveBeenCalledWith(ORG, null));
  });
});

describe('DiscordEventPanel', () => {
  it('says deleting the event takes it off Discord, and when the automatic reminder goes', async () => {
    h.event = parseDiscordEventStatus({ can_manage: true, event_status: 'published', has_webhook: true, guild_linked: true, guild_name: 'Blue Room',
      show: true, reminder_hours: 48, sync: { status: 'synced', on_discord: true, pending: false }, posts: [{ kind: 'publish', status: 'sent' }] });
    render(<DiscordEventPanel eventId={ORG} />);
    expect(await screen.findByText(/cancelling or deleting the event here takes it off there/)).toBeTruthy();
    expect(screen.getByText('Exos posts it by itself 48 hours before the start.')).toBeTruthy();
  });
});
