# Interview rubric — senior eng

for agency eng hires (portal + internal tools). 4 rounds, each interviewer fills this out before talking to anyone else (no anchoring)

## scale
- 1 = strong no, 2 = lean no, 3 = lean yes, 4 = strong yes
- no 2.5s. pick a side.

## round 1 — practical coding (60 min, their machine, any language)
task: build a tiny CLI that ingests a CSV of brand deals and outputs payouts per creator, w/ edge cases (refunds, split deals)
| signal | what a 4 looks like |
|---|---|
| decomposition | breaks it up before typing, names things well |
| correctness | handles the refund + split edge cases unprompted |
| tooling | comfortable in their editor, uses tests/REPL to check |
| communication | narrates tradeoffs, asks about ambiguous reqs |
| AI usage | uses agents if they want, but can explain every line |

## round 2 — system design (60 min)
prompt: design the creator portal draft-upload + brand review flow
- storage choice + why (S3/R2), signed URLs
- auth model: creator vs brand vs agency staff
- notifications, what happens when a brand never responds
- a 4 here: scopes it down first, talks failure modes, doesn't over-engineer w/ kafka

## round 3 — past project deep dive (45 min)
- pick one project they're proud of. go 5 levels deep on one decision
- red flags: can't explain why, only "we", blames others for everything
- green flags: talks about what they'd do differently, knows the numbers

## round 4 — values / team fit (30 min, me)
- how do they handle a creator (non-technical) asking for something unreasonable
- async writing sample: we send a vague slack msg, they reply
- ownership: tell me about something you shipped that broke

## decision
- need avg ≥ 3.0 AND no 1s
- debrief within 24h, written first, then talk
- hiring manager (me) makes the final call, can override w/ a written reason

## comp bands (2026)
- senior: $165–195k + bonus
- staff: $200–235k
- contractors: $95–130/hr
