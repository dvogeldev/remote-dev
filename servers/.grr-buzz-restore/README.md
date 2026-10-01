# Finish `servers/grr-buzz.md` (full body)

Canonical full runbook sha256:
`d61e674344df1c25241516be7cf4be19f5f81c3469542cb1ca36bc857e6a971a`

## Preferred: decode the gzip payload (one file)

```bash
base64 -d servers/.grr-buzz-restore/grr-buzz.md.gz.b64 | gzip -d > servers/grr-buzz.md
sha256sum servers/grr-buzz.md   # expect d61e6743…
rm -rf servers/.grr-buzz-restore
git add -A servers && git commit -m "docs(grr-buzz): restore full runbook from staged gzip" && git push
```

## Alternate: concat parts onto current partial body

Current `servers/grr-buzz.md` on main ends after **Upgrade the relay image**
(ops note is present). Parts `part-0`…`part-4` continue from Rotate keypairs.

```bash
cat servers/grr-buzz.md servers/.grr-buzz-restore/part-{0,1,2,3,4}.md > /tmp/g.md
sha256sum /tmp/g.md   # should match d61e6743…
cp /tmp/g.md servers/grr-buzz.md && rm -rf servers/.grr-buzz-restore
```

Or copy from Grok box: `/workspace/remote-dev/servers/grr-buzz.md` (already FINAL).
