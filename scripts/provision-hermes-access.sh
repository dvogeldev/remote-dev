#!/usr/bin/env bash
# Provision the Cloudflare Access + Tunnel pieces for hermes.dvogeldev.com (#35).
# Reads creds from laptop `pass` (per ADR-0007):
#   cloudflare/dvd/CLOUDFLARE_TOKEN_API
#   cloudflare/dvd/CLOUDFLARE_ACCOUNT_ID
#   cloudflare/dvd/CLOUDFLARE_ZONE_ID
#   cloudflare/dvd/ALLOWLIST_EMAIL
# Writes:
#   cloudflare/dvd/ACCESS_IDP_UID
#   cloudflare/dvd/ACCESS_POLICY_UID
#   cloudflare/dvd/ACCESS_APP_UID
# Required env: $HERMES_TUNNEL_UUID (output of `cloudflared tunnel create hermes-gui` on grr)
set -euo pipefail

TOKEN="$(pass show cloudflare/dvd/CLOUDFLARE_TOKEN_API)"
ACCOUNT="$(pass show cloudflare/dvd/CLOUDFLARE_ACCOUNT_ID)"
ZONE="$(pass show cloudflare/dvd/CLOUDFLARE_ZONE_ID)"
EMAIL="$(pass show cloudflare/dvd/ALLOWLIST_EMAIL)"

api() { curl -fsS -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"; }
api_post() { curl -fsS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"; }
api_put() { curl -fsS -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"; }

upsert_idp() {
  local existing
  existing="$(api "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/access/identity_providers" \
    | jq -r '.result[] | select(.type=="onetimepin") | .id' | head -n1 || true)"
  if [[ -n "$existing" ]]; then
    echo "idp_uid=$existing (already configured)" >&2
    echo "$existing"
    return
  fi
  local resp
  resp="$(api_post "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/access/identity_providers" \
    --data '{"name":"One-time PIN login","type":"onetimepin","config":{}}')"
  local uid
  uid="$(echo "$resp" | jq -r '.result.id')"
  echo "idp_uid=$uid" >&2
  echo "$uid"
}

upsert_policy() {
  local existing
  existing="$(api "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/access/policies" \
    | jq -r '.result[] | select(.name=="david-ops") | .id' | head -n1 || true)"
  if [[ -n "$existing" ]]; then
    local resp
    resp="$(api_put "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/access/policies/$existing" \
      --data "$(jq -n --arg email "$EMAIL" '{name:"david-ops",decision:"allow",include:[{email:{email:$email}}]}')")"
    echo "policy_uid=$existing (updated allowlist to $EMAIL)" >&2
    echo "$existing"
    return
  fi
  local resp
  resp="$(api_post "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/access/policies" \
    --data "$(jq -n --arg email "$EMAIL" '{name:"david-ops",decision:"allow",include:[{email:{email:$email}}]}')")"
  local uid
  uid="$(echo "$resp" | jq -r '.result.id')"
  echo "policy_uid=$uid" >&2
  echo "$uid"
}

upsert_app() {
  local idp="$1" policy="$2"
  local existing
  existing="$(api "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/access/apps" \
    | jq -r '.result[] | select(.name=="hermes-dvogeldev") | .id' | head -n1 || true)"
  if [[ -n "$existing" ]]; then
    echo "app_uid=$existing (already configured)" >&2
    echo "$existing"
    return
  fi
  local resp
  resp="$(api_post "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/access/apps" \
    --data "$(jq -n --arg idp "$idp" --arg pol "$policy" '{
      name:"hermes-dvogeldev",
      type:"self_hosted",
      domain:"hermes.dvogeldev.com",
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
  existing="$(api "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?type=CNAME&name=hermes.dvogeldev.com" \
    | jq -r '.result[0].id // empty' 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    echo "dns_cname_id=$existing (already configured)" >&2
    return
  fi
  if api_post "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" \
    --data "$(jq -n --arg name "hermes.dvogeldev.com" --arg content "$target" '{
      type:"CNAME",
      name:$name,
      content:$content,
      proxied:true
    }')" >/dev/null 2>&1; then
    echo "dns_cname created via API"
  else
    echo "dns_cname: API write failed (token likely lacks Zone: DNS: Edit); ensure record exists via 'cloudflared tunnel route dns --overwrite-dns hermes-gui hermes.dvogeldev.com'" >&2
  fi
}

main() {
  : "${HERMES_TUNNEL_UUID:?Set HERMES_TUNNEL_UUID to the tunnel UUID from 'cloudflared tunnel create hermes-gui' on grr}"

  echo "=== Identity provider ===" >&2
  local idp
  idp="$(upsert_idp)"
  pass insert -m cloudflare/dvd/ACCESS_IDP_UID <<<"$idp" >/dev/null

  echo "=== Allow policy ===" >&2
  local policy
  policy="$(upsert_policy)"
  pass insert -m cloudflare/dvd/ACCESS_POLICY_UID <<<"$policy" >/dev/null

  echo "=== Access app ===" >&2
  local app
  app="$(upsert_app "$idp" "$policy")"
  pass insert -m cloudflare/dvd/ACCESS_APP_UID <<<"$app" >/dev/null

  echo "=== DNS CNAME ===" >&2
  upsert_dns_cname "$HERMES_TUNNEL_UUID"

  echo "done" >&2
}

main