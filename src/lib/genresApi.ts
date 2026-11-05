// The genres of upcoming published, listed events, through the existing anon
// discovery RPC (exos_api_public 'genres.list', mig 20261106140000). Rate
// limited per network like the rest of public discovery; an error (or the
// migration not applied yet) answers an empty list.

import { supabase } from './supabase';
import { parseGenreList, type GenreChip } from './genres';

export async function listPublicGenres(): Promise<GenreChip[]> {
  try {
    const { data, error } = await supabase.rpc('exos_api_public', { p_action: 'genres.list', p_target: null, p_args: {} });
    if (error) return [];
    return parseGenreList(data);
  } catch {
    return [];
  }
}
