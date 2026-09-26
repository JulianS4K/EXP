# Marketplace API references

Vendor API docs for the secondary marketplaces Exos distributes into (see
`docs/d4_bridge_charter.md` §2 and `supabase/functions/exos-distribute`).

| Marketplace | Folder | Snapshot |
|---|---|---|
| StubHub | [`stubhub/`](stubhub/README.md) | 2026-09-14 (API v2.249.0.0, Catalog v1.0.0.75) |

Each folder has the vendor PDFs as printed (`pdf/`), a plain-text extraction
for grep (`text/`), and a README with the endpoint map.

**Hard Rule #2 applies** (see `CLAUDE.md`): upstream ticketing APIs are
read-only. Every endpoint is tagged below as **read** or **write**. A write
(listing create/update/delete, sale fulfilment, account or webhook changes)
needs explicit operator authorization before any code calls it, per the
charter's §6.1 carve-out process.
