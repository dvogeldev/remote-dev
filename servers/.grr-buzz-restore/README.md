# Temporary restore staging for servers/grr-buzz.md

Parts `part-0.md` … `part-4.md` concatenate (in order) onto the current
`servers/grr-buzz.md` body to recover the full runbook after an MCP
truncation incident. Delete this directory once `servers/grr-buzz.md`
matches local `FINAL` (sha256 `d61e674344df1c25241516be7cf4be19f5f81c3469542cb1ca36bc857e6a971a`).

Concatenate:

```bash
cat servers/grr-buzz.md \
  servers/.grr-buzz-restore/part-{0,1,2,3,4}.md \
  > /tmp/grr-buzz-full.md
# then replace servers/grr-buzz.md with that result and delete this dir
```
