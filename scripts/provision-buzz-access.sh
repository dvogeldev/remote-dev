#!/usr/bin/env bash
# Provision the Cloudflare Access app for buzz.dvogeldev.com (#53).
# Reuses the account-level OTP IdP and the `david-ops` allowlist policy from
# hermes.dvogeldev.com (#35) — same operator, same allowlist. Reads creds from
# laptop `pass` (ADR-0007):
#   cloudflare/dvd/CLOUDFLARE_TOKEN_API
#   cloudflare/dvd/CLOUDFLARE_ACCOUNT_ID
#   cloudflare/dvd/CLOUDFLARE_ZONE_ID
#   cloudflare/dvd/ACCESS_IDP_UID
#   cloudflare/dvd/ACCESS_POLICY_UID
# Writes:
#   cloudflare/dvd/ACCESS_BUZZ_APP_UID
# Required env: $BUZZ_TUNNEL_UUID (output of `cloudflared tunnel create buzz-relay` on grr)
set -euo pipefail

TOKEN="$(pass show cloudflare/dvd/CLOUDFLARE_TOKEN_API)"
ACCOUNT="$(pass show cloudflare/dvd/CLOUDFLARE_ACCOUNT_ID)"
ZONE="$(pass show cloudflare/dvd/CLOUDFLARE_ZONE_ID)"
IDP="$(pass show cloudflare/dvd/ACCESS_IDP_UID)"
POLICY="$(pass show cloudflare/dvd/ACCESS_POLICY_UID)"

api() { curl -fsS -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"; }
api_post() { curl -fsS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"; }

upsert_app() {
  local existing
  existing="$(api "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/access/apps" \
    | jq -r '.result[] | select(.name=="buzz-dvogeldev") | .id' | head -n1 || true)"
  if [[ -n "$existing" ]]; then
    echo "app_uid=$existing (already configured)" >&2
    echo "$existing"
    return
  fi
  local resp
  resp="$(api_post "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/access/apps" \
    --data "$(jq -n --arg idp "$IDP" --arg pol "$POLICY" '{
      name:"buzz-dvogeldev",
      type:"self_hosted",
      domain:"buzz.dvogeldev.com",
      policies:[$pol],
      allowed_idps:[$idp],
      session_duration:"24h"
    }')")"
  local uid
  uid="$(echo "$resp" | jq -r '.result.id')"
  echo "app_uid=$uid" >&2
  echo "$uid"
}

upsert_dns_cname() {
  local uuid="$1"
  local target="${uuid}.cfargotunnel.com"
  local existing
  # Token may lack Zone: DNS: Read; treat "can't list" the same as "exists" so
  # the create step (which would also 403) is skipped. The CNAME was created
  # out-of-band by `cloudflared tunnel route dns --overwrite-dns` per the runbook.
  existing="$(api "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?type=CNAME&name=buzz.dvogeldev.com" \
    | jq -r '.result[0].id // empty' 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    echo "dns_cname_id=$existing (already configured)" >&2
    return
  fi
  if api_post "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" \
    --data "$(jq -n --arg name "buzz.dvogeldev.com" --arg content "$target" '{
      type:"CNAME",
      name:$name,
      content:$content,
      proxied:true
    }')" >/dev/null 2>&1; then
    echo "dns_cname created via API"
  else
    echo "dns_cname: API write failed (token likely lacks Zone: DNS: Edit); ensure record exists via 'cloudflared tunnel route dns --overwrite-dns buzz-relay buzz.dvogeldev.com'" >&2
  fi
}

main() {
  : "${BUZZ_TUNNEL_UUID:?Set BUZZ_TUNNEL_UUID to the tunnel UUID from 'cloudflared tunnel create buzz-relay' on grr}"

  echo "=== Access app ===" >&2
  local app
  app="$(upsert_app)"
  pass insert -m cloudflare/dvd/ACCESS_BUZZ_APP_UID <<<"$app" >/dev/null

  echo "=== DNS CNAME ===" >&2
  upsert_dns_cname "$BUZZ_TUNNEL_UUID"

  echo "done" >&2
}

main
