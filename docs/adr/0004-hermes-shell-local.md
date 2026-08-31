# Hermes commands run on the host (`terminal.backend: local`)

The Hermes **process** stays native (`install.sh` on the host plane). Its **shell** is also native: `terminal.backend: local`, the official default. File, terminal, and `execute_code` tools run as the login user, so mixed canon + coding sessions see `~/agency` and `~/projects` without a second bind-mount, and Hermes can `devcontainer exec` into the same project container as a Herdr pane.

Rejected: wrapping Hermes in `nousresearch/hermes-agent` (supported, not our install). Rejected: a generic Docker sandbox as the default shell (playbook) — safer, but a second Node/toolchain that lies next to per-project containers. Approvals stay on; YOLO off. Docker backend remains available later for one untrusted job; it is not the daily path.
