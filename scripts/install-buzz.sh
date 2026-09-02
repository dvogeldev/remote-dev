#!/usr/bin/env bash
# Stand up Buzz on grr-remote-dev-01 (#47).
#
# AFK parts (this script):
#   - Lay down ~/.buzz/{compose.yml,.env} from this repo
#   - Generate BUZZ_RELAY_PRIVATE_KEY on the laptop via `nak key generate`,
#     store in `pass buzz/relay/private-key`, push to ~/.buzz/.env on grr.
#   - Generate Backing-service secrets (Postgres, Redis, MinIO, HMAC) on grr.
#   - Run `docker compose pull` + `up -d` (gated on RELAY_OWNER_PUBKEY being set).
#   - Wait for relay healthcheck.
#   - Print admin-bootstrap instructions for the operator (HITL).
#
# HITL parts (handled in servers/grr-buzz.md, not by this script):
#   - Set RELAY_OWNER_PUBKEY in ~/.buzz/.env (operator's Nostr pubkey, hex).
#   - Operator creates a Buzz room via the Buzz desktop client (loopback via
#     Tailscale or an SSH tunnel).
#   - `buzz-admin add-member --pubkey <Hermes-hex> --role bot` to register
#     Hermes (after #46 wired BUZZ_PRIVATE_KEY into ~/.hermes/.env).
#
# Idempotency: re-running on a populated ~/.buzz/ preserves the relay keypair
# and backing-service secrets. Upgrades are `docker compose pull relay &&
# docker compose up -d relay` — handled by hand per upstream guidance.
set -euo pipefail

HOST="${HOST:-grr}"
ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)"
COMPOSE_SRC="${ROOT}/host-plane/buzz-compose.yml"
ENV_SRC="${ROOT}/host-plane/buzz/.env.example"
REMOTE_COMPOSE=/tmp/buzz-compose.yml
REMOTE_ENV_EXAMPLE=/tmp/buzz.env.example

for f in "$COMPOSE_SRC" "$ENV_SRC"; do
  if [[ ! -f "$f" ]]; then
    echo "missing: $f" >&2
    exit 1
  fi
done

remote_bash_args() {
  ssh -o IdentitiesOnly=yes -o BatchMode=yes "$HOST" bash -s -- "$@"
}
copy_local_to_remote() {
  scp -q "$1" "$HOST:$2"
}

echo "target=$HOST compose=$COMPOSE_SRC env=$ENV_SRC"

# -----------------------------------------------------------------------------
# Stage 1 — Lay down compose.yml + env template + systemd unit on grr
# -----------------------------------------------------------------------------
UNIT_SRC="${ROOT}/host-plane/buzz.service"
REMOTE_UNIT=/tmp/buzz.service
for f in "$UNIT_SRC"; do
  if [[ ! -f "$f" ]]; then
    echo "missing: $f" >&2
    exit 1
  fi
done
copy_local_to_remote "$COMPOSE_SRC" "$REMOTE_COMPOSE"
copy_local_to_remote "$ENV_SRC"     "$REMOTE_ENV_EXAMPLE"
copy_local_to_remote "$UNIT_SRC"    "$REMOTE_UNIT"
remote_bash_args "$REMOTE_COMPOSE" "$REMOTE_ENV_EXAMPLE" "$REMOTE_UNIT" <<'EOS'
set -euo pipefail
remote_compose="$1"
remote_env_example="$2"
remote_unit="$3"
mkdir -p "$HOME/.buzz"
install -m 0644 "$remote_compose"     "$HOME/.buzz/compose.yml"
install -m 0644 "$remote_env_example" "$HOME/.buzz/.env.example"
mkdir -p "$HOME/.config/systemd/user"
install -m 0644 "$remote_unit"        "$HOME/.config/systemd/user/buzz.service"
# Linger: a user service won't run after the user logs out without linger.
# install-hermes-dashboard.sh enables linger; mirror that here so buzz.service
# keeps the stack up across SSH sessions.
if command -v loginctl >/dev/null && ! loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes'; then
  if sudo -n true 2>/dev/null; then
    sudo -n loginctl enable-linger "$USER" >/dev/null
    echo "  linger enabled for $USER"
  else
    echo "WARN: cannot enable linger non-interactively; run 'sudo loginctl enable-linger $USER' manually." >&2
  fi
fi
systemctl --user daemon-reload
EOS

