#!/usr/bin/env python3
"""Generate expanded test_cases.json (25 conversations, up to 10 rounds)."""
from gen_helpers import TC, write_json

C = []

# ── 1-5: Factual (single-round) ──────────────────────────────────────────
C.append(TC("factual_01","factual","When is the Project Falcon launch date?",
    mc=["March 15","March 17"],es=["Project Falcon launch date","Updated Falcon timeline"]))
C.append(TC("factual_02","factual","Who scheduled the Q1 budget review meeting and when is it?",
    mc=["Carol","February 20","Feb 20","February 24","Feb 24"],es=["Q1 budget review"]))
C.append(TC("factual_03","factual","What are the key highlights from the Q1 financial report?",
    mc=["2.4M","$2.4M","2.4 million","revenue","25%"],es=["Q1 financial report"]))
C.append(TC("factual_04","factual","What is the CloudStore contract renewal price and what was recommended?",
    mc=["$40,000","40,000","40K","negotiate","Grace"],es=["Vendor contract renewal"]))
C.append(TC("factual_05","factual","What critical security vulnerability was found and has it been patched?",
    mc=["CVE-2025-1234","log4j","patched"],es=["CVE-2025-1234","Security scan"]))

# ── 6-7: Triage (single-round) ───────────────────────────────────────────
C.append(TC("triage_01","triage","Are there any urgent emails that need immediate attention?",
    mc=["server","down","production","CVE","ESCALATION","BigCorp"],
    es=["URGENT","Production server down","ESCALATION","CRITICAL"]))
C.append(TC("triage_02","triage","What action items and deadlines do I have in the next two weeks?",
    mc=["February 28","Feb 28","Feb 21","March 1","compliance","expense","benefits"],
    es=["Compliance audit","expense reports","Open enrollment"]))

# ── 8-10: Thread: Server incident (3 rounds) ────────────────────────────
g="session_thread_incident"
C.append(TC("thread_incident_01","thread","Walk me through the production server incident. What happened?",
    grp=g,mc=["connection","leak","batch job","503"],es=["Production server down"]))
C.append(TC("thread_incident_02","thread","How was it fixed and what was the impact?",
    grp=g,dep="thread_incident_01",mc=["finally block","PR #847","45 minutes","postmortem"],
    es=["Production server down"]))
C.append(TC("thread_incident_03","thread","Were there any customer-facing consequences?",
    grp=g,dep="thread_incident_02",mc=["BigCorp","timeout","resolved"],
    es=["ESCALATION","BigCorp"]))

# ── 11-13: Thread: Vendor negotiation (3 rounds) ────────────────────────
g="session_thread_vendor"
C.append(TC("thread_vendor_01","thread","Summarize the CloudStore vendor contract negotiation thread.",
    grp=g,mc=["$45,000","$40,000","Grace","DataVault"],es=["Vendor contract renewal"]))
C.append(TC("thread_vendor_02","thread","What was Grace's analysis comparing CloudStore and DataVault?",
    grp=g,dep="thread_vendor_01",mc=["99.9%","99.5%","migration risk","$35,000"],
    es=["Vendor contract renewal"]))
C.append(TC("thread_vendor_03","thread","Is there anything else related to the CloudStore deal I should know about?",
    grp=g,dep="thread_vendor_02",mc=["NDA","legal","AI/ML","5 years"],
    es=["NDA review","Vendor contract renewal"]))

# ── 14-15: Broad (2 rounds) ─────────────────────────────────────────────
g="session_broad_mark"
C.append(TC("broad_mark_01","broad","What topics has Mark Johnson emailed me about?",
    grp=g,mc=["Lisa Wong","new hire","renovation","Building 3","offsite","April","AI","DevOps"],
    es=["New hire","Office renovation","Company offsite","Fwd:"]))
C.append(TC("broad_mark_02","broad","Tell me more about the new hire he mentioned.",
    grp=g,dep="broad_mark_01",mc=["Lisa Wong","Monday","Feb 10","backend"],es=["New hire"]))

# ── 16-17: Temporal ──────────────────────────────────────────────────────
C.append(TC("temporal_01","temporal","What is the most recent email I got from Alice?",
    mc=["March 17","Updated Falcon timeline","2-day delay","marketing","Out of office"],
    es=["Updated Falcon timeline","Out of office"]))
C.append(TC("temporal_02","temporal","What deadlines do I have in the next two weeks?",
    mc=["February 28","Feb 28","Feb 21","March 1","compliance","expense","benefits"],
    es=["Compliance audit","expense reports","Open enrollment"]))

