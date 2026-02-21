#!/usr/bin/env python3
"""Generate expanded corpus.json (56 emails)."""
from gen_helpers import E, P, A, write_json

emails = []

# 001
emails.append(E("falcon-launch","<falcon-launch-001@test.example.com>","Alice tells Bob Falcon launch date March 15",
P("Alice Chen <alice@acme.com>","Bob Martinez <bob@acme.com>","Project Falcon launch date","<falcon-launch-001@test.example.com>","Wed, 05 Feb 2025 09:00:00 +0000",
"Hi Bob,\r\n\r\nThe launch date for Project Falcon is confirmed for March 15, 2025.\r\nPlease make sure the QA team is ready by March 10.\r\n\r\nWe also need the staging environment validated before the 12th.\r\nLet me know if you foresee any blockers.\r\n\r\nThanks,\r\nAlice")))

# 002
emails.append(E("falcon-reply","<falcon-reply-002@test.example.com>","Bob confirms QA readiness, mentions dry run March 12",
P("Bob Martinez <bob@acme.com>","Alice Chen <alice@acme.com>","Re: Project Falcon launch date","<falcon-reply-002@test.example.com>","Wed, 05 Feb 2025 14:30:00 +0000",
"Hi Alice,\r\n\r\nGot it. QA will be ready by March 10. I've also scheduled a dry run for March 12.\r\nThe staging environment is already set up and passing basic smoke tests.\r\n\r\nOne concern: we still need the API keys for the payment gateway integration.\r\nCan you check with Dave's team?\r\n\r\nBest,\r\nBob\r\n\r\n> On Wed, 05 Feb 2025 at 09:00, Alice Chen wrote:\r\n> The launch date for Project Falcon is confirmed for March 15, 2025.\r\n> Please make sure the QA team is ready by March 10.",
irt="<falcon-launch-001@test.example.com>",ref="<falcon-launch-001@test.example.com>")))

# 003
emails.append(E("budget-meeting","<budget-meeting-003@test.example.com>","Carol invites team to Q1 budget review Feb 20",
P("Carol Davis <carol@acme.com>","Engineering Team <engineering@acme.com>","Q1 budget review meeting - Feb 20","<budget-meeting-003@test.example.com>","Mon, 10 Feb 2025 08:00:00 +0000",
"Hi team,\r\n\r\nReminder: the Q1 budget review meeting is scheduled for February 20, 2025 at 2pm in Conference Room B.\r\n\r\nPlease bring your department expense reports and any budget change requests.\r\nWe need to finalize allocations before the March board meeting.\r\n\r\nAgenda:\r\n1. Q1 actuals vs. plan\r\n2. Headcount requests\r\n3. Infrastructure spending\r\n4. Travel budget adjustments\r\n\r\nRegards,\r\nCarol",
cc="Bob Martinez <bob@acme.com>, Finance <finance@acme.com>")))

# 004
emails.append(E("server-down","<server-down-004@test.example.com>","Dave urgently reports production server outage",
P("Dave Wilson <dave@acme.com>","Bob Martinez <bob@acme.com>","URGENT: Production server down - immediate action needed","<server-down-004@test.example.com>","Tue, 11 Feb 2025 03:15:00 +0000",
"Bob,\r\n\r\nProduction server us-east-1 is DOWN. All customer-facing APIs are returning 503.\r\nThis started at 3:05 AM UTC. We need someone to investigate ASAP.\r\n\r\nThe monitoring dashboard shows:\r\n- CPU usage spiked to 100% at 3:04 AM\r\n- Database connections exhausted\r\n- No recent deployments in the last 24h\r\n\r\nI've already paged the on-call team but haven't gotten a response.\r\nPlease escalate if you can.\r\n\r\n-- Dave",
cc="Ops Team <ops@acme.com>")))

# 005
emails.append(E("holiday-schedule","<holiday-schedule-005@test.example.com>","HR 2025 holiday schedule",
P("HR Department <hr@acme.com>","All Staff <allstaff@acme.com>","2025 Company Holiday Schedule","<holiday-schedule-005@test.example.com>","Fri, 03 Jan 2025 10:00:00 +0000",
"Dear colleagues,\r\n\r\nPlease find below the official 2025 company holiday schedule:\r\n\r\n- Jan 1: New Year's Day\r\n- Jan 20: Martin Luther King Jr. Day\r\n- Feb 17: Presidents' Day\r\n- May 26: Memorial Day\r\n- Jul 4: Independence Day\r\n- Sep 1: Labor Day\r\n- Nov 27-28: Thanksgiving\r\n- Dec 24-25: Christmas\r\n- Dec 31: New Year's Eve (half day)\r\n\r\nPlease plan your PTO requests accordingly.\r\n\r\nBest regards,\r\nHR Department",
bcc="Bob Martinez <bob@acme.com>")))

# 006
emails.append(E("q1-report-attachment","<q1-report-006@test.example.com>","Eve sends Q1 financial report with xlsx",
A("Eve Park <eve@acme.com>","Bob Martinez <bob@acme.com>","Q1 financial report attached","<q1-report-006@test.example.com>","Thu, 13 Feb 2025 11:30:00 +0000",
"Hi Bob,\r\n\r\nPlease find attached the Q1 financial report for your review before the budget meeting.\r\n\r\nKey highlights:\r\n- Revenue: $2.4M (up 15% YoY)\r\n- Operating expenses: $1.8M (within budget)\r\n- Net margin: 25%\r\n\r\nLet me know if you have questions.\r\n\r\nEve",
"Q1-Financial-Report-2025.xlsx","application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")))

# 007
emails.append(E("vendor-original","<vendor-original-007@test.example.com>","Frank starts vendor contract renewal thread",
P("Frank Lee <frank@acme.com>","Grace Kim <grace@acme.com>","Vendor contract renewal - CloudStore Inc.","<vendor-original-007@test.example.com>","Mon, 03 Feb 2025 09:00:00 +0000",
"Hi Grace,\r\n\r\nThe CloudStore Inc. contract expires on March 31, 2025.\r\nTheir renewal proposal is $45,000/year (up from $38,000).\r\n\r\nI think we should negotiate. Their competitor DataVault is offering similar storage at $35,000/year.\r\nCan you prepare a comparison analysis?\r\n\r\nThanks,\r\nFrank",
cc="Heidi Tanaka <heidi@acme.com>")))

