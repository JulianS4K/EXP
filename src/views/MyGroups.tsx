// /groups — the group chats I'm in (mig 20261031230000, docs/group-chat.md).

import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { MessageSquare } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { closesLabel, myGroups, type MyGroup } from '../lib/groupChat';

export default function MyGroups() {
  const { user, openAuth } = useAuth();
  const [groups, setGroups] = useState<MyGroup[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!user) return;
    myGroups().then(setGroups).catch((e) => setError((e as Error).message));
  }, [user]);

  if (!user) return (
    <div className="wall min-h-screen flex flex-col items-center justify-center px-4 py-20 text-center">
      <p className="type text-white/60 uppercase tracking-widest text-[12px] mb-4">Sign in to see your group chats</p>
      <button type="button" onClick={() => openAuth('options')} className="bg-brand-primary text-black font-black uppercase tracking-wider px-6 py-3">Sign in</button>
    </div>
  );

  return (
    <div className="wall min-h-screen px-4 py-10 sm:px-8">
      <div className="max-w-2xl mx-auto">
        <h1 className="disp text-3xl sm:text-4xl tracking-tight mb-6">Group chats</h1>
        {error && <p className="type text-xs text-red-400" role="alert">{error}</p>}
        {groups === null && !error && <p className="type text-xs text-white/50" role="status">Loading…</p>}
        {groups?.length === 0 && (
          <p className="type text-sm text-white/60">No groups yet. When an organizer adds you to a table or you join an event's chat, it shows up here.</p>
        )}
        <ul className="divide-y divide-white/10 border border-white/10">
          {groups?.map((g) => (
            <li key={g.id}>
              <Link to={`/groups/${g.id}`} className="flex items-center gap-3 p-4 hover:bg-white/[0.04] focus:bg-white/[0.04]">
                <MessageSquare className="w-5 h-5 text-brand-primary shrink-0" aria-hidden="true" />
                <span className="flex-1 min-w-0">
                  <span className="block text-white truncate">{g.title}</span>
                  <span className="type block text-[11px] text-white/50">
                    {closesLabel(g.closesAt) ?? 'Open'}
                    {g.lastMessageAt ? ` · last message ${g.lastMessageAt.toLocaleString()}` : ''}
                  </span>
                </span>
              </Link>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
