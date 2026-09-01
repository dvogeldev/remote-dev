# Hermes secrets live in `pass` on the laptop

Source of truth is the existing Unix password store on the operator laptop (`pass`, GPG). Kilo’s Gateway key is `kilocode/KILOCODE_API_KEY`. Hermes on `grr-remote-dev-01` only ever sees a mode-600 checkout at `~/.hermes/.env`. Unwrap with `scripts/unwrap-hermes-env.sh` (SSH Host `grr`). Do not install `pass` + the GPG key on the VPS (local Hermes shell would then `pass show`). Do not use Cloudflare Secrets Store for this process: that product’s consumer scope is Workers bindings, not a host-plane `.env`.