# 008
emails.append(E("vendor-reply-1","<vendor-reply1-008@test.example.com>","Grace replies with comparison analysis",
P("Grace Kim <grace@acme.com>","Frank Lee <frank@acme.com>","Re: Vendor contract renewal - CloudStore Inc.","<vendor-reply1-008@test.example.com>","Tue, 04 Feb 2025 14:00:00 +0000",
"Hi Frank,\r\n\r\nI've done the comparison:\r\n\r\nCloudStore: 5TB, 99.9% uptime SLA, 24/7 phone support, no migration risk. $45,000/yr\r\nDataVault: 5TB, 99.5% uptime SLA, email-only support, 2-3 weeks migration. $35,000/yr\r\n\r\nRecommendation: negotiate CloudStore to $40,000 using DataVault quote. Migration risk isn't worth $5K savings.\r\n\r\nGrace",
cc="Heidi Tanaka <heidi@acme.com>",irt="<vendor-original-007@test.example.com>",ref="<vendor-original-007@test.example.com>")))

# 009
emails.append(E("vendor-reply-2","<vendor-reply2-009@test.example.com>","Heidi agrees, will negotiate with CloudStore",
P("Heidi Tanaka <heidi@acme.com>","Frank Lee <frank@acme.com>, Grace Kim <grace@acme.com>","Re: Vendor contract renewal - CloudStore Inc.","<vendor-reply2-009@test.example.com>","Wed, 05 Feb 2025 10:00:00 +0000",
"Agreed with Grace. I'll reach out to CloudStore's account manager today and push for $40K.\r\n\r\nAlso want to add a clause for automatic scaling if we exceed 5TB. Our data growth suggests we'll hit that by Q3.\r\n\r\n-- Heidi",
irt="<vendor-reply1-008@test.example.com>",ref="<vendor-original-007@test.example.com> <vendor-reply1-008@test.example.com>")))

# 010
emails.append(E("mark-topic-1","<mark-topic1-010@test.example.com>","Mark: new hire Lisa Wong starting Monday",
P("Mark Johnson <mark@acme.com>","Bob Martinez <bob@acme.com>","New hire starting Monday - Lisa Wong","<mark-topic1-010@test.example.com>","Thu, 06 Feb 2025 09:00:00 +0000",
"Hi Bob,\r\n\r\nJust a heads-up: Lisa Wong is joining the backend team this Monday, Feb 10.\r\nShe'll need access to the dev environment and a desk in Building 3.\r\n\r\nCan you set up her accounts and assign her a buddy?\r\n\r\nThanks,\r\nMark")))

# 011
emails.append(E("mark-topic-2","<mark-topic2-011@test.example.com>","Mark: office renovation March 3-14",
P("Mark Johnson <mark@acme.com>","Bob Martinez <bob@acme.com>","Office renovation schedule - Building 3","<mark-topic2-011@test.example.com>","Fri, 07 Feb 2025 15:00:00 +0000",
"Bob,\r\n\r\nThe Building 3 renovation is scheduled for March 3-14.\r\nYour team will need to relocate to Building 1 during that period.\r\n\r\nPlease identify any equipment that can't be moved and we'll arrange alternatives.\r\n\r\nMark")))

# 012
emails.append(E("mark-topic-3","<mark-topic3-012@test.example.com>","Mark: company offsite April 5-6",
P("Mark Johnson <mark@acme.com>","Bob Martinez <bob@acme.com>","Company offsite - April 5-6","<mark-topic3-012@test.example.com>","Mon, 10 Feb 2025 11:00:00 +0000",
"Hi Bob,\r\n\r\nThe annual company offsite is happening April 5-6 at the Lakeside Resort.\r\nPlease RSVP by February 25 and indicate any dietary restrictions.\r\n\r\nActivities include team-building exercises, a keynote from the CEO, and a dinner cruise.\r\n\r\nMark")))

# 013
emails.append(E("deadline-email","<deadline-013@test.example.com>","Nora: compliance audit docs needed by Feb 28",
P("Nora Patel <nora@acme.com>","Bob Martinez <bob@acme.com>","Compliance audit documents needed by Feb 28","<deadline-013@test.example.com>","Wed, 12 Feb 2025 09:00:00 +0000",
"Hi Bob,\r\n\r\nThe annual compliance audit is coming up. I need these documents by February 28, 2025:\r\n\r\n1. Code review logs for Q4 2024\r\n2. Security incident reports\r\n3. Access control audit trail\r\n4. Data retention policy acknowledgments\r\n\r\nThis deadline is firm - the auditors arrive March 3.\r\n\r\nThanks,\r\nNora")))

# 014
emails.append(E("cross-reference","<cross-ref-014@test.example.com>","Alice follows up on API keys for Falcon",
P("Alice Chen <alice@acme.com>","Bob Martinez <bob@acme.com>","API keys for Falcon - following up","<cross-ref-014@test.example.com>","Fri, 07 Feb 2025 16:00:00 +0000",
"Bob,\r\n\r\nAs discussed in my previous email about the Falcon launch, we need the payment gateway API keys before March 10.\r\n\r\nI've checked with Dave's team and they say the keys are pending approval from the vendor.\r\nDave, can you provide an ETA?\r\n\r\nWe can't proceed with payment integration testing without them.\r\n\r\nAlice",
cc="Dave Wilson <dave@acme.com>")))

# 015
emails.append(E("processed-email","<processed-015@test.example.com>","IT password reset (will be marked processed)",
P("IT Support <it@acme.com>","Bob Martinez <bob@acme.com>","Password reset completed","<processed-015@test.example.com>","Mon, 03 Feb 2025 12:00:00 +0000",
"Hi Bob,\r\n\r\nYour VPN password has been reset as requested.\r\nNew temporary password: TempPass2025!\r\n\r\nPlease change it within 24 hours via the IT portal.\r\n\r\n-- IT Support Team"),True))

