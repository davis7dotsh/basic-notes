# docker-compose for local dev

portal stack. `docker compose up -d` then `pnpm dev`

```yaml
services:
  postgres:
    image: postgres:17-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: portal
      POSTGRES_PASSWORD: changeme
      POSTGRES_DB: portal
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U portal"]
      interval: 5s
      timeout: 3s
      retries: 10

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    command: ["redis-server", "--appendonly", "yes"]

  minio:
    image: minio/minio:latest
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: minio
      MINIO_ROOT_PASSWORD: changeme
    ports:
      - "9000:9000"
      - "9001:9001"
    volumes:
      - miniodata:/data

  mailpit:
    image: axllent/mailpit
    ports:
      - "1025:1025"
      - "8025:8025"

  worker:
    build:
      context: .
      dockerfile: Dockerfile.worker
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATABASE_URL: postgres://portal:changeme@postgres:5432/portal
      REDIS_URL: redis://redis:6379
    ports:
      - "0.0.0.0:8080:8080"   # bind all ifaces so i can hit it over tailscale from the ipad

volumes:
  pgdata:
  miniodata:
```

## gotchas
- minio stands in for R2 locally, set `S3_ENDPOINT=http://localhost:9000` + `forcePathStyle: true`
- mailpit UI at :8025, catches all outbound mail
- `docker compose down -v` nukes the volumes, careful
- on mac, orbstack instead of docker desktop — way less RAM
- worker hot reload: mount `./src` and run `tsx watch` instead of building. todo
- if postgres won't start after an image bump (16→17), the data dir is incompatible, need pg_upgrade or just nuke for local
