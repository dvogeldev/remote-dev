# Host filesystem: two trees, Hermes sandbox sees both

Coding lives in `~/projects/<repo>`. Agency lives in `~/agency/{canon,inbox,artifacts}`; only `canon` is a git repo. Drop `~/workspace` as a name.

Project containers bind-mount only that repo. Hermes itself is not those containers: with `terminal.backend: local` (ADR-0004) it sees both trees as the host user. If Docker backend is ever turned on, mount `~/projects` → `/workspace/projects` and `~/agency` → `/workspace/agency`; do not mount `~/.hermes` as a workspace.

Rejected: agency inside every project container; agency invisible to Hermes; one git remote for inbox.
