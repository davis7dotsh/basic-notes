# Agency sync — Oct 6

attendees: me, Silas (ops), Juno (partnerships), Kip (eng)

## roster
- 14 active creators, 2 in onboarding (Elsa, Ezra Q.)
- Milo wants to take a break Nov–Jan. fine, need to tell brands w/ open flights
- churn risk: Delphine — unhappy w/ deal flow in Q3. Juno to do a call this wk

## brand pipeline
| brand | creators | status | value |
|---|---|---|---|
| Shellby | 3 | contracting | $42k |
| Branchbase | 2 | verbal yes | $18k |
| Flick | 4 | proposal sent | $55k |
| LintHound | 1 | renewing | $9k |
| Tracewell | 2 | stalled, legal | $24k |

- Tracewell legal wants usage rights in perpetuity. hard no, 12 mo max
- Flick asked for a bundle discount if we do all 4. Juno suggests 8%, I'm ok up to 10

## ops
- invoicing is still manual in quickbooks. Silas spending ~6 hrs/wk on it
- Kip: can we just build the invoice gen off the deals sheet? he thinks 2 days of work
  - yes, but after the creator portal MVP
- need a shared calendar of upload dates across creators so brands don't overlap in same week

## creator portal (Kip)
- MVP: login, see your deals, see payout status, upload drafts for brand review
- stack: sveltekit + postgres + clerk for auth
- target: soft launch w/ 3 creators by Nov 1
- blocker: draft upload storage. R2 vs S3 — going R2, egress is free

## talent hiring
- still need a 2nd partnerships person. 31 applicants, Juno screening top 8
- eng contractor for the portal? Kip says not yet

## action items
- [ ] Juno: call Delphine
- [ ] Juno: push Tracewell legal on usage term
- [ ] Silas: upload calendar sheet v0
- [ ] Kip: portal auth + deals list by next sync
- [ ] me: reply to Flick w/ bundle pricing
- [ ] me: intro Elsa to Shellby team