# 016
emails.append(E("alice-recent","<alice-recent-016@test.example.com>","Alice updates Falcon timeline to March 17",
P("Alice Chen <alice@acme.com>","Bob Martinez <bob@acme.com>","Updated Falcon timeline","<alice-recent-016@test.example.com>","Thu, 13 Feb 2025 17:00:00 +0000",
"Bob,\r\n\r\nQuick update: the marketing team requested a 2-day delay for the Falcon launch.\r\nNew date is March 17, 2025 instead of March 15.\r\n\r\nAll other deadlines shift accordingly:\r\n- QA ready: March 12 (was March 10)\r\n- Dry run: March 14 (was March 12)\r\n\r\nSorry for the late change. Let me know if this causes issues.\r\n\r\nAlice")))

# 017 - Server incident reply 1
emails.append(E("server-reply-1","<server-reply1-017@test.example.com>","Bob found connection pool leak in batch job",
P("Bob Martinez <bob@acme.com>","Dave Wilson <dave@acme.com>","Re: URGENT: Production server down - immediate action needed","<server-reply1-017@test.example.com>","Tue, 11 Feb 2025 03:45:00 +0000",
"Dave,\r\n\r\nI'm on it. The new batch job deployed Friday has a connection leak — each run opens 50 connections and never releases them.\r\n\r\nRestarted the app server and bumped pool limit to 200. APIs responding again.\r\n\r\nWill push proper fix in the morning.\r\n\r\nBob",
cc="Ops Team <ops@acme.com>",irt="<server-down-004@test.example.com>",ref="<server-down-004@test.example.com>")))

# 018 - Server incident reply 2
emails.append(E("server-reply-2","<server-reply2-018@test.example.com>","Dave confirms missing finally block, PR #847",
P("Dave Wilson <dave@acme.com>","Bob Martinez <bob@acme.com>","Re: URGENT: Production server down - immediate action needed","<server-reply2-018@test.example.com>","Tue, 11 Feb 2025 08:30:00 +0000",
"Bob,\r\n\r\nConfirmed: nightly analytics batch job missing a finally block in DB client. Leaking 50 connections per run since Friday.\r\n\r\nFix deployed to staging. Please review PR #847 — want it in prod before tonight's batch window.\r\n\r\nAlso added connection pool monitor to Grafana.\r\n\r\nDave",
cc="Ops Team <ops@acme.com>",irt="<server-reply1-017@test.example.com>",ref="<server-down-004@test.example.com> <server-reply1-017@test.example.com>")))

# 019 - Server incident resolved
emails.append(E("server-resolved","<server-resolved-019@test.example.com>","Server incident resolved with postmortem",
P("Dave Wilson <dave@acme.com>","Bob Martinez <bob@acme.com>, Alice Chen <alice@acme.com>","Re: URGENT: Production server down - RESOLVED + Postmortem","<server-resolved-019@test.example.com>","Tue, 11 Feb 2025 16:00:00 +0000",
"Team,\r\n\r\nProduction outage fully resolved. Fix deployed to prod at 14:30 UTC.\r\n\r\nPostmortem:\r\n- Root cause: Connection leak in nightly analytics batch job (PR #831, deployed Fri Feb 7)\r\n- Impact: 45 minutes full outage, ~12 min degraded\r\n- Fix: Connection cleanup in finally block (PR #847)\r\n- Prevention: Connection pool monitoring alert at 80% capacity\r\n\r\nFull doc: https://wiki.acme.com/postmortem/2025-02-11\r\n\r\nDave",
cc="Ops Team <ops@acme.com>",irt="<server-reply2-018@test.example.com>",ref="<server-down-004@test.example.com> <server-reply1-017@test.example.com> <server-reply2-018@test.example.com>")))

# 020 - Falcon QA status
emails.append(E("falcon-qa","<falcon-qa-020@test.example.com>","Tony: Falcon QA status, 2 tests blocked on API keys",
P("Tony Russo <tony@acme.com>","Alice Chen <alice@acme.com>, Bob Martinez <bob@acme.com>","Falcon QA status report - Week of Feb 10","<falcon-qa-020@test.example.com>","Fri, 14 Feb 2025 10:00:00 +0000",
"Hi Alice, Bob,\r\n\r\nQA status for Project Falcon:\r\n\r\nCompleted:\r\n- User auth flow (32/32 passing)\r\n- Payment processing (28/30 — 2 blocked on API keys)\r\n- Dashboard analytics (all green)\r\n\r\nBlocked:\r\n- Payment gateway integration tests (waiting for API keys)\r\n- Load testing (staging had issues earlier this week)\r\n\r\nRisk: If API keys not received by March 5, we won't hit March 12 QA deadline.\r\n\r\nTony")))

# 021 - Falcon staging issue
emails.append(E("falcon-staging","<falcon-staging-021@test.example.com>","Bob reports staging DB migration failure",
P("Bob Martinez <bob@acme.com>","Alice Chen <alice@acme.com>","Falcon staging - database migration issue","<falcon-staging-021@test.example.com>","Wed, 12 Feb 2025 14:00:00 +0000",
"Alice,\r\n\r\nFalcon staging has a database migration issue. The v3.2 schema migration failed halfway, leaving the orders table inconsistent.\r\n\r\nAsked Dave to look into it. This blocks integration tests.\r\n\r\nDave — check if the migration script needs rollback? Error log shows foreign key constraint violation on payments table.\r\n\r\nBob",
cc="Dave Wilson <dave@acme.com>")))

