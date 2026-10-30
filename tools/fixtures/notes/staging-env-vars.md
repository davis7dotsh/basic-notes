staging env vars

(values in 1password → "agency-portal staging")

```
NODE_ENV=production
PORT=3000
ORIGIN=https://staging.portal.example.dev
DATABASE_URL=postgres://portal:****@staging-db.internal:5432/portal
REDIS_URL=redis://staging-redis.internal:6379
CLERK_SECRET_KEY=sk_test_****
PUBLIC_CLERK_PUBLISHABLE_KEY=pk_test_****
R2_ACCOUNT_ID=****
R2_BUCKET=portal-drafts-staging
STRIPE_WEBHOOK_SECRET=whsec_****
SENTRY_DSN=https://****@o0.ingest.sentry.io/0
LOG_LEVEL=debug
```
- ORIGIN must match exactly or sveltekit form actions 403 (CSRF check)
