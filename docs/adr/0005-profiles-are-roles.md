# Profiles are roles; day one is only `default`

A Hermes profile is who is at the desk (SOUL, skills, sessions, memory), not which MiniMax SKU is rented. Model lives in that profile's `config.yaml` (today: M3 default, Flash fallback, V4 Pro for research, MoA as a selectable council). Switch research/MoA at session start. Do not name profiles after SKUs.

Day one: only `default` (= operator, including coding). Clone `copy` / `research` / … with `--clone` or `--clone-from default` when that role has a skill. Never `--clone-all` (that copies memories). Rejected: playbook model profiles (`hermes-m27`, `hermes-m3`, `hermes-flash`); a 5×3 role×model matrix; pre-creating empty role shells.