# 022 - Falcon staging fix
emails.append(E("falcon-staging-fix","<falcon-staging-fix-022@test.example.com>","Dave fixes staging migration",
P("Dave Wilson <dave@acme.com>","Bob Martinez <bob@acme.com>, Alice Chen <alice@acme.com>","Re: Falcon staging - database migration issue","<falcon-staging-fix-022@test.example.com>","Thu, 13 Feb 2025 09:00:00 +0000",
"Fixed. Migration script was adding a foreign key before the referenced column existed. Reordered the steps.\r\n\r\nStaging back up, all migrations applied. Good to resume integration testing.\r\n\r\nDave",
irt="<falcon-staging-021@test.example.com>",ref="<falcon-staging-021@test.example.com>")))

# 023 - Security scan (PDF attachment)
emails.append(E("security-scan","<security-scan-023@test.example.com>","Henry: Q1 security scan, 1 critical CVE (PDF)",
A("Henry Liu <henry@acme.com>","Bob Martinez <bob@acme.com>","Q1 Security scan results","<security-scan-023@test.example.com>","Mon, 10 Feb 2025 14:00:00 +0000",
"Bob,\r\n\r\nAttached is the Q1 security scan report. Summary:\r\n\r\n- Critical: 1 (CVE-2025-1234 in log4j)\r\n- High: 3 (outdated TLS, weak password policy, exposed debug endpoint)\r\n- Medium: 7\r\n- Low: 12\r\n\r\nCritical CVE must be patched within 48 hours per policy.\r\n\r\nHenry",
"Q1-Security-Scan-2025.pdf","application/pdf")))

# 024 - CVE alert
emails.append(E("cve-alert","<cve-alert-024@test.example.com>","Henry: critical CVE-2025-1234 in log4j, 48h to patch",
P("Henry Liu <henry@acme.com>","Bob Martinez <bob@acme.com>","CRITICAL: CVE-2025-1234 in log4j - patch within 48h","<cve-alert-024@test.example.com>","Mon, 10 Feb 2025 15:30:00 +0000",
"Bob, Dave,\r\n\r\nCVE-2025-1234: Remote code execution in log4j 2.17.0\r\nAffected: order-processing-service (production)\r\nSeverity: CVSS 9.8\r\nFix: Upgrade to log4j 2.17.1\r\n\r\nMust be patched by Wed Feb 12 EOD. Otherwise add WAF rules to block exploit vector.\r\n\r\nHenry\r\nSecurity Team",
cc="Dave Wilson <dave@acme.com>")))

# 025 - CVE patched
emails.append(E("cve-patched","<cve-patched-025@test.example.com>","Bob confirms CVE patched, deployed to prod",
P("Bob Martinez <bob@acme.com>","Henry Liu <henry@acme.com>","Re: CRITICAL: CVE-2025-1234 in log4j - patch within 48h","<cve-patched-025@test.example.com>","Tue, 11 Feb 2025 11:00:00 +0000",
"Henry,\r\n\r\nPatched and deployed to production at 10:45 UTC. order-processing-service now on log4j 2.17.1.\r\n\r\nScanned other services — no other vulnerable instances.\r\nDave updating WAF rules as precaution.\r\n\r\nBob",
cc="Dave Wilson <dave@acme.com>",irt="<cve-alert-024@test.example.com>",ref="<cve-alert-024@test.example.com>")))

# 026 - Customer escalation
emails.append(E("escalation","<escalation-026@test.example.com>","Raj: BigCorp ($500K ARR) API timeouts, CTO threatening CEO escalation",
P("Raj Gupta <raj@acme.com>","Bob Martinez <bob@acme.com>","ESCALATION: BigCorp account - API timeout issues","<escalation-026@test.example.com>","Wed, 12 Feb 2025 10:00:00 +0000",
"Bob,\r\n\r\nBigCorp ($500K ARR, our largest enterprise customer) reporting intermittent API timeouts since Monday.\r\n\r\nCTO Sam Chen threatens CEO escalation if not resolved by Friday.\r\n\r\nAffected: POST /api/v2/orders\r\n~15% of requests timing out\r\nImpact: $20K/day in failed transactions\r\n\r\nCan you investigate urgently?\r\n\r\nRaj\r\nCustomer Success")))

# 027 - Escalation reply
emails.append(E("escalation-reply","<escalation-reply-027@test.example.com>","Bob: BigCorp timeouts related to batch job fix",
P("Bob Martinez <bob@acme.com>","Raj Gupta <raj@acme.com>","Re: ESCALATION: BigCorp account - API timeout issues","<escalation-reply-027@test.example.com>","Wed, 12 Feb 2025 14:30:00 +0000",
"Raj,\r\n\r\nIdentified the issue. Timeouts correlate with the nightly batch job — same one that caused Tuesday's outage. It consumed too many DB connections, causing contention.\r\n\r\nConnection leak fix from yesterday should resolve this. Ask BigCorp to monitor for 24 hours.\r\n\r\nIf still seeing issues, I'll set up a dedicated connection pool for their traffic.\r\n\r\nBob",
irt="<escalation-026@test.example.com>",ref="<escalation-026@test.example.com>")))

# 028 - Escalation resolved
emails.append(E("escalation-resolved","<escalation-resolved-028@test.example.com>","BigCorp resolved, dedicated pool added",
P("Bob Martinez <bob@acme.com>","Raj Gupta <raj@acme.com>","Re: ESCALATION: BigCorp - RESOLVED","<escalation-resolved-028@test.example.com>","Fri, 14 Feb 2025 09:00:00 +0000",
"Raj,\r\n\r\nBigCorp timeouts fully resolved. Success rate back to 99.97% over last 48h.\r\n\r\nRoot cause: same connection leak as Tuesday's outage. Added dedicated connection pool and rate limit for BigCorp.\r\n\r\nAlice, FYI in case Sam raises this at quarterly review.\r\n\r\nBob",
cc="Alice Chen <alice@acme.com>",irt="<escalation-reply-027@test.example.com>",ref="<escalation-026@test.example.com> <escalation-reply-027@test.example.com>")))

