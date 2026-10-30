// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';

vi.mock('../lib/supabase', () => ({ supabase: {} }));

import EventArtistLineup from './EventArtistLineup';
import { parseLineup } from '../lib/artists';

afterEach(cleanup);

const SP = '4Z8W4fKeB5YxbusRsdQVPb';

describe('EventArtistLineup', () => {
  it('renders the acts in running order with act types and Spotify links', () => {
    const lineup = parseLineup([
      { id: 's2', artist_id: 'b', act_type: 'dj', position: 2, artist: { id: 'b', name: 'Nova Echo', permalink: 'nova-echo' } },
      { id: 's1', artist_id: 'a', act_type: 'headline', position: 1, artist: { id: 'a', name: 'Lumen', permalink: 'lumen', spotify_id: SP } },
    ]);
    render(<EventArtistLineup lineup={lineup} timezone="America/New_York" />);
    const slots = screen.getAllByTestId('lineup-slot');
    expect(slots.map((s) => s.textContent)).toEqual([expect.stringContaining('Lumen'), expect.stringContaining('Nova Echo')]);
    expect(slots[1].textContent).toContain('DJ');
    expect(screen.getByRole('link', { name: 'Listen to Lumen on Spotify' }).getAttribute('href')).toBe(`https://open.spotify.com/artist/${SP}`);
    expect(screen.queryByRole('link', { name: 'Listen to Nova Echo on Spotify' })).toBeNull();
  });

  it('renders nothing without a lineup', () => {
    const { container } = render(<EventArtistLineup lineup={[]} />);
    expect(container.innerHTML).toBe('');
  });
});
