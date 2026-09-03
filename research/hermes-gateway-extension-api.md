# Hermes messaging-gateway extension API

> Resolves [#37](https://github.com/dvogeldev/remote-dev/issues/37).
> Parent (wayfinder map): [#36](https://github.com/dvogeldev/remote-dev/issues/36) ("Hermes ↔ Buzz channel").
> Sibling tickets: [#38](https://github.com/dvogeldev/remote-dev/issues/38) (Buzz self-host surface), [#39](https://github.com/dvogeldev/remote-dev/issues/39) (Nostr relay software).
> Repo convention: drop research notes under `research/`. Prior art: `research/hermes-api-surface.md`, `research/oss-web-clients.md`.
> All claims trace to a primary doc page or the upstream GitHub repo.

## TL;DR

The Hermes messaging gateway exposes a **public, documented, plugin-based extension API** for adding new channels. Adding a channel means dropping a directory into `~/.hermes/plugins/<name>/` with a `plugin.yaml` manifest and an `adapter.py` that subclasses `BasePlatformAdapter`. There is no Python entry-point file, no core-code edit, and no build step — the gateway loads plugins at startup.

**Critically for this ticket: Hermes already ships a first-class Buzz platform adapter as a bundled plugin at `plugins/platforms/buzz/`** (since v2026.8.31, PR [#73610](https://github.com/NousResearch/hermes-agent/pull/73610), implementing [#68871](https://github.com/NousResearch/hermes-agent/issues/68871)). Buzz is **option ③ of three** documented integration paths ([Integrations → Buzz](https://hermes-agent.nousresearch.com/docs/integrations/buzz), [Messaging → Buzz](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/buzz)). It speaks Nostr natively (WebSocket subscription with NIP-42 auth + BIP-340 signing, poll-loop fallback) and uses the Buzz CLI for outbound. The recommended adapter shape for this map is therefore **option ③** — install the bundled `buzz` plugin via `hermes gateway setup` and configure `BUZZ_*` env vars in `~/.hermes/.env`. A custom Nostr adapter is only justified if we want Hermes to drive a non-Buzz Nostr relay (e.g. nostr-tools without the `buzz` CLI) — and even then, the **same plugin contract** is the extension point.

The experimental connector-backed "Relay" lane (`gateway/relay/`) is a separate, larger option: it puts a Node/TypeScript **connector** in front of Discord/Telegram/Slack and dials back to Hermes over a single authenticated WebSocket ([`docs/relay-connector-contract.md`](https://github.com/NousResearch/hermes-agent/blob/main/docs/relay-connector-contract.md)). It is overkill for Nostr and is **explicitly EXPERIMENTAL** ("MAY CHANGE without a deprecation cycle until at least two real Class-1 platforms validate it").

---

## 1. The extension point

### 1a. How a new channel gets registered

**Plugin (recommended for community/third-party platforms).** Drop a directory into one of:

| Location | Loaded by |
| --- | --- |
| `plugins/platforms/<name>/` in the installed package | Bundled with the Hermes distribution (the shipped location for IRC, LINE, Telegram, Slack, Matrix, Mattermost, WeCom, Feishu, DingTalk, Email, SMS, Discord, WhatsApp, Teams, Home Assistant, **Buzz**, …) |
| `~/.hermes/plugins/<name>/` | User-installed (no core-code edit) |

The plugin directory has exactly two load-bearing files plus an optional `tools.py`:

```
plugins/platforms/my_platform/
  plugin.yaml      # manifest (kind: platform)
  adapter.py       # BasePlatformAdapter subclass + register(ctx) entry point
  tools.py         # optional outbound client tools (deferred import)
```

Source: [Adding a Platform Adapter → Plugin Path](https://hermes-agent.nousresearch.com/docs/developer-guide/adding-platform-adapters).

**Discovery is via the `Platform._missing_()` enum pattern, not a Python entry point.** The platform registry (`gateway/platform_registry.py` + `hermes_cli/plugins.py`) walks the plugin directories at startup, parses each `plugin.yaml`, and for `kind: platform` plugins registers a cheap `register_deferred` loader. SDK imports are deferred until the gateway actually needs the platform — so plain `hermes chat` never imports your platform's SDK. The doc table is explicit: *"Bundled `kind: platform` plugins register cheap `register_deferred` loaders in `gateway/platform_registry.py` (via `hermes_cli/plugins.py`) so platform SDKs import only when the gateway starts, delivers, or runs setup/status — not on plain `hermes chat`."*

There is **no Python `setup.py` / `pyproject.toml` entry-point** involved — the loader is filesystem-based, scanning the plugin directories at startup.

### 1b. The `register(ctx)` entry point

Every plugin `adapter.py` defines a `register(ctx)` function that registers the platform with the gateway. The exact contract (verbatim from the docs, [`adapter.py` example](https://hermes-agent.nousresearch.com/docs/developer-guide/adding-platform-adapters#adapterpy)):

```python
def register(ctx):
    """Plugin entry point — called by the Hermes plugin system."""
    ctx.register_platform(
        name="my_platform",                          # unique snake_case name
        label="My Platform",                         # display label
        adapter_factory=lambda cfg: MyPlatformAdapter(cfg),
        check_fn=check_requirements,                 # PASSIVE probe — are deps/config present right now?
        validate_config=validate_config,
        required_env=["MY_PLATFORM_TOKEN"],
        install_hint="pip install my-platform-sdk",
        env_enablement_fn=_env_enablement,           # env → PlatformConfig.extra bridge
        cron_deliver_env_var="MY_PLATFORM_HOME_CHANNEL",
        allowed_users_env="MY_PLATFORM_ALLOWED_USERS",
        allow_all_env="MY_PLATFORM_ALLOW_ALL_USERS",
        max_message_length=4000,
        platform_hint="You are chatting via My Platform. It supports markdown formatting.",
        emoji="💬",
    )
    # Optional: register platform-specific tools
    ctx.register_tool(name="my_platform_search", toolset="my_platform", schema={...}, handler=...)
```

`ctx.register_platform()` integrates the adapter into **all** of the gateway's integration points automatically — the doc spells this out as a table (paraphrased):

| Integration point | How it works |
| --- | --- |
| Gateway adapter creation | Registry checked before built-in if/elif chain |
| Config parsing | `Platform._missing_()` accepts any platform name |
| Connected platform validation | Registry `validate_config()` called |
| User authorization | `allowed_users_env` / `allow_all_env` checked |
| Env-only auto-enable | `env_enablement_fn` seeds `PlatformConfig.extra` + `home_channel` |
| YAML config bridge | `apply_yaml_config_fn` translates `config.yaml` keys into env vars / extras |
| Cron delivery | `cron_deliver_env_var` makes `deliver=<name>` work |
| `hermes config` UI entries | `requires_env` / `optional_env` in `plugin.yaml` auto-populate |
| Send engine (`tools/send_message_tool.py`) | Routes through live gateway adapter |
| Webhook cross-platform delivery | Registry checked for known platforms |
| `/update` command access | `allow_update_command` flag |
| Channel directory | Plugin platforms included in enumeration |
| System prompt hints | `platform_hint` injected into LLM context |
| Message chunking | `max_message_length` for smart splitting |
| PII redaction | `pii_safe` flag |
| `hermes status` | Shows plugin platforms with `(plugin)` tag |
| `hermes gateway setup` | Plugin platforms appear in setup menu |
| `hermes tools` / `hermes skills` | Plugin platforms in per-platform config |
| Token lock (multi-profile) | Use `acquire_scoped_lock()` in your `connect()` |
| Orphaned config warning | Descriptive log when plugin is missing |

(Verbatim from [Adding a Platform Adapter → "What the Plugin System Handles Automatically"](https://hermes-agent.nousresearch.com/docs/developer-guide/adding-platform-adapters#what-the-plugin-system-handles-automatically).)

### 1c. `plugin.yaml` schema (verbatim essentials)

```yaml
name: my-platform
label: My Platform
kind: platform            # ← required
version: 1.0.0
description: My custom messaging platform adapter
author: Your Name

# These show up in `hermes config` UI automatically.
requires_env:
  - MY_PLATFORM_TOKEN                    # bare string works
  - name: MY_PLATFORM_CHANNEL            # or rich dict
    description: "Channel to join"
    prompt: "Channel"
    password: false
optional_env:
  - name: MY_PLATFORM_HOME_CHANNEL
    description: "Default channel for cron delivery"
    password: false

# If the plugin also ships outbound client tools the agent can call from any
# session (e.g. `a2a_call`, `a2a_discover`), declare them here. The adapter
# itself stays deferred; only `tools.py` is imported during discovery.
provides_tools:
  - my_platform_call
  - my_platform_list
```

### 1d. The user-config side

```yaml
# config.yaml
gateway:
  platforms:
    my_platform:
      enabled: true
      extra:
        token: "..."
        channel: "#general"
```

Or, more commonly, via `~/.hermes/.env` (the `env_enablement_fn` hook in `register()` reads env vars before constructing the adapter, so `hermes gateway status` and cron delivery see correct state without instantiating the SDK).

---

## 2. The adapter interface — what a channel implements

Every adapter extends `BasePlatformAdapter` from `gateway/platforms/base.py` and implements:

| Method | Required? | Purpose |
| --- | --- | --- |
| `connect(*, is_reconnect: bool = False) -> bool` | **abstract** | Establish connection (WebSocket, long-poll, HTTP server, etc.). Call `self._mark_connected()` on success. |
| `disconnect() -> None` | **abstract** | Clean shutdown. Call `self._mark_disconnected()`. |
| `send(chat_id, content, reply_to=None, metadata=None) -> SendResult` | **abstract** | Send a text message to a chat. Returns `SendResult(success, message_id, error?, thread_id?)`. |
| `send_typing(chat_id, **kwargs)` | optional override | Show typing indicator. |
| `get_chat_info(chat_id) -> dict` | optional override | Return `{"name": ..., "type": ...}`. |
| `_keep_typing(chat_id, *args, **kwargs)` | optional override | The typing-indicator heartbeat; subclass to layer platform-specific mid-flight UX (e.g. LINE's "Get answer" postback button at 45 s). |

**Inbound messages** are received by the adapter and forwarded via `self.handle_message(event)`, which the base class routes to the gateway runner. The adapter builds a `MessageEvent` and the routing is automatic:

```python
from gateway.platforms.base import (
    BasePlatformAdapter, SendResult, MessageEvent, MessageType,
)
from gateway.config import Platform, PlatformConfig

source = self.build_source(
    chat_id=chat_id,
    chat_name=name,
    chat_type="dm",                # or "group"
    user_id=user_id,
    user_name=user_name,
)
event = MessageEvent(
    text=content,
    message_type=MessageType.TEXT,
    source=source,
    message_id=msg_id,
)
await self.handle_message(event)
```

Sources: [Adding a Platform Adapter → Architecture Overview](https://hermes-agent.nousresearch.com/docs/developer-guide/adding-platform-adapters#architecture-overview), [`gateway/platforms/base.py` (raw)](https://github.com/NousResearch/hermes-agent/blob/main/gateway/platforms/base.py).

**Lifecycle hooks** beyond `connect`/`disconnect`:

- `__init__(self, config: PlatformConfig)` — call `super().__init__(config, Platform("my_platform"))`; read creds from `config.extra` or env.
- `_mark_connected()` / `_mark_disconnected()` — base-class helpers that update the gateway's connection state and the active-sessions guard.
- `acquire_scoped_lock()` / `release_scoped_lock()` from `gateway.status` — call in `connect()` / `disconnect()` if the adapter holds a unique credential, to prevent two profiles from driving the same bot identity. The Buzz adapter uses this pattern with key `f"{relay_url}:{self_pubkey}"` (per the [Buzz PR #73610](https://github.com/NousResearch/hermes-agent/pull/73610)).
- `apply_yaml_config_fn(yaml_cfg, platform_cfg)` — hook to translate `config.yaml` keys into env vars / extras before `PlatformConfig.extra` is built (multiplexed profiles only).
- `standalone_sender_fn(pconfig, chat_id, message, *, thread_id, media_files, force_document)` — for **out-of-process cron delivery**: when `hermes cron run` runs in a separate process from `hermes gateway`, this function lets the plugin deliver without holding the live gateway.

Sources: [Adding a Platform Adapter → Token Locks](https://hermes-agent.nousresearch.com/docs/developer-guide/adding-platform-adapters#token-locks), [Cron Delivery](https://hermes-agent.nousresearch.com/docs/developer-guide/adding-platform-adapters#cron-delivery).

---

## 3. On-the-wire / on-disk shape of a "message"

The message shape is the `MessageEvent` dataclass in `gateway/platforms/base.py` plus its embedded `SessionSource`. Both relay-connector paths and native adapters normalize inbound platform wire events into this single shape. Source of truth (verbatim from [`docs/relay-connector-contract.md` §3 SessionSource fields](https://github.com/NousResearch/hermes-agent/blob/main/docs/relay-connector-contract.md)):

`MessageEvent` (the envelope the gateway runner consumes):

| Field | Type | Notes |
| --- | --- | --- |
| `text` | string | The message body |
| `message_type` | enum (`MessageType`) | `TEXT` / `IMAGE` / `AUDIO` / `VIDEO` / `DOCUMENT` / `COMMAND` |
| `source` | `SessionSource` | Routing context (see below) |
| `message_id` | string | Platform message id (for pin / reply / react) |
| `reply_to_message_id` | string \| None | For threaded replies |
| `reply_to` | dict \| None | `{text?, author?, is_own?}` — what the user quoted |
| `media_urls` / `media` | list \| None | For attachments; `media` is parallel array of `{kind, mime, size, filename, caption}` |
| `channel_context` | list \| None | Read-only surrounding messages (relay-context feature) |
| `raw_message` | dict \| None | Platform-specific raw payload (Telegram `_hermes_no_thread_response` flag etc.) |

`SessionSource` (routing discriminators — the wire surface per `to_dict()` in `gateway/session.py`):

| Field | Type | Always sent | Meaning |
| --- | --- | --- | --- |
| `platform` | string | yes | Platform name (matches `PlatformEntry.name`) |
| `chat_id` | string | yes | Primary conversation id; **session-key discriminator** |
| `chat_type` | string | yes | `dm` / `group` / `channel` / `thread` / `forum` |
| `chat_name` | string \| null | yes | Human-readable chat name |
| `user_id` | string \| null | yes | Message author id; **session-key discriminator** |
| `user_name` | string \| null | yes | Author display name |
| `thread_id` | string \| null | yes | Thread / forum-topic id; **session-key discriminator** |
| `chat_topic` | string \| null | yes | Channel topic (Discord, Slack) |
| `user_id_alt` | string | no | Platform-specific stable alt id (Signal UUID, Feishu union_id) |
| `chat_id_alt` | string | no | Alternate chat id (Signal group internal id) |
| `scope_id` | string | no | Platform-neutral scope: Discord guild / Slack workspace / Matrix server — **required for Discord/Slack scope isolation** |
| `parent_chat_id` | string | no | Parent channel when `chat_id` is a thread |
| `message_id` | string | no | Id of the triggering message |

The session key encodes the full routing context and is built by `build_session_key()` in `gateway/session.py`:

```
agent:main:{platform}:{chat_type}:{chat_id}
```

Example: `agent:main:telegram:private:123456789`. **Never construct session keys manually** — always go through `build_session_key()` (per [Gateway Internals → Session Key Format](https://hermes-agent.nousresearch.com/docs/developer-guide/gateway-internals#session-key-format)).

**Mapping a Nostr event into a `MessageEvent`** (for the hypothetical custom Nostr adapter path):

| Nostr field (kind 9 chat message) | Maps to |
| --- | --- |
| `event.id` | `MessageEvent.message_id` |
| `event.pubkey` | `SessionSource.user_id` (hex pubkey, optionally bech32-encoded as `npub1…` for `user_name`) |
| `event.content` | `MessageEvent.text` (the plain-text body after stripping mention tags and media URLs) |
| `event.created_at` | for ordering (used by `_thread_roots` in the Buzz adapter) |
| `tags` with `e` markers (`reply`, `root`, positional) | `SessionSource.thread_id` / `MessageEvent.reply_to_message_id` (NIP-10 reply semantics) |
| `tags` with `p` markers | `SessionSource.user_id_alt` or `chat_id_alt`; also used for DM classification (single `p` tag to a known pubkey ⇒ `chat_type="dm"`) |
| `tags` with `t` / `subject` | `SessionSource.chat_topic` |
| `imeta` tags (NIP-94) | `MessageEvent.media[]` + `media_urls[]` (after fetching from the relay URL with SHA-256 / size integrity check, as the Buzz adapter enforces) |
| Channel id (Buzz relay layer) | `SessionSource.chat_id` |
| Community id (Buzz relay layer) | `SessionSource.scope_id` |
| Own pubkey (the agent's identity) | omitted (drives `is_own` for `reply_to.is_own`) |

The exact relay-side mapping the bundled Buzz adapter uses is in `plugins/platforms/buzz/adapter.py` (NIP-94 attachment gate, NIP-10 e-tag parent resolution, mention gating, self-echo suppression).

### Outbound wire shape

For the **plugin / direct path** (the path option ③ uses), outbound is just a function call from the gateway runner — `await self.send(chat_id, content, reply_to=..., metadata=...)` — so there is no wire format; the adapter translates to whatever the platform's API wants.

For the **experimental relay path** (`gateway/relay/`), outbound is a JSON WebSocket frame. Action set (verbatim from [`docs/relay-connector-contract.md` §4](https://github.com/NousResearch/hermes-agent/blob/main/docs/relay-connector-contract.md)):

| `op` | Fields | Result |
| --- | --- | --- |
| `send` | `chat_id`, `content`, `reply_to?`, `metadata?` | `{success, message_id?, error?}` |
| `edit` | `chat_id`, `message_id`, `content`, `metadata?` | `{success, error?}` |
| `typing` | `chat_id`, `content?`, `metadata?` | `{success}` (Slack-only "clear" semantics for `content=""`) |
| `follow_up` | `session_key`, `kind`, `content`, `metadata?` | `{success, message_id?, error?}` (token-less capability actions) |
| `send_media` | `chat_id`, `media_kind`, `source_url`, `content?`, `filename?`, `reply_to?`, `metadata?` | `{success, message_id?, error?}` (25 MB cap, `media_kind` ∈ image/voice/audio/video/document) |
| `prompt` | `chat_id`, `prompt_kind`, `prompt_id`, `content`, `options[]`, `timeout_s?`, `reply_to?`, `metadata?` | `{success, message_id?, error?}` (native interactive prompts) |
| `react` | `chat_id`, `message_id`, `emoji`, `remove?`, `metadata?` | `{success, error?}` (best-effort, never fails a turn) |
| `thread_create` / `thread_rename` | … | `{success, thread_id?, error?}` |

### On-disk session persistence

`SessionStore` (in `gateway/session.py`) persists the conversation history in **SQLite**. Session keys are the ones `build_session_key()` produces from the `SessionSource` discriminators above. Cron job deliveries are explicitly **not** mirrored into gateway session history (deliberate, to avoid alternation violations) — per [Gateway Internals → Delivery Path](https://hermes-agent.nousresearch.com/docs/developer-guide/gateway-internals#delivery-path).

---

## 4. Documented deployment story for a custom channel

The doc explicitly addresses three shapes:

### 4a. In-process (default; recommended for community/third-party platforms)

This is the documented **default** and the **recommended** path for a new platform:

> *"Plugin (recommended for community/third-party): Drop a plugin directory into `~/.hermes/plugins/` — zero core code changes needed."*

The adapter runs **inside the gateway process**. Lifecycle: `hermes gateway start` (manual), `hermes gateway install` (Linux user service / macOS launchd), `sudo hermes gateway install --system` (Linux boot-time system service). PID file at `~/.hermes/gateway.pid` is profile-scoped. `hermes gateway stop --all` kills all profile gateway processes (used during updates). Source: [Gateway Internals → Process Management](https://hermes-agent.nousresearch.com/docs/developer-guide/gateway-internals#process-management).

### 4b. Out-of-process cron delivery (required for cron that doesn't share the gateway process)

When `hermes cron run` runs separately from `hermes gateway`, the plugin must register a `standalone_sender_fn`. The doc is explicit on why:

> *"Built-in platforms (Telegram, Discord, Slack, etc.) ship direct REST helpers in `tools/send_message_tool.py` so cron can deliver without holding the gateway in the same process. Plugin platforms historically depended on `_gateway_runner_ref()`, which returns `None` outside the gateway process, so without `standalone_sender_fn` the cron-side send fails with `No live adapter for platform '<name>'`."*

The function receives `(pconfig, chat_id, message, *, thread_id, media_files, force_document)` and returns `{"success": True, "message_id": ...}` or `{"error": ...}`. The Buzz adapter ships one — verified in `plugins/platforms/buzz/adapter.py`.

### 4c. Connector-backed / sidecar (experimental relay path)

A **separate service** — the "connector" (Node/TypeScript, in repo `NousResearch/gateway-gateway`) — fronts one or more real messaging platforms (Discord, Telegram, Slack, WhatsApp). It owns all platform bot tokens and sockets. Your gateway dials **out** to it over a single authenticated WebSocket (`wss://…/relay`). Inbound rides the same socket back as `inbound` frames. The connector advertises a `CapabilityDescriptor` at handshake; per-platform capability flags (edit-based streaming, threads, draft streaming, markdown dialect, message length limit) come from that descriptor.

The contract is documented in `docs/relay-connector-contract.md` (v1, EXPERIMENTAL). Key properties:

- Outbound-only networking. The gateway never opens an inbound port. Inbound messages ride back down the same WebSocket the gateway dialed.
- No platform secrets on the gateway. Bot tokens live on the connector. Auth-gated platform media URLs are re-hosted connector-side.
- Platform-agnostic. The gateway doesn't know which concrete platform the connector is fronting.

**Status: EXPERIMENTAL.** The doc explicitly states: *"This contract MAY CHANGE without a deprecation cycle until at least two real Class-1 platforms (Discord + Telegram) have validated it. Evolution during the experimental phase is **additive-only**, gated by `contract_version`."*

**This is not the right deployment shape for the Nostr ↔ Hermes channel.** Nostr is not in the relay connector's roadmap (it would require a Nostr-specific connector, not a messaging-platform connector), the contract is experimental, and the same channel functionality is already provided by the bundled `buzz` plugin via the in-process path (option 4a).

---

## 5. Existing channels we can mirror

### Best mirror: **Buzz** (our exact use case — Nostr → Hermes)

`plugins/platforms/buzz/` is the canonical reference implementation for what we're building. It already ships and is the **bundled** plugin for the Nostr ↔ Hermes channel.

- **Inbound**: persistent NIP-42-authenticated Nostr WebSocket subscription (via `websockets`, dependency-free; BIP-340 signing in `nostr_auth.py`) with automatic CLI-poll fallback. `transport: auto | websocket | poll`.
- **Outbound**: shells out to the `buzz` CLI ("JSON in, JSON out") via `asyncio.create_subprocess_exec`. Private key travels via subprocess env only — never argv.
- **Lifecycle**: `connect()` calls `acquire_scoped_lock("buzz", f"{relay_url}:{self_pubkey}")` to prevent two profiles driving the same identity (IRC pattern). `disconnect()` releases the lock and cancels the WS/poll tasks.
- **Edge cases it handles** (great reference for any custom Nostr adapter): per-channel high-water marks (no history replay on reconnect), bounded event dedup (`_SEEN_CAP = 500`), NIP-94 imeta attachment gate (HTTPS, exact size + SHA-256, 20 MiB cap per attachment, 4 attachments max), NIP-10 reply-parent resolution, mention gating (`require_mention`), leading-@mention strip for slash commands, p-tag DM classification, `buzz users get --pubkey` display-name resolution with TTL cache.

Source: [`plugins/platforms/buzz/adapter.py`](https://github.com/NousResearch/hermes-agent/blob/main/plugins/platforms/buzz/adapter.py), [`plugins/platforms/buzz/plugin.yaml`](https://github.com/NousResearch/hermes-agent/blob/main/plugins/platforms/buzz/plugin.yaml), [Messaging → Buzz](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/buzz), [PR #73610](https://github.com/NousResearch/hermes-agent/pull/73610).

### Other useful references

| Adapter | Why useful as a reference |
| --- | --- |
| **`plugins/platforms/irc/`** | Canonical scoped-lock example; zero external deps; minimal — easy to read. |
| **`plugins/platforms/teams/`** | Bot Framework / Adaptive Cards (REST + callback pattern). |
| **`plugins/platforms/google_chat/`** | OAuth-based REST APIs. |
| **`plugins/platforms/line/`** | Webhook-driven Messaging API with platform-specific slow-LLM UX (`_keep_typing` override at threshold). |
| **`plugins/platforms/wecom/callback_adapter.py`** | Callback/webhook with AES crypto, multi-app. |
| **`gateway/platforms/signal.py`** | Long-poll via signal-cli REST API. |
| **`gateway/platforms/api_server.py`** | How a non-messaging channel (REST chat) plugs into the same `BasePlatformAdapter` surface — relevant if we want a future REST/Nostr HTTP endpoint instead of WS. |

---

## 6. Recommended adapter shape for this map

**Recommendation: do not write a custom Nostr adapter. Use the bundled `buzz` plugin (option ③ of three documented Buzz integration paths).**

Concretely:

1. **Install / enable the bundled Buzz plugin.** `hermes gateway setup` → select Buzz. This drops the plugin manifest into the gateway's loaded-plugin set (already shipped in `plugins/platforms/buzz/`; no code to write).
2. **Configure in `~/.hermes/.env`** (private key is a secret — env is the only place it belongs):
   ```
   BUZZ_RELAY_URL=https://<our-community-relay>
   BUZZ_PRIVATE_KEY=<nsec or hex>          # the only secret
   BUZZ_HOME_CHANNEL=<channel-uuid>
   BUZZ_ALLOWED_USERS=<comma-separated npubs or hex pubkeys>
   BUZZ_ALLOW_ALL_USERS=false              # private mode for our use case
   BUZZ_REQUIRE_MENTION=true               # channels: only respond when addressed
   BUZZ_TRANSPORT=auto                     # WS w/ poll fallback
   BUZZ_POLL_INTERVAL=4                    # seconds (default)
   ```
3. **Or configure via `config.yaml`** (canonical form; env wins when both are set):
   ```yaml
   gateway:
     platforms:
       buzz:
         enabled: true
         extra:
           relay_url: https://<our-community-relay>
           channels: [<uuid>, <uuid>]      # empty = all joined
           home_channel: <uuid>
           allowed_users: []               # empty ⇒ allow all only if allow_all_users=true
           require_mention: true
           allow_all_users: false
           transport: auto
           poll_interval: 4
           cli_path: ""                    # default: `buzz` on PATH, then ~/bin/buzz
           credentials_file: ""            # fallback for BUZZ_PRIVATE_KEY
   ```
4. **Build the `buzz` CLI** from the Block repo: `cargo build --release -p buzz-cli`. Put the binary on `$PATH` (or set `BUZZ_CLI_PATH`).
5. **Verify**: `hermes gateway status` should show `Buzz` (not `(plugin)` — it's bundled); `hermes gateway setup` should accept the same config interactively.

### Why this shape and not a custom Nostr adapter

- **The bundled adapter is already what the ticket is asking for.** Issue [#68871](https://github.com/NousResearch/hermes-agent/issues/68871) was explicitly "Add messaging support for Buzz" and shipped in v2026.8.31. It uses Nostr end-to-end (NIP-42, NIP-94, NIP-10) with dependency-free signing — the integration exists.
- **The plugin extension API is the documented seam.** Even if we wanted custom Nostr behavior (e.g. a relay we control that isn't a Buzz community, or nostr-tools without the CLI), the seam is the same `plugins/platforms/<name>/` directory + `register(ctx)` entry. The bundled adapter is the reference implementation to copy.
- **The relay connector path is wrong for this map.** It's a separate Node/TS connector service fronting conventional messaging platforms (Discord/Telegram/Slack/WhatsApp) over a single authenticated WebSocket. It is **experimental**, the doc explicitly says the contract MAY CHANGE, and it would require building and operating a Nostr-specific connector service.
- **In-process is the right deployment shape.** Per the doc, in-process is the recommended default; cron delivery is handled via the adapter's `standalone_sender_fn` (already wired in the Buzz adapter per [PR #73610](https://github.com/NousResearch/hermes-agent/pull/73610)).

### When a custom Nostr adapter IS justified

Only if we want to point Hermes at a **non-Buzz Nostr relay** (one without the `buzz` CLI, or with relay semantics the CLI doesn't model). Even then:

- Implement as a plugin at `~/.hermes/plugins/<name>/` (zero core edits).
- Subclass `BasePlatformAdapter`.
- Implement `connect()` to open a NIP-42-authenticated WS subscription (model on `plugins/platforms/buzz/adapter.py`'s `_start_websocket`).
- Implement `disconnect()` to cancel the WS task and release the scoped lock.
- Implement `send()` to shell out to whichever CLI you choose (or speak the relay directly via `websockets`).
- Build `MessageEvent`s per §3 mapping; route via `self.handle_message(event)`.
- Add `provides_tools:` in `plugin.yaml` if you want the agent to be able to call Nostr-aware tools from any session (mirrors the `a2a` plugin's pattern).

---

## 7. Cross-references to the ticket checklist

| Ticket question | Answer | Source |
| --- | --- | --- |
| How does a new channel get registered? | Drop a plugin directory at `plugins/platforms/<name>/` or `~/.hermes/plugins/<name>/`; the platform registry scans at startup via `register_deferred` loaders. No Python entry-point file, no core edit, no build step. `register(ctx)` declares everything. | [Adding a Platform Adapter](https://hermes-agent.nousresearch.com/docs/developer-guide/adding-platform-adapters#plugin-path-recommended) |
| What interface / protocol / callback does a channel implement? | Subclass `BasePlatformAdapter` from `gateway/platforms/base.py`. Required: `connect()`, `disconnect()`, `send()`. Optional: `send_typing()`, `get_chat_info()`, `_keep_typing()` (for platform-specific slow-LLM UX). Inbound: build `MessageEvent`, call `self.handle_message(event)`. Lifecycle hooks: `_mark_connected/_mark_disconnected`, `acquire_scoped_lock`/`release_scoped_lock`, `apply_yaml_config_fn`, `standalone_sender_fn`. | [Adding a Platform Adapter → Architecture Overview](https://hermes-agent.nousresearch.com/docs/developer-guide/adding-platform-adapters#architecture-overview) |
| What is the on-the-wire / on-disk shape of a "message"? | `MessageEvent` dataclass with `text`, `message_type`, `source: SessionSource`, `message_id`, `reply_to_message_id`, `reply_to`, `media_urls`/`media`. Session-key format `agent:main:{platform}:{chat_type}:{chat_id}` built by `build_session_key()`. Persisted in `SessionStore` SQLite. The relay-connector wire shape (for the experimental path) is JSON frames — irrelevant for our option ③ path. | [Gateway Internals → Session Key Format](https://hermes-agent.nousresearch.com/docs/developer-guide/gateway-internals#session-key-format), [`docs/relay-connector-contract.md` §3](https://github.com/NousResearch/hermes-agent/blob/main/docs/relay-connector-contract.md) |
| What is the documented deployment story for a custom channel? | In-process (recommended default) — drop plugin at `~/.hermes/plugins/<name>/`; managed by `hermes gateway start`/`install`. Out-of-process cron delivery via `standalone_sender_fn` (so `hermes cron run` outside the gateway process can still deliver). Connector-backed sidecar (`gateway/relay/`) is **experimental** and the wrong shape for Nostr. | [Adding a Platform Adapter → Cron Delivery](https://hermes-agent.nousresearch.com/docs/developer-guide/adding-platform-adapters#cron-delivery), [Gateway Internals → Process Management](https://hermes-agent.nousresearch.com/docs/developer-guide/gateway-internals#process-management) |
| Any existing channel we can mirror? | **Yes — the bundled `plugins/platforms/buzz/` adapter is the exact mirror.** It speaks Nostr natively, handles NIP-42 auth, NIP-10 threading, NIP-94 attachments, and is in v2026.8.31 since [PR #73610](https://github.com/NousResearch/hermes-agent/pull/73610). Other references: `irc/` (scoped-lock pattern), `line/` (slow-LLM UX), `teams/` (REST + callback). | [Messaging → Buzz](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/buzz), [`plugins/platforms/buzz/adapter.py`](https://github.com/NousResearch/hermes-agent/blob/main/plugins/platforms/buzz/adapter.py) |

---

## 8. Open questions for downstream (the map)

- [ ] Which Buzz community relay are we targeting, and is the `buzz` CLI available in our container? (Sibling ticket [#38](https://github.com/dvogeldev/remote-dev/issues/38): "Research Block Buzz: self-host surface and persistence".)
- [ ] What Nostr relay software do we plan to run? (Sibling ticket [#39](https://github.com/dvogeldev/remote-dev/issues/39): "Research Nostr relay software for the host plane". If we don't run a Buzz community, the answer changes — we may need a custom Nostr adapter that mirrors the bundled Buzz plugin's structure but talks a non-Buzz relay directly via `websockets`.)
- [ ] What is the per-channel user allow-list strategy — `BUZZ_ALLOW_ALL_USERS=true` (community mode) or `BUZZ_ALLOWED_USERS=<npubs>` (private mode)?
- [ ] Where does the agent's Nostr identity live — managed by a Nostr signer (npub, NIP-46 remote signer, etc.) or a static `BUZZ_PRIVATE_KEY` in `~/.hermes/.env`?
- [ ] Are inbound attachments in scope? (The Buzz adapter supports NIP-94 imeta with strict integrity + size checks; 20 MiB / 4-attachment cap.)
- [ ] Does cron delivery matter here? (The bundled adapter ships `standalone_sender_fn` so `hermes cron run` outside the gateway works — but if we always run cron inside the gateway process, this is moot.)

---

## Sources

Primary, all consulted 2026-09-01:

- [Adding a Platform Adapter](https://hermes-agent.nousresearch.com/docs/developer-guide/adding-platform-adapters) — plugin path, `register(ctx)` contract, built-in checklist, common patterns, reference implementations. The load-bearing doc for this ticket.
- [Gateway Internals](https://hermes-agent.nousresearch.com/docs/developer-guide/gateway-internals) — file map, message flow, session-key format, two-level guard, auth, hooks, process management.
- [Messaging Gateway overview](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/) — the full platform comparison table.
- [Messaging → Buzz](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/buzz) — the canonical setup guide for the bundled Nostr adapter (config.yaml + `BUZZ_*` env vars, transport modes, attachment gate).
- [Integrations → Buzz](https://hermes-agent.nousresearch.com/docs/integrations/buzz) — the three-way comparison (Desktop runtime / ACP relay bridge / native gateway platform).
- [`docs/relay-connector-contract.md`](https://github.com/NousResearch/hermes-agent/blob/main/docs/relay-connector-contract.md) — the experimental connector wire contract (capability descriptor, `MessageEvent` envelope, outbound action set, trust boundary).
- [`gateway/platforms/base.py`](https://github.com/NousResearch/hermes-agent/blob/main/gateway/platforms/base.py) — `BasePlatformAdapter`, `MessageEvent`, `SendResult`, scoped-lock helpers.
- [`plugins/platforms/buzz/adapter.py`](https://github.com/NousResearch/hermes-agent/blob/main/plugins/platforms/buzz/adapter.py), [`plugins/platforms/buzz/plugin.yaml`](https://github.com/NousResearch/hermes-agent/blob/main/plugins/platforms/buzz/plugin.yaml) — the exact reference implementation for our use case.
- [PR #73610: feat(gateway): Buzz platform adapter — bundled plugin](https://github.com/NousResearch/hermes-agent/pull/73610) — the ship PR; describes the scope (zero core edits, plugin-only), 63 tests, and the per-profile identity lock added in review.
- [Issue #68871: [Feature]: Add messaging support for Buzz](https://github.com/NousResearch/hermes-agent/issues/68871) — the original request.
- [Hermes Agent repo](https://github.com/NousResearch/hermes-agent) and [landing](https://hermes-agent.nousresearch.com/) — version pinning, plugin directory listing.