# 029 - BigCorp thanks
emails.append(E("bigcorp-thanks","<bigcorp-thanks-029@test.example.com>","Sam Chen (BigCorp CTO) thanks Bob",
P("Sam Chen <sam@bigcorp.com>","Bob Martinez <bob@acme.com>","Re: ESCALATION: BigCorp - RESOLVED","<bigcorp-thanks-029@test.example.com>","Fri, 14 Feb 2025 11:00:00 +0000",
"Bob,\r\n\r\nThank you for the quick turnaround. Issues confirmed resolved on our end.\r\n\r\nThe dedicated connection pool gives us more confidence. Looking forward to discussing API v3 migration next month.\r\n\r\nBest,\r\nSam Chen\r\nCTO, BigCorp",
cc="Raj Gupta <raj@acme.com>",irt="<escalation-resolved-028@test.example.com>",ref="<escalation-026@test.example.com> <escalation-reply-027@test.example.com> <escalation-resolved-028@test.example.com>")))

# 030 - Design mockups (PDF)
emails.append(E("design-mockups","<design-mockups-030@test.example.com>","Patricia: Falcon UI mockups for review (PDF)",
A("Patricia Owens <patricia@acme.com>","Bob Martinez <bob@acme.com>","Falcon UI mockups for review","<design-mockups-030@test.example.com>","Mon, 10 Feb 2025 09:00:00 +0000",
"Hi Bob,\r\n\r\nAttached are the Falcon customer dashboard mockups:\r\n1. Order tracking (real-time status)\r\n2. Payment history\r\n3. Analytics dashboard (order volume, revenue)\r\n4. Settings (API key mgmt, webhooks)\r\n\r\nPlease review and send feedback by Wednesday.\r\n\r\nPatricia",
"Falcon-UI-Mockups-v1.pdf","application/pdf",cc="Alice Chen <alice@acme.com>")))

# 031 - Design feedback
emails.append(E("design-feedback","<design-feedback-031@test.example.com>","Bob: design feedback on mockups",
P("Bob Martinez <bob@acme.com>","Patricia Owens <patricia@acme.com>","Re: Falcon UI mockups for review","<design-feedback-031@test.example.com>","Wed, 12 Feb 2025 16:00:00 +0000",
"Patricia,\r\n\r\nGreat work. Feedback:\r\n1. Order tracking: Add estimated delivery time\r\n2. Payment history: Need CSV export\r\n3. Analytics: Chart colors need better contrast (WCAG AA)\r\n4. Settings: Add regenerate-key confirmation dialog\r\n\r\nOverall direction is solid.\r\n\r\nBob",
cc="Alice Chen <alice@acme.com>",irt="<design-mockups-030@test.example.com>",ref="<design-mockups-030@test.example.com>")))

# 032 - Design revised (PDF)
emails.append(E("design-revised","<design-revised-032@test.example.com>","Patricia: revised mockups, all feedback incorporated (PDF)",
A("Patricia Owens <patricia@acme.com>","Bob Martinez <bob@acme.com>","Re: Falcon UI mockups - Revised","<design-revised-032@test.example.com>","Fri, 14 Feb 2025 14:00:00 +0000",
"Bob,\r\n\r\nRevised mockups attached:\r\n1. Added estimated delivery time\r\n2. Added CSV export to payment history\r\n3. Chart colors meet WCAG AA\r\n4. Confirmation dialog for key regeneration\r\n\r\nAll feedback incorporated. Ready for sign-off.\r\n\r\nPatricia",
"Falcon-UI-Mockups-v2-final.pdf","application/pdf",cc="Alice Chen <alice@acme.com>",
irt="<design-feedback-031@test.example.com>",ref="<design-mockups-030@test.example.com> <design-feedback-031@test.example.com>")))

# 033 - Marketing plan
emails.append(E("marketing-plan","<marketing-plan-033@test.example.com>","Grace: Falcon marketing campaign plan, $25K budget",
P("Grace Kim <grace@acme.com>","Alice Chen <alice@acme.com>, Bob Martinez <bob@acme.com>","Falcon marketing campaign - launch plan","<marketing-plan-033@test.example.com>","Wed, 12 Feb 2025 11:00:00 +0000",
"Hi Alice, Bob,\r\n\r\nFalcon launch marketing plan:\r\n\r\nPhase 1 (Mar 3-10): Teaser — social media, blog, email blast\r\nPhase 2 (Mar 10-17): Pre-launch — webinar, press releases, partners\r\nPhase 3 (Mar 17): Launch day — Product Hunt, demo video, email blast\r\nPhase 4 (Mar 17-31): Post-launch — case studies, testimonials, paid ads\r\n\r\nBudget: $25,000 ($8K ads, $7K content, $5K events, $5K tools)\r\n\r\nThis is why we requested the 2-day delay — March 17 aligns with webinar.\r\n\r\nGrace")))

# 034 - Marketing metrics (CSV attachment)
emails.append(E("marketing-metrics","<marketing-metrics-034@test.example.com>","Grace: teaser campaign metrics (CSV)",
A("Grace Kim <grace@acme.com>","Bob Martinez <bob@acme.com>","Falcon pre-launch campaign metrics","<marketing-metrics-034@test.example.com>","Fri, 14 Feb 2025 16:00:00 +0000",
"Bob,\r\n\r\nEarly teaser results:\r\n- Blog views: 4,200 (2x average)\r\n- Email open rate: 34% (industry avg 21%)\r\n- Webinar registrations: 180 (target 300)\r\n- Social impressions: 28K\r\n\r\nFull breakdown attached.\r\n\r\nGrace",
"falcon-campaign-metrics.csv","text/csv")))

# 035 - Conference invite
emails.append(E("conference-invite","<conference-035@test.example.com>","Irene nominates Bob for DevOps Summit",
P("Irene Novak <irene@acme.com>","Bob Martinez <bob@acme.com>","DevOps Summit 2025 - nomination to attend","<conference-035@test.example.com>","Thu, 06 Feb 2025 11:00:00 +0000",
"Bob,\r\n\r\nNominating you for DevOps Summit 2025 in San Francisco, March 20-22.\r\n\r\n- Keynote by CTO of Kubernetes\r\n- Workshops on GitOps and observability\r\n- Networking with engineering leads\r\n\r\nRegistration: $1,500 | Travel+hotel: ~$2,000\r\n\r\nConfirm by Feb 14 so I can get budget approval.\r\n\r\nIrene\r\nVP Engineering")))

