(function () {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const state = { eventId: null, qty: 2 };

  const money = (n) => n == null ? '—' : '$' + Number(n).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const when = (iso) => {
    if (!iso) return '';
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return iso;
    return d.toLocaleString('en-US', { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
  };
  const age = (m) => m == null ? '' : m < 1 ? 'just now' : m < 60 ? `${m} min ago` : `${Math.round(m / 60)} h ago`;
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };

  function showError(msg) { const e = $('error'); e.textContent = msg; e.hidden = !msg; }

  async function api(path) {
    const r = await fetch(path, { headers: { Accept: 'application/json' } });
    if (!r.ok) {
      let detail = `Request failed (${r.status})`;
      try { const j = await r.json(); if (j.detail) detail = typeof j.detail === 'string' ? j.detail : detail; } catch (_) { /* keep default */ }
      throw new Error(detail);
    }
    return r.json();
  }

  // ---------- search ----------
  $('searchForm').addEventListener('submit', async (ev) => {
    ev.preventDefault();
    showError('');
    const q = $('q').value.trim();
    if (q.length < 2) return;
    $('searchBtn').disabled = true;
    try {
      const data = await api(`/api/search?q=${encodeURIComponent(q)}`);
      renderResults(data.events);
    } catch (err) {
      showError(err.message);
    } finally {
      $('searchBtn').disabled = false;
    }
  });

  function renderResults(events) {
    const ul = $('results'); ul.textContent = '';
    $('resultsSection').hidden = false;
    $('resultsNote').hidden = events.length > 0;
    $('resultsNote').textContent = 'No upcoming events match. Try a team, artist or venue name.';
    for (const e of events) {
      const li = el('li');
      const b = el('button'); b.type = 'button';
      b.append(el('span', 'name', e.name), el('span', 'when', when(e.starts_at_local)),
               el('span', 'meta', [e.venue, e.location].filter(Boolean).join(' · ')));
      b.addEventListener('click', () => loadCompare(e.id));
      li.append(b); ul.append(li);
    }
  }

  // ---------- compare ----------
  $('qty').addEventListener('change', () => { state.qty = Number($('qty').value); if (state.eventId) loadCompare(state.eventId); });
  $('refreshBtn').addEventListener('click', () => { if (state.eventId) loadCompare(state.eventId); });

  async function loadCompare(id) {
    state.eventId = id;
    showError('');
    $('compareSection').hidden = false;
    $('ladder').setAttribute('aria-busy', 'true');
    try {
      const data = await api(`/api/events/${id}/compare?qty=${state.qty}`);
      renderCompare(data);
      history.replaceState(null, '', `?event=${id}&qty=${state.qty}`);
      $('compareSection').scrollIntoView({ behavior: 'smooth', block: 'start' });
    } catch (err) {
      showError(err.message);
    } finally {
      $('ladder').removeAttribute('aria-busy');
    }
  }

  const STATUS_TEXT = {
    no_fresh_prices: 'No fresh prices captured yet.',
    not_listed: 'Not listed here for this event.',
    no_match_for_qty: (s, qty) => `${s.listings_total} listings, none sold in lots of ${qty}.`,
  };

  function renderCompare(data) {
    const ev = data.event;
    $('evName').textContent = ev.name;
    $('evMeta').textContent = [when(ev.starts_at_local), ev.venue, ev.location].filter(Boolean).join(' · ');
    $('feesNote').textContent = data.fees_note;
    const ladder = $('ladder'); ladder.textContent = '';
    for (const s of data.sources) {
      const box = el('div', 'src' + (s.key === data.cheapest_buyable ? ' winner' : ''));
      const label = el('div', 'label', s.label);
      if (s.key === data.cheapest_buyable) label.append(el('span', 'chip win', 'cheapest'));
      if (!s.buyable) label.append(el('span', 'chip ref', 'reference only'));
      box.append(label);
      if (s.cheapest) {
        const price = el('div', 'price', money(s.cheapest.total));
        price.append(el('small', null, `${data.qty} × ${money(s.cheapest.unit_price)} · ${age(s.age_minutes)}`));
        box.append(price);
        const d = el('div', 'detail');
        d.append(`Sec ${s.cheapest.section || '—'}, row ${s.cheapest.row || '—'} `);
        d.append(el('span', 'muted', `· ${s.listings_for_qty} of ${s.listings_total} listings fit ${data.qty}`));
        box.append(d);
        const actions = el('div', 'actions');
        if (s.buyable) {
          const a = el('a', 'btn buy', `Buy on ${s.label}`);
          if (s.cheapest.buy_url) { a.href = s.cheapest.buy_url; a.target = '_blank'; a.rel = 'noopener'; }
          else { a.setAttribute('aria-disabled', 'true'); a.textContent = 'No direct link'; }
          actions.append(a);
        }
        box.append(actions);
        if (s.ladder.length > 1) {
          const det = el('details'); det.append(el('summary', null, `Show ${s.ladder.length} cheapest`));
          const t = el('table');
          const thead = el('thead'); const tr = el('tr');
          for (const h of ['Section', 'Row', 'Lot']) tr.append(el('th', null, h));
          tr.append(el('th', 'num', 'Each')); tr.append(el('th', 'num', `Total ×${data.qty}`)); tr.append(el('th', null, ''));
          thead.append(tr); t.append(thead);
          const tb = el('tbody');
          for (const l of s.ladder) {
            const r = el('tr');
            const sec = el('td', null, l.section || '—');
            for (const tag of l.tags) sec.append(el('span', 'tag', tag));
            r.append(sec, el('td', null, l.row || '—'), el('td', null, String(l.quantity ?? '—')),
                     el('td', 'num', money(l.unit_price)), el('td', 'num', money(l.total)));
            const link = el('td');
            if (l.buy_url) { const a = el('a', null, 'buy'); a.href = l.buy_url; a.target = '_blank'; a.rel = 'noopener'; link.append(a); }
            r.append(link); tb.append(r);
          }
          t.append(tb); det.append(t); box.append(det);
        }
        if (s.note) box.append(el('div', 'status', s.note));
      } else {
        const txt = STATUS_TEXT[s.status];
        box.append(el('div', 'status', typeof txt === 'function' ? txt(s, data.qty) : (txt || 'No prices.')));
      }
      ladder.append(box);
    }
  }

  // Deep link: ?event=<id>&qty=<n>
  const params = new URLSearchParams(location.search);
  const deep = Number(params.get('event'));
  const dq = Number(params.get('qty'));
  if (dq >= 1 && dq <= 12) { state.qty = dq; $('qty').value = String(dq); }
  if (deep > 0) loadCompare(deep);
})();