# -----------------------------------------------------------------------------
# Stage 2 — Generate / fetch the relay keypair
#
# BUZZ_RELAY_PRIVATE_KEY signs relay-emitted events (deletions, channel meta).
# Source of truth = laptop pass (ADR #0007). nsec bech32 is accepted by the
# relay; hex is also accepted. We pass nsec (canonical Nostr form).
# -----------------------------------------------------------------------------
PASS_BUZZ_RELAY="${PASS_BUZZ_RELAY:-buzz/relay/private-key}"
buzz_relay_nsec=""

if command -v pass >/dev/null && pass show "$PASS_BUZZ_RELAY" >/dev/null 2>&1; then
  buzz_relay_nsec="$(pass show "$PASS_BUZZ_RELAY" | head -n1)"
  echo "reusing existing relay keypair from pass ($PASS_BUZZ_RELAY)"
else
  if ! command -v nak >/dev/null; then
    echo "FATAL: pass entry $PASS_BUZZ_RELAY missing AND nak not installed on laptop." >&2
    echo "  Install nostr-tools (cargo install nak --locked or download from" >&2
    echo "  https://github.com/fiatjaf/nak/releases) then re-run this script" >&2
    echo "  — it will generate the keypair and store it in pass." >&2
    exit 2
  fi
  echo "generating fresh relay keypair via nak..."
  buzz_relay_nsec="$(nak key generate)"
  # nak v0.20.6 prints the hex secret only; derive the npub for the human-
  # readable mirror line.
  buzz_relay_npub="$(nak key public "$buzz_relay_nsec")"
  if [[ -z "$buzz_relay_nsec" || -z "$buzz_relay_npub" ]]; then
    echo "FATAL: nak produced empty keypair — nsec='$buzz_relay_nsec' npub='$buzz_relay_npub'" >&2
    exit 2
  fi
  if command -v pass >/dev/null; then
    # `printf | pass` works for multiline; `pass insert -m` with `<<<` heredoc
    # has been observed to drop trailing lines on some shells.
    printf '%s\n%s\n' "$buzz_relay_nsec" "$buzz_relay_npub" \
      | pass insert -m -f "$PASS_BUZZ_RELAY" >/dev/null
    echo "stored relay keypair in pass ($PASS_BUZZ_RELAY) — line 1 nsec, line 2 npub"
  else
    echo "WARN: pass not installed — relay keypair is in this terminal only; back it up." >&2
    echo "  nsec: $buzz_relay_nsec" >&2
    echo "  npub: $buzz_relay_npub" >&2
  fi
fi

# -----------------------------------------------------------------------------
# Stage 3 — Push the relay keypair into ~/.buzz/.env on grr
#
# The nsec is passed as $1 to the remote script (SSH channel is encrypted).
# The remote script does the atomic replace so the .env is never half-written.
# -----------------------------------------------------------------------------
remote_bash_args "$buzz_relay_nsec" <<'EOS'
set -euo pipefail
new_relay_nsec="$1"
target="$HOME/.buzz/.env"
# First-run safety net: .env is seeded from .env.example if absent.
# install-buzz.sh may have crashed mid-flight on an earlier run, leaving
# compose.yml + .env.example present but .env missing — re-running should
# heal cleanly without overwriting an operator-edited .env that already
# has the relay key filled in.
if [[ ! -s "$target" ]] || grep -q '^BUZZ_RELAY_PRIVATE_KEY=REPLACE_ME' "$target"; then
  cp "$HOME/.buzz/.env.example" "$target"
fi
chmod 0600 "$target"
umask 077
tmp="$(mktemp "$target.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
# Preserve every line except any existing BUZZ_RELAY_PRIVATE_KEY=...
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    BUZZ_RELAY_PRIVATE_KEY=*) ;;
    *) printf '%s\n' "$line" ;;
  esac
done < "$target" > "$tmp"
printf 'BUZZ_RELAY_PRIVATE_KEY=%s\n' "$new_relay_nsec" >> "$tmp"
mv "$tmp" "$target"
chmod 0600 "$target"
grep -q '^BUZZ_RELAY_PRIVATE_KEY=' "$target" || { echo "FATAL: BUZZ_RELAY_PRIVATE_KEY not written" >&2; exit 1; }
grep -q '^BUZZ_RELAY_PRIVATE_KEY=REPLACE_ME' "$target" && { echo "FATAL: placeholder remained" >&2; exit 1; }
echo "  injected BUZZ_RELAY_PRIVATE_KEY into $target"
EOS

# -----------------------------------------------------------------------------
# Stage 4 — Generate Backing-service secrets on grr (idempotent)
# -----------------------------------------------------------------------------
remote_bash_args <<'EOS'
set -euo pipefail
target="$HOME/.buzz/.env"