# 036 - Travel approved
emails.append(E("travel-approved","<travel-approved-036@test.example.com>","Irene: DevOps Summit travel approved, $3800 budget",
P("Irene Novak <irene@acme.com>","Bob Martinez <bob@acme.com>","Re: DevOps Summit 2025 - travel approved","<travel-approved-036@test.example.com>","Fri, 14 Feb 2025 08:00:00 +0000",
"Bob,\r\n\r\nTravel approved:\r\n- DevOps Summit, March 20-22, Moscone Center SF\r\n- Budget: $3,800\r\n- Flight: Book via Concur, economy\r\n- Hotel: Marriott Union Square ($250/night corporate rate)\r\n\r\nSubmit travel request in Concur by Feb 21.\r\n\r\nIrene",
irt="<conference-035@test.example.com>",ref="<conference-035@test.example.com>")))

# 037 - Conference summary
emails.append(E("conference-summary","<conference-summary-037@test.example.com>","Bob shares DevOps Summit takeaways",
P("Bob Martinez <bob@acme.com>","Engineering Team <engineering@acme.com>","DevOps Summit 2025 - key takeaways","<conference-summary-037@test.example.com>","Mon, 24 Mar 2025 09:00:00 +0000",
"Team,\r\n\r\nDevOps Summit takeaways:\r\n\r\n1. GitOps accelerating — ArgoCD + Flux dominant\r\n2. OpenTelemetry is the observability standard (migrate from Datadog agents)\r\n3. Platform engineering teams reduce onboarding 40%\r\n4. AI-assisted incident response emerging (PagerDuty AI looks promising)\r\n\r\nDetailed summary at next all-hands.\r\n\r\nBob")))

# 038 - Lisa PR review
emails.append(E("pr-review","<pr-review-038@test.example.com>","Lisa submits first PR for order validation refactor",
P("Lisa Wong <lisa@acme.com>","Bob Martinez <bob@acme.com>","PR review request: Falcon order validation refactor","<pr-review-038@test.example.com>","Thu, 13 Feb 2025 14:00:00 +0000",
"Hi Bob,\r\n\r\nSubmitted PR #852 for the order validation refactor:\r\n- Extracted validation into OrderValidator class\r\n- Added unit tests (empty orders, negative quantities, currency mismatches)\r\n- Fixed bug: 0-quantity items were silently accepted\r\n\r\nFirst PR here — let me know if I'm missing conventions.\r\nhttps://github.acme.com/falcon/backend/pull/852\r\n\r\nThanks,\r\nLisa")))

# 039 - PR feedback
emails.append(E("pr-feedback","<pr-feedback-039@test.example.com>","Bob: code review feedback on Lisa's PR",
P("Bob Martinez <bob@acme.com>","Lisa Wong <lisa@acme.com>","Re: PR review request: Falcon order validation refactor","<pr-feedback-039@test.example.com>","Thu, 13 Feb 2025 17:30:00 +0000",
"Lisa,\r\n\r\nNice work! Comments:\r\n1. Make validation rules configurable for product-specific rules later\r\n2. Add test for quantities > 10,000 (business rule cap)\r\n3. Use snake_case for methods, not camelCase — see wiki.acme.com/code-style\r\n\r\nMinor changes only — LGTM. Approved with suggestions.\r\n\r\nBob",
irt="<pr-review-038@test.example.com>",ref="<pr-review-038@test.example.com>")))

# 040 - Lisa first week questions
emails.append(E("lisa-questions","<lisa-questions-040@test.example.com>","Lisa asks about IDE, staging access, design docs",
P("Lisa Wong <lisa@acme.com>","Bob Martinez <bob@acme.com>","First week questions","<lisa-questions-040@test.example.com>","Tue, 11 Feb 2025 09:00:00 +0000",
"Hi Bob,\r\n\r\nThanks for the warm welcome! Questions:\r\n1. Recommended IDE for Falcon backend? Using VS Code, saw some on IntelliJ.\r\n2. How to get staging DB access? Dev works but staging needs VPN config.\r\n3. Design doc for Falcon payment processing flow?\r\n4. Who handles the on-call rotation schedule?\r\n\r\nExcited to be on the team!\r\n\r\nLisa")))

# 041 - Lisa access issue
emails.append(E("lisa-access","<lisa-access-041@test.example.com>","Lisa can't clone falcon-backend repo, needs permissions",
P("Lisa Wong <lisa@acme.com>","Bob Martinez <bob@acme.com>","Can't access falcon-backend repo","<lisa-access-041@test.example.com>","Mon, 10 Feb 2025 15:00:00 +0000",
"Bob,\r\n\r\nGetting 403 trying to clone falcon-backend. Username: lwong.\r\n\r\nError: Permission to acme/falcon-backend.git denied to lwong.\r\n\r\nNeed to be added to falcon-dev team. Submitted access request in IT portal this morning.\r\n\r\nThanks,\r\nLisa",
cc="IT Support <it@acme.com>")))

# 042 - JIRA ticket
emails.append(E("jira-ticket","<jira-342-042@test.example.com>","JIRA: FALCON-342 payment timeout bug assigned to Bob",
P("JIRA <noreply@jira.acme.com>","Bob Martinez <bob@acme.com>","[FALCON-342] Payment timeout on orders > $10,000 assigned to you","<jira-342-042@test.example.com>","Wed, 12 Feb 2025 08:00:00 +0000",
"FALCON-342: Payment timeout on orders > $10,000\r\n\r\nType: Bug | Priority: High\r\nAssignee: Bob Martinez | Reporter: Tony Russo\r\nSprint: Falcon Sprint 12\r\n\r\nOrders >$10K timeout during payment. Gateway returns timeout after 30s.\r\n\r\nSteps: 1) Create order >$10K 2) Submit payment 3) Timeout after 30s\r\n\r\nDo not reply to this email.")))