# ── 18-19: Attachment-focused ────────────────────────────────────────────
C.append(TC("attachment_01","attachment","What reports and documents have been sent to me as attachments?",
    mc=["Q1","financial","security scan","budget","mockup","migration"],
    es=["Q1 financial report","Security scan","budget","mockups","Migration"]))
C.append(TC("attachment_02","attachment","What did the security scan report find?",
    mc=["critical","CVE","log4j","High","Medium"],es=["Security scan"]))

# ── 20-21: Negative ─────────────────────────────────────────────────────
C.append(TC("negative_01","negative","Has anyone emailed me about the Mars colonization project?",
    mc=["no ","not ","don't","doesn't","no relevant","no emails","couldn't find"],
    cite=False,hk=["Mars colonization","Mars project"]))
C.append(TC("negative_02","negative","What is the CEO's salary?",
    mc=["no ","not ","don't","doesn't","no information","no emails","couldn't find"],
    cite=False,hk=["CEO salary"]))

# ── 22: Multi-turn: Falcon deep dive (8 rounds) ─────────────────────────
g="session_mt_falcon"
C.append(TC("mt_falcon_01","multi_turn","Tell me everything about Project Falcon.",
    grp=g,mc=["launch","March","Alice"],es=["Falcon"]))
C.append(TC("mt_falcon_02","multi_turn","What's the current launch date and why did it change?",
    grp=g,dep="mt_falcon_01",mc=["March 17","marketing","2-day delay"],
    es=["Updated Falcon timeline"]))
C.append(TC("mt_falcon_03","multi_turn","What's the status of QA testing?",
    grp=g,dep="mt_falcon_02",mc=["Tony","32/32","blocked","API keys"],
    es=["Falcon QA status"]))
C.append(TC("mt_falcon_04","multi_turn","Were there any staging environment issues?",
    grp=g,dep="mt_falcon_03",mc=["migration","foreign key","Dave","fixed"],
    es=["staging"]))
C.append(TC("mt_falcon_05","multi_turn","What about the UI design — is that on track?",
    grp=g,dep="mt_falcon_04",mc=["Patricia","mockups","WCAG","revised"],
    es=["Falcon UI mockups"]))
C.append(TC("mt_falcon_06","multi_turn","What's the marketing plan for the launch?",
    grp=g,dep="mt_falcon_05",mc=["Grace","Phase","$25,000","webinar"],
    es=["marketing campaign"]))
C.append(TC("mt_falcon_07","multi_turn","Are there any open bugs I should know about?",
    grp=g,dep="mt_falcon_06",mc=["FALCON-342","payment timeout","$10,000"],
    es=["FALCON-342","Payment timeout"]))
C.append(TC("mt_falcon_08","multi_turn","Summarize all the Falcon risks and blockers right now.",
    grp=g,dep="mt_falcon_07",mc=["API keys","blocked"],cite=False))

# ── 23: Multi-turn: Server incident deep dive (7 rounds) ────────────────
g="session_mt_incident"
C.append(TC("mt_incident_01","multi_turn","Tell me about the production server outage.",
    grp=g,mc=["us-east-1","503","3:05 AM"],es=["Production server down"]))
C.append(TC("mt_incident_02","multi_turn","What was the root cause?",
    grp=g,dep="mt_incident_01",mc=["connection leak","batch job","finally block"],
    es=["Production server down"]))
C.append(TC("mt_incident_03","multi_turn","How long was the outage and what was done to fix it?",
    grp=g,dep="mt_incident_02",mc=["45 minutes","PR #847","pool limit"],
    es=["Production server down"]))
C.append(TC("mt_incident_04","multi_turn","Was there a postmortem?",
    grp=g,dep="mt_incident_03",mc=["postmortem","monitoring","80%"],
    es=["RESOLVED","Postmortem"]))
C.append(TC("mt_incident_05","multi_turn","Did any customers complain about this?",
    grp=g,dep="mt_incident_04",mc=["BigCorp","timeout","$500K","Sam Chen"],
    es=["ESCALATION","BigCorp"]))
C.append(TC("mt_incident_06","multi_turn","Is the customer issue resolved now?",
    grp=g,dep="mt_incident_05",mc=["resolved","99.97%","dedicated connection pool"],
    es=["RESOLVED"]))
C.append(TC("mt_incident_07","multi_turn","Were there any other infrastructure warnings related to this?",
    grp=g,dep="mt_incident_06",mc=["disk space","85%","CI","build"],
    es=["Disk space","FAILED"],cite=False))

