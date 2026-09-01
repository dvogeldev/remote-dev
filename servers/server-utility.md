# Server Utility Guide

Quick reference for checking connectivity and latency on `grr-remote-dev-01`.

## Server Info

| Property | Value |
|----------|-------|
| Hostname | grr-remote-dev-01 |
| IPv4 | 163.123.236.73 |
| IPv6 | 2602:f964:1:7a::a |
| SSH Port | 22 |

---

## Connectivity Checks

### Ping

Basic round-trip latency:

```bash
ping 163.123.236.73
```

With count limit:

```bash
ping -c 5 163.123.236.73
```

### Ping with Timestamp

Log pings with timestamps:

```bash
ping 163.123.236.73 | while read line; do echo "$(date): $line"; done
```

---

## Latency & Traceroute

### MTR

Combines traceroute and ping with continuous stats. Install with `apt install mtr`:

```bash
mtr 163.123.236.73
```

### Traceroute

Show the path packets take to the server:

```bash
traceroute 163.123.236.73
```

---

## DNS Resolution

### Check DNS Resolver Response

```bash
# Test 1.1.1.1 (Cloudflare)
dig 1.1.1.1

# Test 8.8.8.8 (Google)
dig 8.8.8.8

# Time a DNS query
time dig google.com @8.8.8.8
```

---

## HTTP Response Time

### cURL Timing

```bash
curl -o /dev/null -s -w "DNS: %{time_namelookup}s\nConnect: %{time_connect}s\nSSL: %{time_appconnect}s\nTotal: %{time_total}s\n" https://163.123.236.73
```

### wget

```bash
wget -q --spider http://163.123.236.73
```

---

## Port Availability

### Netcat

Check if SSH port is open and responsive:

```bash
nc -zv 163.123.236.73 22 -w 5
```

### Telnet

```bash
telnet 163.123.236.73 22
```

---

## Quick Reference

| Command | Purpose |
|---------|---------|
| `ping -c 5 <ip>` | Round-trip latency (5 packets) |
| `mtr <ip>` | Traceroute + latency stats |
| `curl -w` | HTTP request timing breakdown |
| `dig @<resolver> <domain>` | DNS resolver response |
| `nc -zv <ip> <port>` | Port availability check |

---

## Quick Connectivity Test

Run this to get a quick overview:

```bash
ping -c 3 163.123.236.73 && echo "---" && nc -zv 163.123.236.73 22 -w 3
```