# 043 - CI build failed
emails.append(E("ci-failed","<ci-failed-043@test.example.com>","CI: falcon-backend build #1847 failed, 2 tests",
P("CI System <ci-notify@acme.com>","Bob Martinez <bob@acme.com>","[FAILED] falcon-backend #1847 - main branch","<ci-failed-043@test.example.com>","Thu, 13 Feb 2025 06:15:00 +0000",
"Build #1847 FAILED for falcon-backend (main)\r\n\r\nCommit: a3f7b2d \"Fix connection pool cleanup\"\r\nAuthor: Dave Wilson | Duration: 4m 32s\r\n\r\nFailed: test_payment_gateway_integration (timeout), test_order_processing_large_batch (assertion)\r\n2 failed, 847 passed, 3 skipped\r\n\r\nhttps://ci.acme.com/falcon-backend/1847\r\n\r\nAutomated notification.")))

# 044 - Monitoring alert
emails.append(E("monitoring-alert","<monitoring-disk-044@test.example.com>","Monitoring: prod-db-01 disk at 85%, 7 days to full",
P("Monitoring <monitoring@acme.com>","Bob Martinez <bob@acme.com>","[ALERT] Disk space warning - prod-db-01 at 85%","<monitoring-disk-044@test.example.com>","Wed, 12 Feb 2025 22:00:00 +0000",
"ALERT: Disk space warning\r\n\r\nHost: prod-db-01.acme.internal\r\nMetric: disk_usage_percent | Current: 85% | Threshold: 80%\r\nPartition: /data/postgres\r\n\r\nGrowing ~2%/day. Est. full in ~7 days.\r\n\r\nAction: Archive old transaction logs or expand volume.\r\n\r\nAutomated alert.",
cc="Dave Wilson <dave@acme.com>")))

# 045 - Performance review
emails.append(E("perf-review","<perf-review-045@test.example.com>","Irene: Bob's FY2024 performance review, Exceeds Expectations",
P("Irene Novak <irene@acme.com>","Bob Martinez <bob@acme.com>","Annual performance review summary - FY2024","<perf-review-045@test.example.com>","Fri, 07 Feb 2025 17:00:00 +0000",
"Bob,\r\n\r\nFY2024 review summary:\r\n\r\nRating: Exceeds Expectations (4/5)\r\n\r\nStrengths: Technical leadership on Falcon, incident response (Q3 DB migration crisis), mentoring junior engineers.\r\n\r\nGrowth areas: Delegate more, improve team runbook documentation.\r\n\r\nCompensation: 8% salary increase (March 1). Stock refresh: 500 RSUs over 4 years.\r\n\r\nLet's discuss in our next 1:1.\r\n\r\nIrene")))

# 046 - 1:1 agenda
emails.append(E("one-on-one","<one-on-one-046@test.example.com>","Alice: 1:1 agenda covering Falcon, Lisa, incident, travel",
P("Alice Chen <alice@acme.com>","Bob Martinez <bob@acme.com>","1:1 agenda - Feb 14","<one-on-one-046@test.example.com>","Thu, 13 Feb 2025 08:00:00 +0000",
"Bob,\r\n\r\nTopics for tomorrow's 1:1:\r\n1. Falcon timeline (March 17 launch)\r\n2. Lisa Wong onboarding — how's her first week?\r\n3. Production incident postmortem follow-up\r\n4. API keys status from vendor?\r\n5. DevOps Summit travel\r\n6. Sprint 13 capacity\r\n\r\nAnything to add?\r\n\r\nAlice")))

# 047 - Revised budget (xlsx attachment)
emails.append(E("revised-budget","<revised-budget-047@test.example.com>","Eve: revised Q1 engineering budget $420K (xlsx)",
A("Eve Park <eve@acme.com>","Bob Martinez <bob@acme.com>","Revised Q1 budget allocation - engineering","<revised-budget-047@test.example.com>","Fri, 14 Feb 2025 12:00:00 +0000",
"Bob,\r\n\r\nRevised Q1 engineering allocations:\r\n- Infrastructure: $180,000 (up from $150K, cloud overruns)\r\n- Headcount: 2 new (1 senior backend, 1 SRE)\r\n- Training: $15,000\r\n- Tools: $45,000\r\nTotal: $420,000\r\n\r\nSee attached. Sign off by Feb 21.\r\n\r\nEve",
"Q1-Engineering-Budget-Revised.xlsx","application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
cc="Carol Davis <carol@acme.com>")))

# 048 - Expense report deadline
emails.append(E("expense-deadline","<expense-deadline-048@test.example.com>","Eve: 3 outstanding expense receipts due Feb 21",
P("Eve Park <eve@acme.com>","Bob Martinez <bob@acme.com>","Reminder: expense reports due Feb 21","<expense-deadline-048@test.example.com>","Mon, 17 Feb 2025 09:00:00 +0000",
"Bob,\r\n\r\nQ4 2024 expense reports due February 21.\r\n\r\nOutstanding in Concur:\r\n1. AWS training ($450) - Dec 12\r\n2. Team dinner ($380) - Dec 18\r\n3. JetBrains license ($249) - Jan 5\r\n\r\nPlease submit ASAP.\r\n\r\nEve\r\nFinance")))

# 049 - Compliance training
emails.append(E("compliance-training","<compliance-training-049@test.example.com>","Nora: 4 mandatory training modules due March 1",
P("Nora Patel <nora@acme.com>","Bob Martinez <bob@acme.com>","Mandatory compliance training - due March 1","<compliance-training-049@test.example.com>","Mon, 10 Feb 2025 10:00:00 +0000",
"Bob,\r\n\r\nOutstanding compliance training:\r\n1. Data Privacy & GDPR (45 min)\r\n2. Information Security Awareness (30 min)\r\n3. Anti-Harassment Policy (20 min)\r\n4. Code of Conduct Refresher (15 min)\r\n\r\nDue by March 1, 2025. Portal: https://training.acme.com\r\n\r\nNora\r\nCompliance")))