# If .env is missing or still a placeholder stub, start from the template.
if [[ ! -s "$target" ]] || grep -q '^BUZZ_RELAY_PRIVATE_KEY=REPLACE_ME' "$target"; then
  cp "$HOME/.buzz/.env.example" "$target"
  chmod 0600 "$target"
fi

rand_hex() { openssl rand -hex "$1"; }

# Replace REPLACE_ME_<kind> in-place. Idempotent: a real value is left alone.
fill() {
  local key="$1" bytes="$2"
  if grep -q "^${key}=REPLACE_ME" "$target"; then
    local value
    value="$(rand_hex "$bytes")"
    tmp="$(mktemp "$target.XXXXXX")"
    awk -v k="$key" -v v="$value" '
      BEGIN { FS="="; OFS="=" }
      $1 == k && $2 ~ /^REPLACE_ME/ { print k, v; next }
      { print }
    ' "$target" > "$tmp"
    mv "$tmp" "$target"
    echo "  generated $key"
  fi
}

fill POSTGRES_PASSWORD            24
fill REDIS_PASSWORD               24
fill BUZZ_S3_ACCESS_KEY           24
fill BUZZ_S3_SECRET_KEY           48
fill BUZZ_GIT_HOOK_HMAC_SECRET    32

chmod 0600 "$target"
echo "wrote $target ($(wc -c < "$target") bytes)"
EOS

# -----------------------------------------------------------------------------
# Stage 4b — Public-hostname env mode (BUZZ_PUBLIC_HOSTNAME, #53)
#
# When BUZZ_PUBLIC_HOSTNAME is set in ~/.buzz/.env (or in the operator's
# local env when invoking this script), the relay's host→community resolver,
# media URLs, and CORS origins are rewritten to use the public hostname
# instead of loopback. This is what makes the relay accept WS connections
# from cloudflared at https://buzz.dvogeldev.com. See ADR #0013.
#
# Idempotent: only writes keys whose current value matches the loopback
# placeholder OR is unset. If the operator has hand-edited these, leave them.
# -----------------------------------------------------------------------------
remote_bash_args <<'EOS'
set -euo pipefail
target="$HOME/.buzz/.env"

# BUZZ_PUBLIC_HOSTNAME is the toggle. Read it from the live .env, or from
# the operator's local environment if they're flipping it for the first run.
hostname="$(grep -E '^BUZZ_PUBLIC_HOSTNAME=' "$target" 2>/dev/null | cut -d= -f2- || true)"
hostname="${hostname:-${BUZZ_PUBLIC_HOSTNAME:-}}"
# Treat empty / placeholder values as unset.
case "$hostname" in
  ""|REPLACE_ME*) hostname=""; ;;
esac

rewrite_if_loopback() {
  local key="$1" new_value="$2"
  local current
  current="$(grep -E "^${key}=" "$target" 2>/dev/null | cut -d= -f2- || true)"
  # Rewrite only if the current value is a loopback default OR unset.
  case "$current" in
    ""|"127.0.0.1"|"127.0.0.1:3000"|"http://127.0.0.1:3000"|"http://127.0.0.1:3000/media"|REPLACE_ME*)
      tmp="$(mktemp "$target.XXXXXX")"
      awk -v k="$key" -v v="$new_value" '
        BEGIN { FS="="; OFS="=" }
        $1 == k { print k, v; next }
        { print }
      ' "$target" > "$tmp"
      mv "$tmp" "$target"
      echo "  ${key} -> ${new_value}"
      ;;
    *)
      echo "  ${key}: leaving operator value (${current})"
      ;;
  esac
}

if [[ -n "$hostname" ]]; then
  wss="wss://${hostname}"
  https="https://${hostname}"
  rewrite_if_loopback BUZZ_DOMAIN                  "$hostname"
  rewrite_if_loopback RELAY_URL                    "$wss"
  rewrite_if_loopback BUZZ_MEDIA_BASE_URL         "${https}/media"
  rewrite_if_loopback BUZZ_MEDIA_SERVER_DOMAIN     "$hostname"
  # CORS for the desktop client + browser-based admin tools.
  # Default matches the canonical HTTPS origin; operator can add more.
  rewrite_if_loopback BUZZ_CORS_ORIGINS            "$https"
  chmod 0600 "$target"
  echo "public-hostname mode: relay answers at ${wss}"
else
  echo "loopback mode (BUZZ_PUBLIC_HOSTNAME unset) — relay answers at ws://127.0.0.1:3000"
fi
EOS

