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
    echo "idp_uid=$existing (already configured)"
    echo "$existing"
    return
  fi
  local resp
  resp="$(api_post "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/access/identity_providers" \
    --data '{"name":"One-time PIN login","type":"onetimepin","config":{}}')"
  echo "$resp" | jq -r '.result.id' | xargs -I{} echo "idp_uid={}"
  echo "$resp" | jq -r '.result.id'
}

upsert_policy() {
  local existing
  existing="$(api "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/access/policies" \
    | jq -r '.result[] | select(.name=="david-ops") | .id' | head -n1 || true)"
  if [[ -n "$existing" ]]; then
    echo "policy_uid=$existing (already configured)"
    echo "$existing"
    return
  fi
  local resp
  resp="$(api_post "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/access/policies" \
    --data "$(jq -n --arg email "$EMAIL" '{name:"david-ops",decision:"allow",include:[{email:{email:$email}}]}')")"
  echo "$resp" | jq -r '.result.id' | xargs -I{} echo "policy_uid={}"
  echo "$resp" | jq -r '.result.id'
}

upsert_app() {
  local idp="$1" policy="$2"
  local existing
  existing="$(api "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/access/apps" \
    | jq -r '.result[] | select(.name=="hermes-dvogeldev") | .id' | head -n1 || true)"
  if [[ -n "$existing" ]]; then
    echo "app_uid=$existing (already configured)"
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
  echo "$resp" | jq -r '.result.id' | xargs -I{} echo "app_uid={}"
  echo "$resp" | jq -r '.result.id'
}

upsert_dns_cname() {
  local uuid="$1"
  local target="${uuid}.cfargotunnel.com"
  local existing
  existing="$(api "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?type=CNAME&name=hermes.dvogeldev.com" \
    | jq -r '.result[0].id // empty')"
  if [[ -n "$existing" ]]; then
    echo "dns_cname_id=$existing (already configured)"
    return
  fi
  api_post "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" \
    --data "$(jq -n --arg name "hermes.dvogeldev.com" --arg content "$target" '{
      type:"CNAME",
      name:$name,
      content:$content,
      proxied:true
    }')" | jq -r '.result.id' | xargs -I{} echo "dns_cname_id={}"
}

main() {
  : "${HERMES_TUNNEL_UUID:?Set HERMES_TUNNEL_UUID to the tunnel UUID from 'cloudflared tunnel create hermes-gui' on grr}"

  echo "=== Identity provider ==="
  local idp
  idp="$(upsert_idp)"
  pass insert -m cloudflare/dvd/ACCESS_IDP_UID <<<"$idp" >/dev/null

  echo "=== Allow policy ==="
  local policy
  policy="$(upsert_policy)"
  pass insert -m cloudflare/dvd/ACCESS_POLICY_UID <<<"$policy" >/dev/null

  echo "=== Access app ==="
  local app
  app="$(upsert_app "$idp" "$policy")"
  pass insert -m cloudflare/dvd/ACCESS_APP_UID <<<"$app" >/dev/null

  echo "=== DNS CNAME ==="
  upsert_dns_cname "$HERMES_TUNNEL_UUID"

  echo "done"
}

main