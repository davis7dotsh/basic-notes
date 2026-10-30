# nginx for the blog

on the hetzner box. blog is sveltekit node adapter on :3000, plausible on :8000

```nginx
server {
    listen 80;
    server_name example.com www.example.com;
    return 301 https://example.com$request_uri;
}

server {
    listen 443 ssl http2;
    server_name example.com;

    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;

    location /_app/immutable/ {
        proxy_pass http://127.0.0.1:3000;
        add_header Cache-Control "public, max-age=31536000, immutable";
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

server {
    listen 443 ssl http2;
    server_name stats.example.com;
    ssl_certificate     /etc/letsencrypt/live/stats.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/stats.example.com/privkey.pem;
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
    }
}
```

- `sudo nginx -t && sudo systemctl reload nginx`
- certbot renew is on a systemd timer, check `systemctl list-timers`
- sveltekit needs `ORIGIN=https://example.com` + `PROTOCOL_HEADER=x-forwarded-proto`
- honestly should just move this to vercel or a cf tunnel. one less box
- 502? → `journalctl -u blog -n 100`, usually the node process died after a deploy
