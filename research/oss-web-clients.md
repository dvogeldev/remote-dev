# Survey: OSS web clients to bolt in front of Hermes

Resolves ticket #28. Survey of self-hostable OSS chat UIs that could sit in
front of the Hermes agent process. Day-one scope (per #27): chat +
session list/continue + per-skill toggling on the `default` profile only.
The load-bearing requirement is **per-session skill toggling**.

Repo conventions for notes: this file lives in a new `research/` directory
because no existing convention matches a survey artifact. `convos/` is for
runbooks, `docs/adr/` is for architecture decisions.

## TL;DR

- **Carry forward as candidates**: LibreChat, LobeChat (LobeHub).
- **Rule out for day-one**: Open WebUI (license shape + chat-DB ownership),
  NextChat (no real multi-user auth, no per-session tool toggling).
- **Swing to custom** if per-session skill toggling cannot be made first-class
  in either candidate without a fork.

## Comparison table

Population: the four candidates named in #28 plus an explicit "rule-out" row
where applicable. Numbers are GitHub repo stats as of 2026-08-31.

| Project | Stars / issues | License | Backend protocol | Streaming | Auth | Session storage | Tools / skills / MCP | Mobile / PWA | Footprint (DB) | Multi-user shape |
|---|---|---|---|---|---|---|---|---|---|---|
| [Open WebUI](https://github.com/open-webui/open-webui) | 150.5k / 155 open | [Custom "Open WebUI License"](https://github.com/open-webui/open-webui/blob/main/LICENSE) (BSD-3-Clause-style with §4 branding-restriction clause; not OSI-approved) | OpenAI-compatible (`/v1/chat/completions`) plus Ollama, LMStudio, Groq, Mistral, OpenRouter, vLLM — point at any HTTP endpoint | SSE (OpenAI-compatible default) | Local user DB; OAuth/OIDC providers; LDAP/AD; SSO via trusted headers; SCIM 2.0 | Owns DB; conversations live in Open WebUI's storage (SQLite or Postgres) | [Filters, Actions, Pipes, Tools, Skills, MCP, MCPO, OpenAPI tool servers](https://github.com/open-webui/open-webui) | Responsive + PWA ("native app-like feel and offline access on localhost") | Docker image, SQLite (with optional encryption) or Postgres | First-class; granular RBAC + user groups |
| [LibreChat](https://github.com/danny-avila/LibreChat) | 42.7k / 352 open | [MIT](https://github.com/danny-avila/LibreChat) | OpenAI-compatible [Custom Endpoints](https://www.librechat.ai/docs/quick_start/custom_endpoints) (no proxy), plus Anthropic, AWS Bedrock, OpenAI, Azure, Google, Vertex, OpenAI Responses | SSE + [Resumable Streams](https://www.librechat.ai/docs/features/resumable_streams) (auto-reconnect / multi-tab) | Built-in user DB; OAuth2, LDAP, email login | Owns DB (MongoDB via `MONGODB_URI` in standard deploy) | Agents, [Skills](https://www.librechat.ai/docs/features/skills) (`SKILL.md` bundles, manual / automatic / always-on), MCP, Code Interpreter, Functions | Responsive web; PWA-installable per docs; no first-class native mobile app | MongoDB; Redis optional for sessions/streams | First-class; admin panel, per-user/groups permissions |
| [LobeChat / LobeHub](https://github.com/lobehub/lobehub) | 82.1k / 327 open | [LobeHub Community License](https://github.com/lobehub/lobehub/blob/canary/LICENSE) (Apache-2.0-based; commercial use OK as-is, derivative redistribution needs commercial license) | OpenAI-compatible custom providers; plus Anthropic, Google, Bedrock, Ollama, etc. via plugin providers | SSE via OpenAI-compatible | NextAuth: OAuth (Google/GitHub/etc), credentials, CAS, Clerk | Owns DB (Postgres via Drizzle ORM — `drizzle.config.ts` in repo); client-side IndexedDB cache | "10,000+ skills"; plugin/MCP marketplace; agents-as-unit-of-work | Responsive + dedicated mobile entry (`index.mobile.html`); PWA-capable | Postgres + S3-compatible object storage | First-class; multi-user with RBAC |
| [NextChat / ChatGPT-Next-Web](https://github.com/ChatGPTNextWeb/NextChat) | 88.7k / 706 open | [MIT](https://github.com/ChatGPTNextWeb/NextChat/blob/main/LICENSE) | OpenAI-compatible (`BASE_URL`), Azure, Gemini, Anthropic, DeepSeek, etc. (env-driven) | SSE ("support streaming response") | Single shared `CODE` env var (comma-separated passwords); not a real user system | Browser localStorage; optional UpStash Redis sync | MCP via `ENABLE_MCP=true` flag; not a first-class per-session concept | Responsive + PWA; [dedicated iOS app](https://apps.apple.com/us/app/nextchat-ai/id6743085599); Tauri desktop builds | None on server; client-side localStorage | Single-user pattern; multi-tenant is a hack |

## Per-project detail

### Open WebUI

- **License caveat**: §4 of the [LICENSE](https://github.com/open-webui/open-webui/blob/main/LICENSE) bars altering "Open WebUI" branding above 50 end users in any 30-day window unless an enterprise license is purchased. David is the only end user, so this is fine in practice — but it's source-available, not OSI-approved OSS. Worth flagging for the stack ticket.
- **Backend fit**: As of the README, Open WebUI happily proxies any OpenAI-compatible endpoint, so it can talk to Hermes once Hermes exposes one ([#29](https://github.com/dvogeldev/remote-dev/issues/29)).
- **Tools/skills fit**: First-class Tools + Skills + MCP per the README key-features list.
- **Per-session skill toggling**: Supported via per-user/per-group access controls on tools and models; admin can toggle on a session.
- **Sessions**: Conversations are stored in Open WebUI's DB, not Hermes's. If we want sessions to live with Hermes (so the CLI and the GUI share one session list), Open WebUI is a mismatch unless we accept a mirrored DB ([#32](https://github.com/dvogeldev/remote-dev/issues/32)).
- **Footprint**: Python/FastAPI backend + Svelte frontend. Single Docker image; SQLite is fine for single-user.

### LibreChat

- **License**: MIT — clean.
- **Backend fit**: [Custom Endpoints](https://www.librechat.ai/docs/quick_start/custom_endpoints) explicitly support OpenAI-compatible APIs without a proxy.
- **Tools/skills fit**: [Skills](https://www.librechat.ai/docs/features/skills) are `SKILL.md` bundles with manual/automatic/always-on triggers — semantically close to what Hermes calls "skills", though Hermes skills are addressed differently (Hermes skills are part of the agent profile). Worth probing in the [API surface ticket #29](https://github.com/dvogeldev/remote-dev/issues/29).
- **Per-session skill toggling**: Yes — agents in LibreChat are configurable per-conversation (skill selection per agent, and the agent chosen per chat). The closest analog to "per-session skill toggling" is "selecting which agent (and which tools are bound to it) starts this conversation".
- **Sessions**: MongoDB-backed; same DB-ownership concern as Open WebUI.
- **Resumable streams**: A real differentiator for the mobile/PWA path — connection drops recover automatically.
- **Auth**: OAuth2 / LDAP / email; the tunnel can sit in front and disable local auth, or we can lean on it for one local user.
- **Footprint**: Node + Mongo + optional Redis. Heavier than Open WebUI; ~3 services in the docker-compose.

### LobeChat / LobeHub

- **License**: [LobeHub Community License](https://github.com/lobehub/lobehub/blob/canary/LICENSE) — Apache-2.0-based. Commercial use as a service is fine; distributing a derivative work needs a commercial license. For our use case (self-host, don't redistribute a fork), this is fine.
- **Backend fit**: OpenAI-compatible custom providers plus native plugins for Anthropic, Google, Bedrock, Ollama, etc.
- **Tools/skills fit**: Plugin/MCP marketplace; "10,000+ skills". Agents are first-class.
- **Per-session skill toggling**: Agent configuration is per-conversation; agents bundle skills. Close fit.
- **Sessions**: Postgres-backed via Drizzle. Same DB-ownership caveat.
- **Mobile**: `index.mobile.html` in repo plus responsive web. The README markets it as a multi-agent workspace rather than a thin chat client — that's a feature, not a bug, but it's more surface than we strictly need for day one.
- **Footprint**: Postgres + S3-compatible storage; heavier than LibreChat.

### NextChat / ChatGPT-Next-Web

- **License**: MIT.
- **Backend fit**: OpenAI-compatible via `BASE_URL`. Easy.
- **Tools/skills fit**: MCP via `ENABLE_MCP=true`. No notion of per-session skill toggling — it's a thin client with optional MCP servers.
- **Auth**: `CODE` env var (shared password) is the auth model. Not a real user system, so single-user is the intended shape; multi-user is unsupported.
- **Sessions**: Browser localStorage by default. Optional UpStash Redis sync. No server-side session DB unless we add one — closer to Hermes-native (the GUI just stores UI state) than the other three, ironically.
- **Mobile**: Best mobile story of the four (responsive + PWA + dedicated iOS app).
- **Footprint**: Smallest. Static-ish Next.js app.
- **Why ruled out for day-one**: no per-session skill toggling, no real auth, no server-side session DB. Could be a fallback if the stack ticket (#30) wants a minimal wrapper around an OpenAI-compatible Hermes endpoint, but it doesn't earn its keep against LibreChat/LobeChat.

## What "carries forward" means

The ticket asks for 2–3 shortlist candidates with a paragraph each on
"why carry it forward" and "what it can't do that we'd need an adapter
or replacement for".

### LibreChat — carry forward

Most direct fit for "OpenAI-compatible frontend with real auth and
real per-agent/per-conversation tool selection". MIT-licensed and
self-hostable. Resumable streams are a real win for the mobile/PWA
path ([#34](https://github.com/dvogeldev/remote-dev/issues/34)).

**What it can't do out of the box**: own Hermes' session store. If we
want the CLI and the GUI to share one conversation list (the ideal),
LibreChat's MongoDB becomes a mirror, not the source of truth. That
needs an adapter in the [session-model ticket #32](https://github.com/dvogeldev/remote-dev/issues/32)
or an upstream contribution so LibreChat can delegate session listing
to an external API. Hermes skills are also addressed at the agent
profile level; LibreChat skills are `SKILL.md` bundles with manual /
auto / always-on triggers — close but not identical, so we'd want to
map one to the other in the [capability-surface ticket #33](https://github.com/dvogeldev/remote-dev/issues/33).

### LobeChat / LobeHub — carry forward

OpenAI-compatible, Apache-2.0-based license (with the commercial-use
clause noted above), strong plugin/MCP story, first-class agent
configuration per conversation. Best "per-session skill toggling"
ergonomics of the four. Mobile entry (`index.mobile.html`) is
production-grade.

**What it can't do out of the box**: lighter-weight than we need — the
README sells it as a multi-agent workspace, not a thin chat client.
Also Postgres-backed, so the same session-DB ownership question as
LibreChat applies. License is Apache-2.0-based but commercial use
hinges on not redistributing a derivative; for self-host-as-is this is
fine, but if we ever publish a fork we need to revisit.

### Open WebUI — marginal

Most popular of the four and the most polished UX. License is
source-available with a branding clause that limits re-branding above
50 end users; we're single-user so it's compliant, but it's not
OSI-approved OSS. Conversations live in Open WebUI's DB by default;
needs the same session-DB adapter story as LibreChat.

**Why not on the shortlist**: license shape (not OSI OSS) plus the
session-DB ownership cost. Worth a mention as the "if the others don't
fit, this is the safe fallback" option, but not a first-tier candidate
for the stack ticket.

### NextChat — ruled out for day-one

Clean MIT, smallest footprint, best mobile story. Fails the
per-session skill toggling requirement and has no real auth model.
Worth keeping in mind if [#33](https://github.com/dvogeldev/remote-dev/issues/33)
collapses to "just chat, no skill UX".

## Open questions for downstream

- [ ] Does Hermes expose an OpenAI-compatible `/v1/chat/completions` endpoint, or does LibreChat/LobeChat need an adapter? ([#29](https://github.com/dvogeldev/remote-dev/issues/29))
- [ ] How do Hermes "skills" map onto LibreChat "Skills" or LobeChat "plugins"? ([#33](https://github.com/dvogeldev/remote-dev/issues/33))
- [ ] Can sessions live in Hermes' store (CLI + GUI share state) or does the GUI own them? ([#32](https://github.com/dvogeldev/remote-dev/issues/32))
- [ ] Does the single-user constraint make the Open WebUI license non-issue, or do we want to avoid source-available licenses on principle?