# Open Brain Setup + MCP Wiring — System Capture

**Purpose:** Snapshot of how Open Brain is actually deployed on this machine and which agents talk to it via MCP, so future sessions don't have to rediscover it.
**Date captured:** 2026-09-08
**Related:** `docs/adr/0006-open-brain-is-a-resource.md`, `convos/memory-hermes.md` (§5 layer roles), `CONTEXT.md` (agency tree)

---

## 1. What Open Brain is here

A personal "second brain" in the Nate B. Jones pattern: **Supabase Postgres + pgvector + MCP**. It is the *capture bus* for raw thoughts ("what I noticed today"), not canon, not the graph, not a task list (ADR 0006).

- **Host:** Supabase project `crgdufvwyfgbzobtnwcw`
- **Source repo (local):** `~/projects/openbrain` — Deno edge functions + Node bulk-ingest scripts
- **Embeddings:** OpenRouter (`openai/text-embedding-3-small`); metadata extraction via `openai/gpt-4o-mini`
- **Semantic search:** Supabase RPC `match_thoughts` (pgvector cosine similarity, default threshold 0.3)

## 2. Supabase edge functions (`~/projects/openbrain/supabase/functions/`)

| Function | Purpose |
|---|---|
| `open-brain-mcp` | The MCP server (369 lines). Streamable HTTP transport via Hono; auth = `x-brain-key` header or `?key=` query param checked against `MCP_ACCESS_KEY` secret |
| `ingest-thought` | Single-thought HTTP ingest endpoint |
| `ingest-telegram` | Telegram-side ingest (service-role key) |

### MCP tools exposed by `open-brain`

| Tool | What it does |
|---|---|
| `search_thoughts` | Semantic search by meaning (query, limit, threshold) |
| `list_thoughts` | Recent thoughts, filterable by type/topic/person/time |
| `thought_stats` | Totals, types, top topics, people |
| `capture_thought` | Write a standalone, self-contained thought + embedding |

Note: `capture_thought` runs an LLM metadata-extraction pass (topics, people, type) over the content before storing.

## 3. Bulk ingest (bypasses MCP)

`~/projects/openbrain/` (Node, config via `.env` there):

- `ingest-notes.js` — markdown notes from `~/00-staging/notes` (parent dir only) directly into Supabase
- `ingest-grok.js` — x.ai/Grok conversation export (`~/prod-grok-backend.json`, MongoDB-style timestamps) into Supabase

Both use `SUPABASE_SERVICE_ROLE_KEY` + `OPENROUTER_API_KEY` from the local `.env`. These are bulk paths only; the day-to-day write path is the MCP `capture_thought` tool.

## 4. Which agents are wired to it (MCP clients)

| Client | Config file | Servers |
|---|---|---|
| **OpenCode** | `~/.config/opencode/opencode.json` | `open-brain` (remote), `notebooklm` (local, `npx notebooklm-mcp@latest`), `decster` (remote) |
| **Kilo** | `~/.config/kilo/kilo.jsonc` | `open-brain` (remote; `capture_thought` pre-allowed in permissions), plus DigitalOcean (stdio), Cloudflare remote set (mcp / docs / bindings / builds / observability) |

Connection string is the same in both: `https://crgdufvwyfgbzobtnwcw.supabase.co/functions/v1/open-brain-mcp?key=<anon key>` — the key travels in the URL query param. Pi (this harness) and Hermes are **not** wired to it; per ADR 0006, Hermes on `default` reads Open Brain via MCP only when a wiki page or method needs context, and the repo policy is inbox-files-first.

## 5. Secrets map (do not commit these)

| Secret | Where it lives |
|---|---|
| `MCP_ACCESS_KEY` | Supabase function secret (env var on the function) |
| Supabase anon key (in MCP URL) | `~/.config/opencode/opencode.json`, `~/.config/kilo/kilo.jsonc` |
| `SUPABASE_SERVICE_ROLE_KEY`, `OPENROUTER_API_KEY` | `~/projects/openbrain/.env` |
| DigitalOcean token (Kilo stdio MCP) | `~/.config/kilo/kilo.jsonc` — **never copy into this repo** |

Per ADR 0007, the laptop `pass` tree is the source of truth for secrets.

## 6. Open items

- Open Brain is the only always-on knowledge service besides Hermes itself; Cognee/graph layer is still future work (see `convos/memory-hermes.md` §10–11).
- `ingest-thought` (HTTP) vs MCP `capture_thought` overlap — one write path could be retired.
- If the anon key in the URL ever leaks (it sits in plaintext configs), rotate in the Supabase dashboard and update both client configs.