# 050 - NDA review
emails.append(E("nda-review","<nda-review-050@test.example.com>","Legal: review NDA amendment for CloudStore contract",
P("Legal Department <legal@acme.com>","Bob Martinez <bob@acme.com>","NDA review required - CloudStore contract amendment","<nda-review-050@test.example.com>","Thu, 13 Feb 2025 10:00:00 +0000",
"Bob,\r\n\r\nCloudStore contract renegotiation requires NDA amendment:\r\n- Extended confidentiality: 2 years to 5 years\r\n- Added AI/ML training data exclusion clause\r\n- Changed to mutual NDA (was one-way)\r\n\r\nPlease confirm the AI/ML exclusion is acceptable from engineering. Sign-off by Feb 18.\r\n\r\nLegal Department",
cc="Heidi Tanaka <heidi@acme.com>")))

# 051 - Casual lunch
emails.append(E("lunch","<lunch-051@test.example.com>","Dave asks Bob to lunch, casual",
P("Dave Wilson <dave@acme.com>","Bob Martinez <bob@acme.com>","Lunch today?","<lunch-051@test.example.com>","Wed, 12 Feb 2025 11:30:00 +0000",
"Bob,\r\n\r\nWant to grab lunch at that new Thai place on 3rd? Pad see ew is amazing apparently.\r\n\r\n12:30 work?\r\n\r\nDave")))

# 052 - Alice OOO
emails.append(E("alice-ooo","<alice-ooo-052@test.example.com>","Alice OOO Feb 17-21, Bob is Falcon point of contact",
P("Alice Chen <alice@acme.com>","Engineering Team <engineering@acme.com>","Out of office Feb 17-21","<alice-ooo-052@test.example.com>","Fri, 14 Feb 2025 17:00:00 +0000",
"Team,\r\n\r\nOOO February 17-21 (family vacation).\r\n\r\nDuring my absence:\r\n- Falcon: Bob Martinez\r\n- Budget: Carol Davis\r\n- Urgent: Text my cell\r\n\r\nLimited email, will respond to critical items within 24h.\r\n\r\nAlice")))

# 053 - Meeting rescheduled
emails.append(E("meeting-reschedule","<meeting-reschedule-053@test.example.com>","Carol: budget review rescheduled to Feb 24 (Alice OOO)",
P("Carol Davis <carol@acme.com>","Bob Martinez <bob@acme.com>","Q1 budget review - rescheduled to Feb 24","<meeting-reschedule-053@test.example.com>","Wed, 19 Feb 2025 09:00:00 +0000",
"Bob,\r\n\r\nQ1 budget review rescheduled from Feb 20 to Feb 24 (Monday) 2pm, Conference Room B.\r\n\r\nAlice is OOO this week and we need her input on Falcon budget.\r\n\r\nSame agenda. Bring updated expense reports.\r\n\r\nCarol",
irt="<budget-meeting-003@test.example.com>",ref="<budget-meeting-003@test.example.com>")))

# 054 - Forwarded article
emails.append(E("fwd-article","<fwd-article-054@test.example.com>","Mark forwards AI in DevOps article",
P("Mark Johnson <mark@acme.com>","Bob Martinez <bob@acme.com>","Fwd: Interesting article on AI in DevOps","<fwd-article-054@test.example.com>","Tue, 11 Feb 2025 14:00:00 +0000",
"Bob,\r\n\r\nThought you'd find this interesting given your DevOps Summit trip:\r\n\r\n---------- Forwarded message ----------\r\nFrom: TechDigest <newsletter@techdigest.com>\r\nSubject: How AI is Transforming DevOps in 2025\r\n\r\nKey trends:\r\n1. AIOps for automated incident detection\r\n2. AI code review reducing review time 60%\r\n3. Predictive scaling via ML\r\n4. NL infrastructure-as-code generation\r\n\r\nhttps://techdigest.com/ai-devops-2025\r\n\r\n-- Mark")))

# 055 - Benefits enrollment
emails.append(E("benefits-enrollment","<benefits-055@test.example.com>","HR: benefits open enrollment closes Feb 28",
P("HR Department <hr@acme.com>","Bob Martinez <bob@acme.com>","Open enrollment deadline - Feb 28","<benefits-055@test.example.com>","Mon, 17 Feb 2025 08:00:00 +0000",
"Dear Bob,\r\n\r\nOpen enrollment for 2025 benefits closes February 28.\r\n\r\nChanges:\r\n- New dental plan (Delta Dental Premium)\r\n- 401(k) match increased from 4% to 5%\r\n- New $500/year wellness stipend\r\n\r\nCurrent elections roll over if no changes made.\r\n\r\nhttps://benefits.acme.com\r\n\r\nHR Department")))

# 056 - DB migration plan (PDF attachment)
emails.append(E("db-migration","<db-migration-056@test.example.com>","Dave: PostgreSQL 16 upgrade plan with runbook (PDF)",
A("Dave Wilson <dave@acme.com>","Bob Martinez <bob@acme.com>, Alice Chen <alice@acme.com>","Falcon DB migration plan - PostgreSQL 16 upgrade","<db-migration-056@test.example.com>","Mon, 10 Feb 2025 16:00:00 +0000",
"Bob, Alice,\r\n\r\nProposing PG14 to PG16 upgrade before Falcon launch:\r\n- 2x bulk INSERT performance\r\n- Better parallel queries\r\n- JSON path queries for order metadata\r\n\r\nTimeline:\r\n- Feb 17-21: Test on staging\r\n- Feb 24-25: Dry run on prod replica\r\n- Mar 1 (Sat 2am): Production (est 4h downtime)\r\n\r\nRunbook attached.\r\n\r\nDave",
"PG16-Migration-Runbook.pdf","application/pdf")))

write_json("corpus.json", {"_meta":"Synthetic email corpus for ThunderRAG quality testing.","emails":emails})