# -----------------------------------------------------------------------------
# Stage 5 — Pre-flight gate on RELAY_OWNER_PUBKEY
#
# We refuse to `up -d` until the operator has set their Nostr pubkey — without
# it the relay boots but no one is recognized as the owner / operator and the
# admin commands will reject everything. Easy to forget on a Sunday evening.
# -----------------------------------------------------------------------------
needs_owner="$(ssh -o IdentitiesOnly=yes -o BatchMode=yes "$HOST" \
  'grep -q "^RELAY_OWNER_PUBKEY=[^R]" "$HOME/.buzz/.env" && echo no || echo yes')"
if [[ "$needs_owner" == "yes" ]]; then
  cat <<EOF

=================================================================
  Pre-flight: RELAY_OWNER_PUBKEY is unset in ~/.buzz/.env on $HOST.
  Run, then re-run this script:
    ssh $HOST '\$EDITOR \$HOME/.buzz/.env'  # set RELAY_OWNER_PUBKEY=<operator-hex>
    # Get the hex:  nak pubkey <your-nsec>
    # This is the OPERATOR's Nostr pubkey (not Hermes's).
    HOST=$HOST $0
=================================================================
EOF
  exit 0
fi

# -----------------------------------------------------------------------------
# Stage 5b — Detect an existing Postgres dump in pass (recovery story, #51)
#
# If `pass buzz/postgres-dumps/` has any *.sql.gpg archives, we transfer the
# latest one to grr so Stage 6 can replay it into the freshly-provisioned
# Postgres before the relay boots. Skip cleanly when pass has no archives
# (genuinely fresh deployment).
# -----------------------------------------------------------------------------
remote_dump_path=""
remote_dump_filename=""
if command -v pass >/dev/null && pass ls "buzz/postgres-dumps/" >/dev/null 2>&1; then
  # pass ls output uses box-drawing chars; pull out *.sql filenames.
  # Filenames are sortable timestamps (YYYYMMDDTHHMMSSZ), so reverse-sort
  # gives us the latest.
  latest="$(pass ls "buzz/postgres-dumps/" 2>/dev/null \
    | grep -oE '[0-9TZ]+\.sql' \
    | sort -r \
    | head -n 1)"
  if [[ -n "$latest" ]]; then
    echo "  pass has Postgres dump: $latest (will replay)"
    # `pass show` decrypts the pass tree layer (ADR-0007) and returns
    # the raw SQL. No further gpg decryption needed.
    pass show "buzz/postgres-dumps/$latest" > /tmp/buzz-restore.dump
    scp -q /tmp/buzz-restore.dump "$HOST:/tmp/buzz-restore.dump"
    rm -f /tmp/buzz-restore.dump
    remote_dump_path="/tmp/buzz-restore.dump"
    remote_dump_filename="$latest"
  fi
fi
if [[ -z "$remote_dump_path" ]]; then
  echo "  no Postgres dumps in pass (fresh deployment, nothing to restore)"
fi

# -----------------------------------------------------------------------------
# Stage 6 — compose pull + bring the stack up via the systemd unit
#
# buzz.service runs `docker compose up` in the foreground, which keeps the
# compose process alive under the unit. The unit IS the control plane for
# the stack: `systemctl --user start|stop|restart buzz.service`.
#
# If a Postgres dump was transferred in Stage 5b, we bring up Postgres +
# minio-init only (so the relay doesn't race us), replay the dump into
# the empty DB, then start the full stack via the systemd unit. Skip
# restore cleanly on (a) no dump, or (b) DB already populated.
# -----------------------------------------------------------------------------
remote_bash_args "${remote_dump_path:-}" <<'EOS'
set -euo pipefail
dump_path="${1:-}"
cd "$HOME/.buzz"
echo "compose pull..."
docker compose pull --quiet