# ── 24: Multi-turn: Lisa onboarding (5 rounds) ──────────────────────────
g="session_mt_lisa"
C.append(TC("mt_lisa_01","multi_turn","What do you know about Lisa Wong?",
    grp=g,mc=["new hire","backend","Feb 10","Monday"],es=["Lisa Wong","New hire"]))
C.append(TC("mt_lisa_02","multi_turn","Did she have any onboarding issues?",
    grp=g,dep="mt_lisa_01",mc=["403","falcon-backend","access","repo"],
    es=["access","falcon-backend"]))
C.append(TC("mt_lisa_03","multi_turn","What questions did she ask in her first week?",
    grp=g,dep="mt_lisa_02",mc=["IDE","staging","VPN","on-call"],
    es=["First week questions"]))
C.append(TC("mt_lisa_04","multi_turn","Has she submitted any code yet?",
    grp=g,dep="mt_lisa_03",mc=["PR #852","OrderValidator","validation","0-quantity"],
    es=["PR review","order validation"]))
C.append(TC("mt_lisa_05","multi_turn","What feedback did she get on her code?",
    grp=g,dep="mt_lisa_04",mc=["configurable","snake_case","10,000","LGTM"],
    es=["PR review"]))

# ── 25: Multi-turn: Cross-topic conversation (10 rounds) ────────────────
g="session_mt_mixed"
C.append(TC("mt_mixed_01","multi_turn","Give me a high-level overview of what's been happening in my inbox.",
    grp=g,mc=["Falcon","server","outage","BigCorp","budget"],cite=False))
C.append(TC("mt_mixed_02","multi_turn","Let's start with the most urgent items. What needs my attention right now?",
    grp=g,dep="mt_mixed_01",mc=["CVE","ESCALATION","disk space","compliance"],cite=False))
C.append(TC("mt_mixed_03","multi_turn","Tell me about the BigCorp situation specifically.",
    grp=g,dep="mt_mixed_02",mc=["BigCorp","$500K","timeout","Sam Chen"],
    es=["ESCALATION","BigCorp"]))
C.append(TC("mt_mixed_04","multi_turn","OK, switching topics. What's happening with Project Falcon?",
    grp=g,dep="mt_mixed_03",mc=["March 17","launch","QA","marketing"],es=["Falcon"]))
C.append(TC("mt_mixed_05","multi_turn","What about the team — any HR or people updates?",
    grp=g,dep="mt_mixed_04",mc=["Lisa Wong","performance review","offsite"],
    es=["Lisa Wong","performance review","offsite"]))
C.append(TC("mt_mixed_06","multi_turn","How was my performance review?",
    grp=g,dep="mt_mixed_05",mc=["Exceeds Expectations","4/5","8%","RSU","500"],
    es=["performance review"]))
C.append(TC("mt_mixed_07","multi_turn","What financial things do I need to deal with?",
    grp=g,dep="mt_mixed_06",mc=["expense","$420,000","budget","benefits","Feb 21","Feb 28"],
    es=["expense","budget","benefits"]))
C.append(TC("mt_mixed_08","multi_turn","Are there any conferences or travel coming up?",
    grp=g,dep="mt_mixed_07",mc=["DevOps Summit","March 20","San Francisco","$3,800"],
    es=["DevOps Summit"]))
C.append(TC("mt_mixed_09","multi_turn","What did I learn at that conference?",
    grp=g,dep="mt_mixed_08",mc=["GitOps","OpenTelemetry","ArgoCD","platform engineering"],
    es=["DevOps Summit","takeaways"]))
C.append(TC("mt_mixed_10","multi_turn","Finally, is there anything casual or low-priority I should know about?",
    grp=g,dep="mt_mixed_09",mc=["lunch","Thai","holiday","AI","DevOps","article"],
    es=["Lunch","holiday","Fwd:"],cite=False))

# ── 26: Multi-turn: Budget & Finance (6 rounds) ─────────────────────────
g="session_mt_budget"
C.append(TC("mt_budget_01","multi_turn","What's the current state of our Q1 budget?",
    grp=g,mc=["$420,000","infrastructure","headcount"],es=["budget","Q1 financial"]))
C.append(TC("mt_budget_02","multi_turn","How does the revised budget compare to the original Q1 report?",
    grp=g,dep="mt_budget_01",mc=["$2.4M","revenue","$180,000","$150,000"],
    es=["Q1 financial","budget"]))
