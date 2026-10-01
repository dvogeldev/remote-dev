# Temporary staging: finish `servers/grr-buzz.md`

`servers/grr-buzz.md` on `main` currently ends after **Upgrade the relay image**
(ops note + day-one + Operating are present). Append parts in order to recover
the full runbook (Rotate keypairs → Backups → Files → Out of scope → Done means).

Expected full file sha256:
`d61e674344df1c25241516be7cf4be19f5f81c3469542cb1ca36bc857e6a971a`

## One-liner (from repo root after `git pull`)

```bash
cat servers/grr-buzz.md \
  servers/.grr-buzz-restore/part-{0,1,2,3,4}.md \
  > /tmp/grr-buzz-full.md
sha256sum /tmp/grr-buzz-full.md
# expect d61e6743… then:
cp /tmp/grr-buzz-full.md servers/grr-buzz.md
rm -rf servers/.grr-buzz-restore
git add servers/grr-buzz.md && git commit -m "docs(grr-buzz): complete runbook after MCP restore" && git push
```

Or copy from the Grok box clone: `/workspace/remote-dev/servers/grr-buzz.md`
(already the full FINAL).

Delete this directory once the single-file runbook matches that hash.