if [[ -n "$dump_path" ]]; then
  # Load the backing-service secrets from .env (set -a exports all
  # variables; we then set +a to keep them out of the global env).
  set -a; . ./.env; set +a

  echo "bringing up Postgres (for restore)..."
  # Bring up Postgres only. `--wait` here would also wait for any service
  # that depends on Postgres (i.e., the relay), which would hang the script
  # until the relay is healthy — but we're explicitly NOT bringing the
  # relay up yet because we're about to replay into Postgres. The relay
  # comes up via the systemd unit below, AFTER the replay succeeds.
  docker compose up --wait postgres

  # Idempotency: check if the DB already has tables (could happen if the
  # operator manually restored or a partial install happened). If empty,
  # replay; if populated, log a warning and skip to avoid clobbering.
  # Note: `< /dev/null` is critical — `docker compose exec` inherits the
  # parent's stdin and would otherwise eat the rest of the heredoc.
  table_count="$(docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" postgres \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" \
    < /dev/null || true)"
  table_count="${table_count:-0}"

  if [[ "$table_count" == "0" ]]; then
    echo "Postgres DB empty — replaying dump from $dump_path..."
    # NOTE: bash `cmd < a < b` means "read from b" (last redirect wins), and
    # `cmd1 | cmd2 < file` makes the `<` win over the pipe. We must use
    # exactly one of: pipe-only (`cat file | cmd`) OR `<`-only (`cmd < file`).
    # Pipe-only is simpler here.
    if ! cat "$dump_path" | docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" postgres \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1; then
      echo "FATAL: dump replay failed (above psql output)" >&2
      exit 5
    fi
    echo "  restore complete; clean up the dump file"
    rm -f "$dump_path"
  else
    echo "WARN: Postgres DB already has $table_count public table(s); skipping restore to avoid clobbering."
    echo "      If intentional, run manually:"
    echo "        cat $dump_path | docker compose exec -T -e PGPASSWORD=\"\$POSTGRES_PASSWORD\" postgres \\"
    echo "          psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -v ON_ERROR_STOP=1 < /dev/null"
    rm -f "$dump_path"
  fi

  # Bring up minio-init too so its bucket is ready before the relay
  # checks S3 access. No `--wait` here either (the relay depends on it).
  echo "bringing up minio-init..."
  docker compose up minio-init
else
  echo "no dump to restore (fresh deployment)"
fi

echo "starting buzz.service (this runs docker compose up in the foreground)..."
systemctl --user enable --now buzz.service
echo "waiting for relay healthcheck..."
for i in $(seq 1 60); do
  if docker compose exec -T relay bash -ec \
       'exec 3<>/dev/tcp/127.0.0.1/8080; printf "GET /_readiness HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" >&3; grep -q "200 OK" <&3'; then
    echo "relay healthy after ${i} attempts"
    exit 0
  fi
  sleep 2
done
echo "FATAL: relay did not become healthy within 120s" >&2
docker compose logs --tail=80 relay >&2
systemctl --user status buzz.service --no-pager >&2 || true
exit 4
EOS

# -----------------------------------------------------------------------------
# Stage 7 — Print summary + admin-bootstrap instructions
# -----------------------------------------------------------------------------
remote_bash_args <<'EOS'
set -euo pipefail
echo "================================================================="
echo "  Buzz relay is up on $(hostname). Files / ports / paths:"
echo "================================================================="
echo "  Compose file:  $HOME/.buzz/compose.yml"
echo "  Env file:      $HOME/.buzz/.env  (mode 0600)"
echo "  Volumes:       docker volume ls | grep buzz-  (postgres, redis, minio, git)"
echo "  Relay WS:      ws://127.0.0.1:3000   (loopback only)"
echo "  Relay health:  curl -fsS http://127.0.0.1:8080/_liveness"
echo "  Relay metrics: http://127.0.0.1:9102/metrics  (Prometheus)"
echo
echo "  Day-one admin bootstrap (HITL — do on this host):"
echo
hermes_npub_file="$HOME/.hermes/nostr.npub"
if [[ -s "$hermes_npub_file" ]]; then
  echo "    1. Hermes's npub (already on this host per #46):"
  echo "         $(cat "$hermes_npub_file")"
else
  echo "    1. Hermes's npub: not yet in $HOME/.hermes/nostr.npub"
  echo "         run scripts/unwrap-hermes-env.sh from the laptop first."
fi
echo
echo "    2. Add Hermes to the workspace as a Bot:"
echo "         cd ~/.buzz && docker compose exec relay buzz-admin add-member \\"
echo "             --pubkey <hermes-hex-pubkey> --role bot"
echo
echo "    3. Operator connects from the laptop via the Buzz desktop client:"
echo "         - Tailscale:  relay URL ws://grr-remote-dev-01:3000"
echo "         - SSH tunnel: ssh -L 3000:127.0.0.1:3000 $(hostname), then ws://127.0.0.1:3000"
echo
echo "    4. Operator creates the demo room in the Buzz UI, then sets on this host:"
echo "         echo BUZZ_HOME_CHANNEL=<uuid> >> \$HOME/.hermes/.env"
echo "         echo 'BUZZ_CHANNELS=[<uuid>]' >> \$HOME/.hermes/.env"
echo "         systemctl --user restart hermes-dashboard.service"
echo "         (Hermes connects to ws://127.0.0.1:3000 from the same host — no extra networking.)"
echo
echo "    5. Manage the stack:"
echo "         systemctl --user start|stop|status buzz.service"
echo "         cd ~/.buzz && docker compose logs -f relay"
echo "         cd ~/.buzz && docker compose pull relay && docker compose up -d relay  # upgrade"
echo "================================================================="
EOS

echo "Install complete."