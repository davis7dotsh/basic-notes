# tailscale notes

tailnet: example-tailnet.ts.net

## devices
- studio (mac studio) — 100.64.0.10
- nas (synology) — runs the tailscale pkg, subnet router for 192.168.1.0/24
- macbook, iphone, ipad
- hetzner vps — exit node for when i'm on sketchy cafe wifi

## commands
```bash
tailscale up --ssh --advertise-exit-node
tailscale status
tailscale ping nas
tailscale serve --bg 5173          # share a dev server on https://studio.example-tailnet.ts.net
tailscale serve status
tailscale funnel 443 on            # public internet, careful
tailscale cert studio.example-tailnet.ts.net
```

## ACL bits
- tag:server can't initiate to personal devices
- `"ssh": [{"action": "check", ...}]` for the vps so it re-auths every 12h

- MagicDNS on, so `ssh nas` just works
- vite needs `server.host = true` + `allowedHosts` for the ts.net name
