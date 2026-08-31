# Hermes HTTP/streaming API surface today

> Resolves [#29](https://github.com/dvogeldev/remote-dev/issues/29).
> Parent: [#27](https://github.com/dvogeldev/remote-dev/issues/27) (Hermes GUI map).
> Sources are cited inline. All claims trace to a primary doc page or the upstream GitHub repo.

## TL;DR

Hermes Agent does not expose a single HTTP API — it exposes **two distinct servers** in v0.21.0 (released 2026-08-31), each on a different port and a different protocol surface:

| Server | Default port | Auth | Protocol | Purpose |
| --- | --- | --- | --- | --- |
| `hermes dashboard` / `hermes serve` (the **management plane**) | **9119** | Bearer/session cookie, **engaged only when bound off-loopback** | FastAPI + REST + WebSocket (`/api/pty`) | Browser dashboard SPA + embedded TUI; profile/env/config/cron/sessions admin |
| `hermes gateway` with `API_SERVER_ENABLED=true` (the **chat plane**) | **8642** | **Bearer token (`API_SERVER_KEY`) required, even on loopback** | OpenAI-compatible REST + SSE + Hermes-native runs | Drop-in backend for Open WebUI, LobeChat, LibreChat, anything that speaks `/v1` |

Neither is "the Hermes API" — they answer different questions. **The GUI wants the chat plane (8642).** The management plane (9119) is what powers Hermes Desktop and the bundled React dashboard and is not necessary for a custom web GUI.

Full release pinning: the installer at <https://hermes-agent.nousresearch.com/install.sh> tracks `BRANCH="main"` by default and pulls from `https://github.com/NousResearch/hermes-agent.git` (`REPO_URL_HTTPS` in the script). The currently advertised version on the homepage banner reads "Hermes Agent v0.21.0" ([landing page](https://hermes-agent.nousresearch.com/)). The `v0.21.0` GitHub release is tagged `v2026.8.31`, commit `29112be`, released 2026-08-31 ([GitHub releases](https://github.com/NousResearch/hermes-agent/releases)).

---

## 1. The two servers

### 1a. Chat plane — `API_SERVER_ENABLED=true` on `hermes gateway` (port 8642)

This is the load-bearing surface for a custom GUI. It is **not enabled by default** — you set `API_SERVER_ENABLED=true` (and `API_SERVER_KEY=…`) in `~/.hermes/.env`, then start `hermes gateway`. Startup line confirms it:

```
[API Server] API server listening on http://127.0.0.1:8642
```

Source: [API Server docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server).

**Defaults from the same doc page:**

| Variable | Default | Notes |
| --- | --- | --- |
| `API_SERVER_ENABLED` | `false` | |
| `API_SERVER_PORT` | `8642` | |
| `API_SERVER_HOST` | `127.0.0.1` | Loopback-only by default; bind to `0.0.0.0` to expose |
| `API_SERVER_KEY` | *(required)* | Bearer auth; docs explicitly say "required for every deployment, including the default loopback bind" |
| `API_SERVER_CORS_ORIGINS` | unset | Off by default; explicit allowlist required for browser clients |
| `API_SERVER_MODEL_NAME` | profile name | The model name advertised on `/v1/models` |

**Concurrent-run cap** (`gateway.api_server.max_concurrent_runs`, default **10**) returns HTTP 429 when saturated. Same source.

### 1b. Management plane — `hermes dashboard` / `hermes serve` (port 9119)

This is the FastAPI server that powers Hermes Desktop and the React/Vite dashboard SPA. `hermes serve` is the **headless** variant — same server, no browser UI auto-open. CLI reference confirms:

> `hermes serve` — Start the Hermes **backend server** (headless; powers the desktop app and remote backends). … default port `9119`. A non-loopback bind engages the same auth gate.

Source: [CLI Commands Reference → `hermes serve` / `hermes dashboard`](https://hermes-agent.nousresearch.com/docs/reference/cli-commands).

This server ships the `/api/...` REST API documented in the [Web Dashboard docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard) (config, env, sessions, logs, analytics, cron, profiles, skills, MCP, messaging platforms, webhooks, pairing, curator, ops, system stats, pty) plus the WebSocket that hosts the embedded TUI. It is **not the right surface to build a chat GUI on top of** — those `/api/...` routes are management CRUD, not chat.

**Auth on 9119 (relevant for the GUI's tunnel/Access story):**

- Loopback bind → no auth, no login page.
- Non-loopback bind → auth gate **engages automatically**, **fail-closed**. `--insecure` was removed in the June 2026 hardening; binding to `0.0.0.0` always requires either Nous Portal OAuth (`hermes dashboard register`) or the username/password provider.
- `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` + `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` (+ `HERMES_DASHBOARD_BASIC_AUTH_SECRET`) for the password provider.

Source: [Web Dashboard → Authentication (gated mode)](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard).

> Operational note for our VPS deployment: **port 9119 is where the bundled dashboard already lives.** Putting a custom GUI on 9119 would collide with the official dashboard. A custom GUI should bind `0.0.0.0:8642` (the chat plane) behind Cloudflare Access, and leave 9119 loopback-only for the operator's own browser tunnel.

---

## 2. Endpoint inventory on the chat plane (port 8642)

All paths and behaviors are from [API Server docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server). Every route below requires `Authorization: Bearer $API_SERVER_KEY` unless called out as public.

### 2a. OpenAI-compatible (`/v1/...`)

| Method | Path | Notes |
| --- | --- | --- |
| `POST` | `/v1/chat/completions` | Stateless. Full transcript in `messages`. SSE on `"stream": true` with `chat.completion.chunk` + Hermes' own `hermes.tool.progress` event. |
| `POST` | `/v1/responses` | OpenAI Responses API. Server-side state via `previous_response_id` or named `conversation`. Multi-turn context preserved without client managing it. Stored responses capped at **100 (LRU eviction)** — see Limitations. |
| `GET` | `/v1/responses/{id}` | Retrieve a stored response. |
| `DELETE` | `/v1/responses/{id}` | Delete a stored response. |
| `GET` | `/v1/models` | OpenAI-compat model list. Returns a single alias — defaults to profile name (or `hermes-agent` for default profile). Intentionally minimal; use `/api/model/options` for the richer picker. |
| `GET` | `/v1/capabilities` | Machine-readable surface advert: `chat_completions`, `responses_api`, `run_submission`, `run_status`, `run_events_sse`, `run_stop`, `run_approval`, plus per-feature flags and `endpoints.session_*`. Designed exactly for an external UI to discover support before rendering controls. |
| `GET` | `/v1/skills` | Skill catalog (name, description, category) for the active profile. |
| `GET` | `/v1/toolsets` | Toolsets with `tools[]` for the `api_server` platform. |
| `GET` | `/health` and `/v1/health` | Public. `{"status":"ok"}`. |
| `GET` | `/health/detailed` | Authenticated. Readiness — config/state/model/disk/gateway/runs/delegations. Coarse counts, never secrets. Always returns HTTP 200; inspect `status` and `readiness.checks`. |

**Inline image input** is supported on `/v1/chat/completions` and `/v1/responses`. **Uploaded files are not** (`file`, `input_file`, `file_id`, non-image `data:` URLs return `400 unsupported_content_type`). — Source: API Server docs.

**Per-request model selection** on `/v1/chat/completions`, `/v1/responses`, `/v1/runs`, `/api/sessions/{id}/chat`, `/api/sessions/{id}/chat/stream`:

- `model` (target model id), `provider` (Hermes provider slug), `model_options` (request-scoped reasoning/service-tier controls).
- Precedence: session `/model` override → `gateway.platforms.api_server.model_routes` alias → direct request → gateway default.
- **Bare `model` on the OpenAI-compatible endpoints is opt-in**: a generic OpenAI client hardcoding `gpt-4o` would normally fall back to the gateway default. To force the request's `model` to win, set `gateway.platforms.api_server.direct_model_requests: true`. Sending an explicit `provider` always honors the requested model regardless.

### 2b. Hermes-native runs (`/v1/runs/...`) — the streaming-friendly layer

| Method | Path | Notes |
| --- | --- | --- |
| `POST` | `/v1/runs` | Create a run. Returns `{run_id, status: "started"}`. Accepts `Idempotency-Key` (1–255 visible ASCII) — replayed retries return the original `run_id` with HTTP 202 `Idempotency-Replayed: true` for up to **24h** after the last status update. Reusing the same key with a different payload returns HTTP 409 `idempotency_key_conflict`. |
| `GET` | `/v1/runs/{run_id}` | Poll current state — useful when the SSE connection is gone. |
| `GET` | `/v1/runs/{run_id}/events` | **SSE** of run lifecycle: tool-call progress, token deltas, `subagent.start`/`subagent.complete`, completion. Unconsumed event buffer expires after **5 min** (transport state only — the run itself keeps running). |
| `POST` | `/v1/runs/{run_id}/stop` | Returns `{"status":"stopping"}` immediately; run settles to `cancelled` after the executor-backed work exits. |
| `POST` | `/v1/runs/{run_id}/approval` | Resolve a pending human approval (e.g. dangerous-command gate). Advertised in `/v1/capabilities` as `run_approval`. |

### 2c. Sessions API (`/api/sessions/...`) — REST over the same plane

For GUI authors this is the most useful set of routes; all gated by `API_SERVER_KEY`.

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/api/sessions` | Paginated list. Query: `limit`, `offset`, `source`, `include_children`. |
| `POST` | `/api/sessions` | Create empty session. |
| `GET` | `/api/sessions/{id}` | Session metadata. |
| `PATCH` | `/api/sessions/{id}` | Update `title` or `end_reason`. |
| `DELETE` | `/api/sessions/{id}` | Delete session. |
| `GET` | `/api/sessions/{id}/messages` | Message history (paginated). |
| `POST` | `/api/sessions/{id}/fork` | Branch session via `SessionDB` lineage — matches CLI `/branch`. |
| `POST` | `/api/sessions/{id}/chat` | One synchronous agent turn. |
| `POST` | `/api/sessions/{id}/chat/stream` | **SSE wrapper**: `assistant.delta`, `tool.started`, `tool.completed`, `run.completed`. |

### 2d. Jobs (cron) — `/api/jobs/...`

`GET / POST / GET / PATCH / DELETE` and `…/pause`, `…/resume`, `…/run`. Same bearer auth. Mirrors `hermes cron` shape.

### 2e. Models and discovery — `/api/...`

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/api/model/options` | Hermes-aware model inventory — providers, curated model lists, pricing, capability hints. Same substrate the bundled dashboard Models page and TUI `model.options` RPC use. Pass `?refresh=1` to bust the cache and probe all custom endpoints. |
| `POST` | `/v1/browser-control/register` | Authenticated. Register a browser-controller extension; returns a single-use 30-second ticket. |
| `GET` | `/v1/browser-control/ws` | WebSocket with subprotocols `hermes-browser-control-v1` + `hermes-browser-control-ticket.<ticket>`. Ticket never accepted in query string. |

### 2f. Multi-profile routing — `/p/<profile>/...`

When `gateway.multiplex_profiles` is enabled, the shared listener serves every profile through a `/p/<profile>/` URL prefix and **authentication is bound to the routed profile**:

- `/p/<profile>/v1/...` requires that profile's own `API_SERVER_KEY` (from `~/.hermes/profiles/<profile>/.env`). The default listener's key is rejected on named-profile prefixes.
- Unprefixed routes and `/p/default/...` keep using the default profile's key.
- A named profile with no `API_SERVER_KEY` of its own fails closed — its prefix is unreachable until you set one.

**Breaking change (July 2026)**: a valid default-profile key used to be accepted on any `/p/<profile>/` prefix; now it returns 401. Each named profile needs its own key.

---

## 3. What the API server gives us per the ticket's 10-point checklist

Cross-referencing the [ticket body](https://github.com/dvogeldev/remote-dev/issues/29):

1. **Default Hermes server** — two. `hermes serve` / `hermes dashboard` on **9119** (management, FastAPI+WebSocket, React SPA) and `API_SERVER_ENABLED=true` on `hermes gateway` on **8642** (chat, OpenAI-compat + native). Both CLI references verified at [CLI Commands Reference](https://hermes-agent.nousresearch.com/docs/reference/cli-commands).
2. **Protocols** — `/v1/chat/completions` (OpenAI), `/v1/responses` (OpenAI Responses, with server-side state), plus Hermes-native `/v1/runs` and `/api/sessions/{id}/chat(/stream)`. **No `/v1/messages` (Anthropic).**
3. **Session endpoints** — full CRUD + fork + chat + chat/stream under `/api/sessions/...`. No need to scrape `~/.hermes/sessions/` from disk.
4. **Streaming** — both SSE and `stream: true` on OpenAI routes; `chat/stream` SSE with structured events. Token-by-token. **No public WebSocket for chat** (the WebSocket on 8642 is only for browser-control).
5. **Skill toggling** — `GET /v1/skills` enumerates; **`PUT /api/skills/toggle` lives on the management plane (9119)**, not 8642. So per-session skill enable/disable is **not exposed on the chat plane**. The dashboard exposes per-skill enable/disable on the profile-wide `~/.hermes/skills/` directory; runtime per-session skill toggling is implicit (the agent's `/skills` command).
6. **Profile switching** — first-class on the chat plane via the `/p/<profile>/` prefix. Day-one `default` profile is the unprefixed listener. To isolate users later, set `gateway.multiplex_profiles: true` and stand up one `.env` per profile.
7. **Tool approvals** — `POST /v1/runs/{run_id}/approval` resolves pending approvals. Advertised in `/v1/capabilities` as `run_approval`. **This is the host-plane approval handshake** — the GUI should turn this on (it's `approvals.mode: smart` in `config.yaml` per the [Security docs](https://hermes-agent.nousresearch.com/docs/user-guide/security)) and render the approval prompt on the SSE stream.
8. **Auth on the Hermes port itself** — bearer-token **always required** for 8642, even on loopback (the docs are explicit). For 9119, loopback is open and non-loopback engages a fail-closed gate (Nous OAuth or basic auth).
9. **Version pinning** — Hermes Agent v0.21.0, tag `v2026.8.31`, commit `29112be`, released 2026-08-31 ([GitHub releases](https://github.com/NousResearch/hermes-agent/releases)). Install script pins `BRANCH="main"` by default; the API server surface has been stable since at least v0.20.0 (the `direct_model_requests` toggle and `/p/<profile>/` breaking change note both reference "July 2026", predating the v0.20.0 release on 2026-08-03).
10. **Known gaps for a GUI**:
    - **No WebSocket for chat.** SSE is the only streaming transport. That's fine for browsers (`EventSource`) and `fetch`+streams on the server side, but it rules out bidirectional channels.
    - **No Anthropic-compat `/v1/messages`** — only OpenAI Responses + Hermes-native runs. Bolt-on OSS frontends expecting Anthropic shape need a thin shim.
    - **`PUT /api/skills/toggle` lives on 9119, not 8642.** Per-session skill enable/disable at runtime is not on the chat plane.
    - **No file upload** — inline images only. Document/file attachments go through other channels.
    - **Stored responses capped at 100 (LRU).** Multi-turn on `/v1/responses` is fine; deep archives need offload.
    - **`Idempotency-Key` cached 5 min on the chat plane** (HTTP-level), and **24 h** on `/v1/runs` (durably retained for replay).
    - **CORS off by default.** If the GUI is browser-side on a different origin, you must set `API_SERVER_CORS_ORIGINS` explicitly.
    - **No `/v1/models` enrichment** — it advertises a single alias. The richer picker (`/api/model/options`) is Hermes-specific; OpenAI-compat clients see only the alias.
    - **`API_SERVER_KEY` is required even on loopback**, and a separate key per profile is required once `/p/<profile>/...` is engaged.

---

## 4. Bolt-on OSS vs custom adapter — one-paragraph sketch

**Bolt-on OSS path (Open WebUI, LobeChat, LibreChat, NextChat, AnythingLLM, Jan, HF Chat-UI, big-AGI — all listed in the [API Server compatible-frontends table](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server))**: point the frontend at `http://<host>:8642/v1` with `OPENAI_API_BASE_URL` / `OPENAI_API_KEY` set to the bearer; you immediately get a polished chat UI with conversations, model picker, multi-user (one profile per user via `/p/<profile>/`), and tool progress streamed inline via SSE. The [Open WebUI integration guide](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/open-webui) walks it end-to-end. This is the **fastest path to "Hermes GUI" today** and should be the first thing we stand up behind Cloudflare Tunnel + Access to validate the stack; it removes zero risk because every endpoint it touches is on the documented API server surface.

**Custom adapter path (what our own GUI would write)**: build a thin frontend that talks `/v1/chat/completions` (with `stream: true` for token deltas plus `hermes.tool.progress` events for inline tool-start UX) for the chat surface, plus `/api/sessions/...` for the conversation list / branch / messages / sync turn / SSE wrapper. For "approval gates" the GUI listens for `run_approval` in `/v1/capabilities` and posts decisions to `/v1/runs/{run_id}/approval`. Profile switching is `/p/<profile>/...` from day one (even if we only ship `default` at first). Long-term memory scoping is the `X-Hermes-Session-Key` header on chat/responses/runs — needed to keep Honcho's per-channel identity stable across `/new`. The custom adapter is justified only if the bolt-on OSS path can't deliver a specific UX we commit to (e.g. tight TUI parity on a phone, custom approval UX, or surfacing `X-Hermes-Session-Key` correctly).

---

## Sources

Primary, all consulted 2026-08-31:

- [API Server docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server) — endpoints, env vars, auth, profile routing, runs, jobs, sessions, capabilities.
- [Web Dashboard docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard) — port 9119 server, REST API, auth gate, fail-closed semantics.
- [CLI Commands Reference](https://hermes-agent.nousresearch.com/docs/reference/cli-commands) — `hermes serve`, `hermes dashboard`, `hermes gateway`, `hermes chat`, `hermes sessions`, `hermes proxy`, `hermes security`, `hermes peer`.
- [Open WebUI integration guide](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/open-webui) — the reference bolt-on path.
- [Hermes Agent landing](https://hermes-agent.nousresearch.com/) and [install.sh](https://hermes-agent.nousresearch.com/install.sh) — version banner, install pinning.
- [GitHub releases](https://github.com/NousResearch/hermes-agent/releases) — `v0.21.0` tag, `v2026.8.31`, commit `29112be`.
- [GitHub repo](https://github.com/NousResearch/hermes-agent) — repo layout (`apps/`, `hermes_cli/`, `web/`, `gateway/`, `acp_adapter/`).
