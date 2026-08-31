# grr-remote-dev-01

## Specs

| Property       | Value                |
|----------------|----------------------|
| Hostname       | grr-remote-dev-01    |
| OS             | Ubuntu 24.04 LTS (Noble Numbat) |
| Provider       | RackGenius           |
| Location       | Grand Rapids, MI     |
| Swap           | 1 GB                 |
| SSH Key        | Rackgenius           |

## Network

| Property | Value         |
|----------|---------------|
| IPv4     | 163.123.236.73 |
| IPv6     | 2602:f964:1:7a::a |
| Tailscale IPv4 | 100.80.237.36 |
| Tailscale IPv6 | fd7a:115c:a1e0::cf3a:ed25 |
| MagicDNS | grr-remote-dev-01.tail6acbf0.ts.net |
| SSH Port | 22            |
| DNS Resolvers | 1.1.1.1, 8.8.8.8 |
| Tailscale SSH | off (use sshd) |

## Access

| Property | Value         |
|----------|---------------|
| User     | david (uid 1000; sudo, docker) |
| SSH Keys | `~/.ssh/rack_genius01` (Host `grr` / `grr-remote-dev-01`) |

## Services

- Hermes instance
- Container-based remote dev environment