C.append(TC("mt_budget_03","multi_turn","When is the budget review meeting?",
    grp=g,dep="mt_budget_02",mc=["Feb 24","rescheduled","Alice","OOO"],
    es=["budget review","rescheduled"]))
C.append(TC("mt_budget_04","multi_turn","What expense reports do I need to submit?",
    grp=g,dep="mt_budget_03",mc=["AWS","$450","team dinner","$380","JetBrains","$249"],
    es=["expense reports"]))
C.append(TC("mt_budget_05","multi_turn","Are there any other financial deadlines I should know about?",
    grp=g,dep="mt_budget_04",mc=["Feb 28","benefits","enrollment","Feb 21"],
    es=["Open enrollment","expense"]))
C.append(TC("mt_budget_06","multi_turn","What's the total conference travel budget that was approved?",
    grp=g,dep="mt_budget_05",mc=["$3,800","DevOps Summit","Concur"],
    es=["DevOps Summit","travel approved"]))

# ── 27: Security thread (3 rounds) ──────────────────────────────────────
g="session_mt_security"
C.append(TC("mt_security_01","multi_turn","Give me a full overview of security-related emails.",
    grp=g,mc=["CVE-2025-1234","log4j","security scan","NDA"],
    es=["Security scan","CVE","NDA review"]))
C.append(TC("mt_security_02","multi_turn","What were all the findings in the security scan?",
    grp=g,dep="mt_security_01",mc=["Critical","High","Medium","Low","TLS","password","debug"],
    es=["Security scan"]))
C.append(TC("mt_security_03","multi_turn","Has everything been addressed?",
    grp=g,dep="mt_security_02",mc=["patched","log4j 2.17.1","WAF"],
    es=["CVE","patched"]))

# ── 28: Design review thread (3 rounds) ─────────────────────────────────
g="session_mt_design"
C.append(TC("mt_design_01","multi_turn","What's the status of the Falcon UI design?",
    grp=g,mc=["Patricia","mockups","dashboard"],es=["Falcon UI mockups"]))
C.append(TC("mt_design_02","multi_turn","What feedback was given on the initial mockups?",
    grp=g,dep="mt_design_01",mc=["delivery time","CSV export","WCAG","confirmation dialog"],
    es=["Falcon UI mockups"]))
C.append(TC("mt_design_03","multi_turn","Was the feedback incorporated?",
    grp=g,dep="mt_design_02",mc=["revised","incorporated","sign-off","v2"],
    es=["Revised"]))

# ── 29: People & HR (4 rounds) ──────────────────────────────────────────
g="session_mt_people"
C.append(TC("mt_people_01","multi_turn","Who are the key people I've been emailing with and what are their roles?",
    grp=g,mc=["Alice","Dave","Eve","Irene","Lisa","Henry","Patricia"],cite=False))
C.append(TC("mt_people_02","multi_turn","Tell me about my performance review.",
    grp=g,dep="mt_people_01",mc=["Exceeds Expectations","4/5","8%","500 RSUs"],
    es=["performance review"]))
C.append(TC("mt_people_03","multi_turn","What training or development activities are coming up for me?",
    grp=g,dep="mt_people_02",mc=["compliance training","GDPR","DevOps Summit","March 1"],
    es=["compliance training","DevOps Summit"]))
C.append(TC("mt_people_04","multi_turn","What about the company offsite?",
    grp=g,dep="mt_people_03",mc=["April 5","Lakeside Resort","RSVP","February 25"],
    es=["Company offsite"]))

# ── 30: Cross-reference (2 rounds) ──────────────────────────────────────
g="session_crossref"
C.append(TC("crossref_01","cross_reference","What's the situation with the payment gateway API keys for Falcon?",
    grp=g,mc=["API keys","pending","approval","Dave","vendor"],es=["API keys for Falcon"]))
C.append(TC("crossref_02","cross_reference","How does this affect QA testing?",
    grp=g,dep="crossref_01",mc=["blocked","Tony","28/30","March 5","March 12"],
    es=["Falcon QA status"]))

test_cases = {
    "_meta": "Quality test cases for ThunderRAG. Each case runs through the full query flow.",
    "user_name": "Bob Martinez <bob@acme.com>",
    "cases": C
}

write_json("test_cases.json", test_cases)

# Print summary
groups = {}
for c in C:
    g = c["session_group"]
    groups.setdefault(g, []).append(c["id"])
print(f"\n{len(C)} test cases in {len(groups)} conversations:")
for g, ids in groups.items():
    print(f"  {g}: {len(ids)} rounds")
