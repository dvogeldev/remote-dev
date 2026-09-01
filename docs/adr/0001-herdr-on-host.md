# Herdr lives on the host plane

The operator's daily coding path is `herdr --remote` from the laptop onto an always-on Herdr on the VPS. Herdr (and nvim) stay on the host plane so disconnects and project-container rebuilds do not kill the mux. Project toolchains go in per-repo Dev Containers; panes `devcontainer exec` into them. Rejected: Herdr inside `dev-base` (system diagram) and a Herdr-less agent-only box (playbook).
