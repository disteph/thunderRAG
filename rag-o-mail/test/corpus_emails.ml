(*
  100-email synthetic corpus for integration testing.
  Covers 15 thread clusters + standalone/edge-case emails.
*)

type email_spec =
  { id : string; from_ : string; to_ : string; cc : string
  ; subject : string; date : string; in_reply_to : string
  ; body : string; thread : string; actionable : bool }

let e ~id ~from_ ~to_ ?(cc="") ~subject ~date ?(irt="") ~body ~thr ~act () =
  { id; from_; to_; cc; subject; date; in_reply_to = irt; body; thread = thr; actionable = act }

(* ── Thread 1: Project Phoenix — Platform Migration (8 emails) ── *)
let t01 =
  [ e ~id:"phoenix-001@acme.com" ~from_:"Alice Chen <alice.chen@acme.com>"
      ~to_:"Engineering <eng@acme.com>" ~cc:"Leo Mueller <leo.mueller@acme.com>"
      ~subject:"Project Phoenix — kicking off the platform migration"
      ~date:"Mon, 03 Mar 2025 09:00:00 +0000"
      ~body:"Team,\n\nProject Phoenix is approved. We're migrating our monolith to microservices on k8s.\n\nMilestones:\n- Mar 15: Architecture review\n- Apr 1: Staging ready\n- Apr 15: Dry run\n- May 1: Production cutover\n\nPlease block time for the architecture review next week.\n\nAlice"
      ~thr:"phoenix" ~act:true ()
  ; e ~id:"phoenix-002@acme.com" ~from_:"Dave Singh <dave.singh@acme.com>"
      ~to_:"Alice Chen <alice.chen@acme.com>" ~cc:"Nathan Brooks <nathan.brooks@acme.com>"
      ~subject:"Re: Project Phoenix — kicking off the platform migration"
      ~date:"Mon, 03 Mar 2025 11:30:00 +0000" ~irt:"<phoenix-001@acme.com>"
      ~body:"Alice,\n\nThe Apr 1 staging deadline is tight — we need 12 new k8s nodes plus service mesh. I estimate 2-3 weeks for infra alone. Can we push to April 7?\n\nNathan — check if us-east-2 has capacity for the new cluster.\n\n— Dave"
      ~thr:"phoenix" ~act:true ()
  ; e ~id:"phoenix-003@acme.com" ~from_:"Bob Martinez <bob.martinez@acme.com>"
      ~to_:"Alice Chen <alice.chen@acme.com>"
      ~subject:"Re: Project Phoenix — QA test plan"
      ~date:"Mon, 03 Mar 2025 14:15:00 +0000" ~irt:"<phoenix-001@acme.com>"
      ~body:"Alice,\n\nQA plan covers: API contract validation for 47 endpoints, load testing at 2x peak, data migration integrity, and rollback validation. I'll need staging access as soon as it's up. Separate test DB?\n\nBob"
      ~thr:"phoenix" ~act:true ()
  ; e ~id:"phoenix-004@acme.com" ~from_:"Alice Chen <alice.chen@acme.com>"
      ~to_:"Dave Singh <dave.singh@acme.com>"
      ~cc:"Bob Martinez <bob.martinez@acme.com>, Nathan Brooks <nathan.brooks@acme.com>"
      ~subject:"Re: Project Phoenix — updated timeline"
      ~date:"Tue, 04 Mar 2025 09:00:00 +0000" ~irt:"<phoenix-002@acme.com>"
      ~body:"Dave, Bob,\n\nUpdated timeline:\n- Staging: April 7\n- Bob gets access April 8\n- Dry run: April 18\n- Cutover: May 1 (unchanged)\n\nDave, send infra requirements doc by Friday for budget approval.\n\nAlice"
      ~thr:"phoenix" ~act:true ()
  ; e ~id:"phoenix-005@acme.com" ~from_:"Leo Mueller <leo.mueller@acme.com>"
      ~to_:"Alice Chen <alice.chen@acme.com>"
      ~subject:"Re: Phoenix budget approval"
      ~date:"Wed, 05 Mar 2025 16:00:00 +0000" ~irt:"<phoenix-004@acme.com>"
      ~body:"Alice,\n\nBudget approved — $45K allocated for Q2 infrastructure under Phoenix. Make sure we have a solid rollback plan.\n\n— Leo"
      ~thr:"phoenix" ~act:false ()
  ; e ~id:"phoenix-006@acme.com" ~from_:"Nathan Brooks <nathan.brooks@acme.com>"
      ~to_:"Engineering <eng@acme.com>"
      ~subject:"Phoenix staging environment ready"
      ~date:"Mon, 07 Apr 2025 10:00:00 +0000" ~irt:"<phoenix-004@acme.com>"
      ~body:"Team,\n\nPhoenix staging is live:\n- Cluster: phoenix-staging.internal.acme.com\n- 12 nodes (4 vCPU, 16GB each)\n- Istio service mesh configured\n- PostgreSQL 16 replica (anonymized)\n\nBob, your QA account is provisioned.\n\nNathan"
      ~thr:"phoenix" ~act:true ()
  ; e ~id:"phoenix-007@acme.com" ~from_:"Dave Singh <dave.singh@acme.com>"
      ~to_:"Alice Chen <alice.chen@acme.com>" ~cc:"Engineering <eng@acme.com>"
      ~subject:"Phoenix dry run results"
      ~date:"Fri, 18 Apr 2025 17:00:00 +0000" ~irt:"<phoenix-006@acme.com>"
      ~body:"Team,\n\nDry run results: 46/47 endpoints migrated. /api/v2/reports has a timeout under load (missing index on new schema — fix deploying Monday). Data migration: 4h 23m. Rollback: under 15min. On track for May 1.\n\n— Dave"
      ~thr:"phoenix" ~act:true ()
  ; e ~id:"phoenix-008@acme.com" ~from_:"Alice Chen <alice.chen@acme.com>"
      ~to_:"Engineering <eng@acme.com>" ~cc:"Leo Mueller <leo.mueller@acme.com>"
      ~subject:"Phoenix go-live confirmed for May 1"
      ~date:"Mon, 28 Apr 2025 09:00:00 +0000" ~irt:"<phoenix-007@acme.com>"
      ~body:"Team,\n\nAll blockers resolved. Go-live: May 1, 6:00 AM UTC. War room: #phoenix-cutover. Everyone available 5:30 AM - noon UTC. Rollback decision point: 8:00 AM.\n\nLet's make this happen!\nAlice"
      ~thr:"phoenix" ~act:true ()
  ]

(* ── Thread 2: Q2 Budget Planning (5 emails) ── *)
let t02 =
  [ e ~id:"budget-001@acme.com" ~from_:"Carol Wu <carol.wu@acme.com>"
      ~to_:"Dept Heads <dept-heads@acme.com>"
      ~subject:"Q2 budget submissions due March 21"
      ~date:"Mon, 10 Mar 2025 08:00:00 +0000"
      ~body:"Department heads,\n\nQ2 budget requests due March 21. Use the template in Finance > Templates. Total budget is flat vs Q1 (+2% max). Headcount needs VP approval. CapEx over $10K needs CFO sign-off.\n\nI'll schedule review sessions the week of March 24.\n\nCarol"
      ~thr:"budget" ~act:true ()
  ; e ~id:"budget-002@acme.com" ~from_:"Frank O'Brien <frank.obrien@acme.com>"
      ~to_:"Carol Wu <carol.wu@acme.com>"
      ~subject:"Re: Q2 budget — Sales request"
      ~date:"Wed, 12 Mar 2025 15:00:00 +0000" ~irt:"<budget-001@acme.com>"
      ~body:"Carol,\n\nSales Q2 budget: 3 new SDRs ($180K), conference sponsorship ($35K), new CRM analytics tier ($12K/yr). Revenue target: $2.4M (up 15% vs Q1).\n\nFrank"
      ~thr:"budget" ~act:true ()
  ; e ~id:"budget-003@acme.com" ~from_:"Alice Chen <alice.chen@acme.com>"
      ~to_:"Carol Wu <carol.wu@acme.com>"
      ~subject:"Re: Q2 budget — Engineering request"
      ~date:"Thu, 13 Mar 2025 10:00:00 +0000" ~irt:"<budget-001@acme.com>"
      ~body:"Carol,\n\nEngineering Q2: Phoenix infra $45K (approved), 2 senior backend engineers $320K, Datadog Enterprise $8K/mo, team offsite $15K.\n\nAlice"
      ~thr:"budget" ~act:true ()
  ; e ~id:"budget-004@acme.com" ~from_:"Carol Wu <carol.wu@acme.com>"
      ~to_:"Dept Heads <dept-heads@acme.com>"
      ~subject:"Budget review meetings scheduled"
      ~date:"Mon, 24 Mar 2025 09:00:00 +0000" ~irt:"<budget-001@acme.com>"
      ~body:"All,\n\nReview sessions: Sales Tue 10am, Engineering Tue 2pm, Marketing Wed 10am, HR Wed 2pm, Legal Thu 10am. We're $85K over target — bring priority-ranked lists.\n\nCarol"
      ~thr:"budget" ~act:true ()
  ; e ~id:"budget-005@acme.com" ~from_:"Carol Wu <carol.wu@acme.com>"
      ~to_:"All Staff <all@acme.com>"
      ~subject:"Q2 budget finalized"
      ~date:"Fri, 28 Mar 2025 16:00:00 +0000" ~irt:"<budget-004@acme.com>"
      ~body:"Team,\n\nQ2 budget approved by the board. Phoenix infra approved. Sales: 2 SDRs (1 deferred to Q3). Engineering: 2 senior hires. Marketing +10%. Retreat approved for June.\n\nCarol"
      ~thr:"budget" ~act:false ()
  ]

(* ── Thread 3: Security Incident (7 emails) ── *)
let t03 =
  [ e ~id:"security-001@acme.com" ~from_:"Eve Nowak <eve.nowak@acme.com>"
      ~to_:"Security <security@acme.com>" ~cc:"Leo Mueller <leo.mueller@acme.com>"
      ~subject:"ALERT: Suspicious login activity detected"
      ~date:"Tue, 11 Mar 2025 03:15:00 +0000"
      ~body:"SECURITY ALERT — HIGH SEVERITY\n\nAt 02:47 UTC: 147 failed logins from Tor exit nodes. 3 successful auths using compromised contractor account (jsmith-contractor).\n\nActions taken: account disabled, IP blocked, sessions rotated.\n\nDave: check lateral movement. Nathan: pull 72h access logs.\n\nEve"
      ~thr:"security" ~act:true ()
  ; e ~id:"security-002@acme.com" ~from_:"Dave Singh <dave.singh@acme.com>"
      ~to_:"Eve Nowak <eve.nowak@acme.com>" ~cc:"Security <security@acme.com>"
      ~subject:"Re: ALERT: Suspicious login activity"
      ~date:"Tue, 11 Mar 2025 04:30:00 +0000" ~irt:"<security-001@acme.com>"
      ~body:"Eve,\n\nSession lasted 12 minutes. Attacker accessed user management page (read-only). No write ops, no API key generation, no lateral movement. Session killed by idle timeout. Recommend MFA on all admin accounts immediately.\n\nDave"
      ~thr:"security" ~act:true ()
  ; e ~id:"security-003@acme.com" ~from_:"Eve Nowak <eve.nowak@acme.com>"
      ~to_:"Security <security@acme.com>" ~cc:"Leo Mueller <leo.mueller@acme.com>"
      ~subject:"Incident update — scope confirmed"
      ~date:"Tue, 11 Mar 2025 08:00:00 +0000" ~irt:"<security-002@acme.com>"
      ~body:"Team,\n\nBreach limited to admin portal. No customer data accessed. Root cause: contractor credentials found in a public GitHub repo (.env file).\n\nAction items:\n1. MFA mandatory by EOD tomorrow\n2. Credential scan of public repos\n3. Contractor security training\n4. Nathan: IP allowlisting for admin portal\n\nEve"
      ~thr:"security" ~act:true ()
  ; e ~id:"security-004@acme.com" ~from_:"Nathan Brooks <nathan.brooks@acme.com>"
      ~to_:"Eve Nowak <eve.nowak@acme.com>" ~cc:"Dave Singh <dave.singh@acme.com>"
      ~subject:"Re: Incident — firewall rules updated"
      ~date:"Tue, 11 Mar 2025 11:00:00 +0000" ~irt:"<security-003@acme.com>"
      ~body:"Eve,\n\nFirewall updated: admin portal VPN-only, geo-blocking for hostile ranges, rate limiting (5 failed = 30min lockout). IP allowlist fully deployed by end of week. Adding Cloudflare Access as zero-trust layer.\n\nNathan"
      ~thr:"security" ~act:true ()
  ; e ~id:"security-005@acme.com" ~from_:"Eve Nowak <eve.nowak@acme.com>"
      ~to_:"Security <security@acme.com>"
      ~subject:"Incident CONTAINED"
      ~date:"Wed, 12 Mar 2025 09:00:00 +0000" ~irt:"<security-004@acme.com>"
      ~body:"Team,\n\nSEC-2025-03-11 is CONTAINED. MFA enabled, credentials rotated, IP allowlisting deployed, rate limiting active. Remaining: credential scan, contractor training, post-incident report (due March 19).\n\nEve"
      ~thr:"security" ~act:true ()
  ; e ~id:"security-006@acme.com" ~from_:"Karen Patel <karen.patel@acme.com>"
      ~to_:"Eve Nowak <eve.nowak@acme.com>" ~cc:"Leo Mueller <leo.mueller@acme.com>"
      ~subject:"Re: Incident — legal notification requirements"
      ~date:"Wed, 12 Mar 2025 14:00:00 +0000" ~irt:"<security-005@acme.com>"
      ~body:"Eve,\n\nNo mandatory notification (no customer PII accessed). Recommend: document incident, update IR plan, brief board next month. I'll draft the board briefing — send me the post-incident report.\n\nKaren"
      ~thr:"security" ~act:true ()
  ; e ~id:"security-007@acme.com" ~from_:"Eve Nowak <eve.nowak@acme.com>"
      ~to_:"All Staff <all@acme.com>"
      ~subject:"Security incident summary and reminders"
      ~date:"Fri, 21 Mar 2025 10:00:00 +0000" ~irt:"<security-006@acme.com>"
      ~body:"All,\n\nOn March 11 we contained a security incident involving compromised contractor credentials. No customer data affected.\n\nNew policies: MFA mandatory, admin portal VPN-only, quarterly security training required. Please complete training by March 31.\n\nEve"
      ~thr:"security" ~act:false ()
  ]

(* ── Thread 4: Website Redesign (5 emails) ── *)
let t04 =
  [ e ~id:"redesign-001@acme.com" ~from_:"Irene Costa <irene.costa@acme.com>"
      ~to_:"Alice Chen <alice.chen@acme.com>" ~cc:"Maria Santos <maria.santos@acme.com>"
      ~subject:"Website redesign v2 proposal"
      ~date:"Wed, 05 Mar 2025 10:00:00 +0000"
      ~body:"Alice, Maria,\n\nConversion rate dropped 18% since Q3. Proposing full redesign: modernized landing pages, interactive product demo, improved mobile (40% of traffic), blog with SEO. Can we schedule a review this week?\n\nIrene"
      ~thr:"redesign" ~act:true ()
  ; e ~id:"redesign-002@acme.com" ~from_:"Alice Chen <alice.chen@acme.com>"
      ~to_:"Irene Costa <irene.costa@acme.com>" ~cc:"Maria Santos <maria.santos@acme.com>"
      ~subject:"Re: Website redesign v2 proposal"
      ~date:"Thu, 06 Mar 2025 14:00:00 +0000" ~irt:"<redesign-001@acme.com>"
      ~body:"Irene,\n\nEstimate: landing pages 3wk, interactive demo 2wk, mobile 1wk, blog+SEO 2wk. Total ~4 weeks with 2 devs. Can start mid-April after Phoenix dry run.\n\nAlice"
      ~thr:"redesign" ~act:true ()
  ; e ~id:"redesign-003@acme.com" ~from_:"Maria Santos <maria.santos@acme.com>"
      ~to_:"Irene Costa <irene.costa@acme.com>" ~cc:"Alice Chen <alice.chen@acme.com>"
      ~subject:"Re: Website redesign — project plan"
      ~date:"Fri, 07 Mar 2025 09:00:00 +0000" ~irt:"<redesign-002@acme.com>"
      ~body:"Project plan:\n- Sprint 1 (Apr 14-25): Landing pages + mobile\n- Sprint 2 (Apr 28-May 9): Interactive demo\n- Sprint 3 (May 12-23): Blog + SEO + polish\n- Launch: May 26\n\nAlice, assign developers by April 7?\n\nMaria"
      ~thr:"redesign" ~act:true ()
  ; e ~id:"redesign-004@acme.com" ~from_:"Irene Costa <irene.costa@acme.com>"
      ~to_:"Engineering <eng@acme.com>" ~cc:"Maria Santos <maria.santos@acme.com>"
      ~subject:"Redesign mockups ready for review"
      ~date:"Mon, 07 Apr 2025 10:00:00 +0000" ~irt:"<redesign-003@acme.com>"
      ~body:"Team,\n\nFinal mockups in Figma: Homepage (3 A/B variants), product page with demo placeholder, pricing page (new tiers), blog layout. Review and comment by Wednesday — Sprint 1 starts Monday.\n\nIrene"
      ~thr:"redesign" ~act:true ()
  ; e ~id:"redesign-005@acme.com" ~from_:"Maria Santos <maria.santos@acme.com>"
      ~to_:"Engineering <eng@acme.com>"
      ~subject:"Redesign Sprint 1 kickoff"
      ~date:"Mon, 14 Apr 2025 09:00:00 +0000" ~irt:"<redesign-004@acme.com>"
      ~body:"Team,\n\nSprint 1 underway. Landing pages: Chen Wei. Mobile: Priya Sharma. Daily standup 9:30am #website-redesign. Sprint review: Friday Apr 25 3pm.\n\nMaria"
      ~thr:"redesign" ~act:true ()
  ]

(* ── Thread 5: New Hire Onboarding (4 emails) ── *)
let t05 =
  [ e ~id:"onboard-001@acme.com" ~from_:"Grace Kim <grace.kim@acme.com>"
      ~to_:"Alice Chen <alice.chen@acme.com>" ~cc:"Dave Singh <dave.singh@acme.com>"
      ~subject:"New hire starting March 3 — Priya Sharma"
      ~date:"Fri, 28 Feb 2025 15:00:00 +0000"
      ~body:"Alice, Dave,\n\nPriya Sharma joins as Senior Frontend Developer on March 3 (website redesign). Alice: assign buddy/mentor. Dave: provision laptop + accounts (GitHub, Slack, Jira, AWS). Review onboarding checklist in Notion.\n\nGrace"
      ~thr:"onboarding" ~act:true ()
  ; e ~id:"onboard-002@acme.com" ~from_:"Alice Chen <alice.chen@acme.com>"
      ~to_:"Grace Kim <grace.kim@acme.com>" ~cc:"Dave Singh <dave.singh@acme.com>"
      ~subject:"Re: New hire — Priya Sharma"
      ~date:"Fri, 28 Feb 2025 16:30:00 +0000" ~irt:"<onboard-001@acme.com>"
      ~body:"Grace,\n\nChen Wei will be Priya's buddy. Scheduled: Tue 2pm 1:1 with me, Wed 10am architecture walkthrough with Dave, Thu 2pm codebase tour with Chen Wei.\n\nAlice"
      ~thr:"onboarding" ~act:false ()
  ; e ~id:"onboard-003@acme.com" ~from_:"Dave Singh <dave.singh@acme.com>"
      ~to_:"Grace Kim <grace.kim@acme.com>"
      ~subject:"Re: New hire — accounts provisioned"
      ~date:"Fri, 28 Feb 2025 17:00:00 +0000" ~irt:"<onboard-001@acme.com>"
      ~body:"Grace,\n\nAll done: GitHub (priya-sharma-acme), Slack, Jira, AWS IAM (dev-team policy), VPN credentials sealed. Laptop (MacBook Pro M3) ready at reception Monday.\n\nDave"
      ~thr:"onboarding" ~act:false ()
  ; e ~id:"onboard-004@acme.com" ~from_:"Grace Kim <grace.kim@acme.com>"
      ~to_:"Priya Sharma <priya.sharma@acme.com>"
      ~cc:"Alice Chen <alice.chen@acme.com>, Dave Singh <dave.singh@acme.com>"
      ~subject:"Welcome to Acme, Priya!"
      ~date:"Mon, 03 Mar 2025 08:00:00 +0000" ~irt:"<onboard-003@acme.com>"
      ~body:"Hi Priya,\n\nWelcome! Day 1: 9am HR orientation, 11am IT setup with Dave, 12:30pm team lunch, 2pm self-guided Notion docs. Your buddy Chen Wei is your go-to for questions.\n\nGrace"
      ~thr:"onboarding" ~act:false ()
  ]

(* ── Thread 6: Client Demo — BigCorp (6 emails) ── *)
let t06 =
  [ e ~id:"bigcorp-001@acme.com" ~from_:"Frank O'Brien <frank.obrien@acme.com>"
      ~to_:"Alice Chen <alice.chen@acme.com>" ~cc:"Maria Santos <maria.santos@acme.com>"
      ~subject:"BigCorp demo request — $500K deal"
      ~date:"Tue, 18 Mar 2025 10:00:00 +0000"
      ~body:"Alice, Maria,\n\nBigCorp VP wants a technical demo next week — potential $500K/yr deal. They want: real-time analytics, API integration, SSO/SAML, EU data residency. Can we set up a demo env by Tuesday March 25?\n\nFrank"
      ~thr:"bigcorp" ~act:true ()
  ; e ~id:"bigcorp-002@acme.com" ~from_:"Maria Santos <maria.santos@acme.com>"
      ~to_:"Frank O'Brien <frank.obrien@acme.com>" ~cc:"Alice Chen <alice.chen@acme.com>"
      ~subject:"Re: BigCorp demo — prep plan"
      ~date:"Tue, 18 Mar 2025 14:00:00 +0000" ~irt:"<bigcorp-001@acme.com>"
      ~body:"Frank,\n\nPlan: Wed set up demo tenant, Thu configure SSO (Okta), Fri dry run, Tue Mar 25 2pm live demo. Alice — assign someone for the API integration demo (webhook system + REST explorer).\n\nMaria"
      ~thr:"bigcorp" ~act:true ()
  ; e ~id:"bigcorp-003@acme.com" ~from_:"Alice Chen <alice.chen@acme.com>"
      ~to_:"Maria Santos <maria.santos@acme.com>" ~cc:"Frank O'Brien <frank.obrien@acme.com>"
      ~subject:"Re: BigCorp — demo env ready"
      ~date:"Wed, 19 Mar 2025 09:00:00 +0000" ~irt:"<bigcorp-002@acme.com>"
      ~body:"Demo environment ready: demo.acme.com/bigcorp. Loaded with realistic sample data, API explorer live, 3 webhook examples configured. For EU residency: we can spin up eu-west-1 — I'll get a cost estimate.\n\nAlice"
      ~thr:"bigcorp" ~act:true ()
  ; e ~id:"bigcorp-004@acme.com" ~from_:"Frank O'Brien <frank.obrien@acme.com>"
      ~to_:"Alice Chen <alice.chen@acme.com>" ~cc:"Maria Santos <maria.santos@acme.com>"
      ~subject:"BigCorp demo debrief — very positive"
      ~date:"Tue, 25 Mar 2025 17:00:00 +0000" ~irt:"<bigcorp-003@acme.com>"
      ~body:"Team,\n\nDemo went great! VP impressed with analytics and API flexibility. Follow-ups: POC with their data (2-week trial), security questionnaire, pricing proposal with EU option, architecture doc for IT review. Could close in April — our biggest deal ever.\n\nFrank"
      ~thr:"bigcorp" ~act:true ()
  ; e ~id:"bigcorp-005@acme.com" ~from_:"Frank O'Brien <frank.obrien@acme.com>"
      ~to_:"Alice Chen <alice.chen@acme.com>"
      ~subject:"BigCorp CTO follow-up questions"
      ~date:"Thu, 27 Mar 2025 10:00:00 +0000" ~irt:"<bigcorp-004@acme.com>"
      ~body:"Alice,\n\nBigCorp CTO questions: 1) SLA for analytics API (<200ms p99)? 2) Custom RBAC roles (5 tiers)? 3) Per-env webhooks (staging vs prod)? 4) 7-year data retention? 5) Terraform provider?\n\nCan you respond by Monday?\n\nFrank"
      ~thr:"bigcorp" ~act:true ()
  ; e ~id:"bigcorp-006@acme.com" ~from_:"Maria Santos <maria.santos@acme.com>"
      ~to_:"Frank O'Brien <frank.obrien@acme.com>" ~cc:"Alice Chen <alice.chen@acme.com>"
      ~subject:"BigCorp proposal sent"
      ~date:"Fri, 04 Apr 2025 16:00:00 +0000" ~irt:"<bigcorp-005@acme.com>"
      ~body:"Proposal sent: Enterprise tier $480K/yr (3-year), EU hosting $48K/yr, 2-week free POC, technical FAQ, architecture doc, security questionnaire. Ball in their court.\n\nMaria"
      ~thr:"bigcorp" ~act:false ()
  ]

(* ── Thread 7: CI/CD Pipeline (5 emails) ── *)
let t07 =
  [ e ~id:"cicd-001@acme.com" ~from_:"Dave Singh <dave.singh@acme.com>"
      ~to_:"Alice Chen <alice.chen@acme.com>" ~cc:"Nathan Brooks <nathan.brooks@acme.com>"
      ~subject:"CI/CD pipeline modernization proposal"
      ~date:"Mon, 17 Mar 2025 09:00:00 +0000"
      ~body:"Alice,\n\nJenkins is a bottleneck (23min avg build). Proposal: migrate to GitHub Actions + ArgoCD. Target: <8min builds, preview envs per PR, GitOps deployments, ~$2K/mo savings. Phase 1: 5 core services (2wk). Phase 2: remaining + decommission Jenkins (2wk). Can start Monday if approved.\n\nDave"
      ~thr:"cicd" ~act:true ()
  ; e ~id:"cicd-002@acme.com" ~from_:"Nathan Brooks <nathan.brooks@acme.com>"
      ~to_:"Dave Singh <dave.singh@acme.com>" ~cc:"Alice Chen <alice.chen@acme.com>"
      ~subject:"Re: CI/CD modernization — infra requirements"
      ~date:"Mon, 17 Mar 2025 14:00:00 +0000" ~irt:"<cicd-001@acme.com>"
      ~body:"Dave,\n\nFor ArgoCD: dedicated k8s namespace (argo-system), 3 nodes for controllers, Sealed Secrets, External DNS for preview envs. Can have infra ready by Wednesday.\n\nNathan"
      ~thr:"cicd" ~act:true ()
  ; e ~id:"cicd-003@acme.com" ~from_:"Alice Chen <alice.chen@acme.com>"
      ~to_:"Dave Singh <dave.singh@acme.com>" ~cc:"Nathan Brooks <nathan.brooks@acme.com>"
      ~subject:"Re: CI/CD — approved"
      ~date:"Tue, 18 Mar 2025 09:00:00 +0000" ~irt:"<cicd-002@acme.com>"
      ~body:"Dave, Nathan,\n\nApproved. Keep Jenkins running in parallel until Phase 2 validated. Document migration steps per service. Set up PagerDuty alerts for ArgoCD sync failures.\n\nAlice"
      ~thr:"cicd" ~act:true ()
  ; e ~id:"cicd-004@acme.com" ~from_:"Dave Singh <dave.singh@acme.com>"
      ~to_:"Engineering <eng@acme.com>"
      ~subject:"CI/CD Phase 1 complete"
      ~date:"Fri, 28 Mar 2025 17:00:00 +0000" ~irt:"<cicd-003@acme.com>"
      ~body:"Team,\n\n5 core services now on GitHub Actions + ArgoCD. Build time: 6 min (down from 23!). Preview environments working. Zero failed deployments during migration. Phase 2 starts Monday.\n\nDave"
      ~thr:"cicd" ~act:false ()
  ; e ~id:"cicd-005@acme.com" ~from_:"Dave Singh <dave.singh@acme.com>"
      ~to_:"Engineering <eng@acme.com>" ~cc:"Alice Chen <alice.chen@acme.com>"
      ~subject:"CI/CD fully operational — Jenkins decommissioned"
      ~date:"Fri, 11 Apr 2025 17:00:00 +0000" ~irt:"<cicd-004@acme.com>"
      ~body:"Team,\n\nAll 18 services migrated. Jenkins decommissioned. Avg build: 5.8min, monthly savings: $2,100, preview envs: 100% coverage. Ping me in #devops for issues.\n\nDave"
      ~thr:"cicd" ~act:false ()
  ]

(* ── Thread 8: Company Retreat (4 emails) ── *)
let t08 =
  [ e ~id:"retreat-001@acme.com" ~from_:"Grace Kim <grace.kim@acme.com>"
      ~to_:"All Staff <all@acme.com>"
      ~subject:"Annual company retreat — save the date!"
      ~date:"Mon, 10 Mar 2025 10:00:00 +0000"
      ~body:"Everyone,\n\nSave the date! Annual retreat June 13-15. Theme: \"Building Together.\" Venue survey coming this week.\n\nGrace"
      ~thr:"retreat" ~act:false ()
  ; e ~id:"retreat-002@acme.com" ~from_:"Grace Kim <grace.kim@acme.com>"
      ~to_:"All Staff <all@acme.com>"
      ~subject:"Retreat venue vote — respond by March 21"
      ~date:"Wed, 12 Mar 2025 10:00:00 +0000" ~irt:"<retreat-001@acme.com>"
      ~body:"Vote for your venue:\nA) Mountain Lodge, Lake Tahoe\nB) Coastal Inn, Half Moon Bay\nC) Wine Country Estate, Napa\n\nVote: https://forms.acme.com/retreat-2025. Deadline: March 21.\n\nGrace"
      ~thr:"retreat" ~act:true ()
  ; e ~id:"retreat-003@acme.com" ~from_:"Grace Kim <grace.kim@acme.com>"
      ~to_:"All Staff <all@acme.com>"
      ~subject:"Retreat agenda finalized — Half Moon Bay!"
      ~date:"Mon, 07 Apr 2025 10:00:00 +0000" ~irt:"<retreat-002@acme.com>"
      ~body:"Half Moon Bay won (52%)! Fri 2pm check-in, Fri 7pm dinner, Sat 9am all-hands, Sat 2pm activities, Sat 7pm awards dinner, Sun 10am brunch.\n\nGrace"
      ~thr:"retreat" ~act:false ()
  ; e ~id:"retreat-004@acme.com" ~from_:"Grace Kim <grace.kim@acme.com>"
      ~to_:"All Staff <all@acme.com>"
      ~subject:"Retreat logistics and travel info"
      ~date:"Mon, 02 Jun 2025 10:00:00 +0000" ~irt:"<retreat-003@acme.com>"
      ~body:"Shuttle from office 12pm Fri, returns 1pm Sun. Self-drive: 123 Ocean View Dr, Half Moon Bay. Bring: comfortable clothes, swimsuit, laptop for Sat session. Dietary: https://forms.acme.com/retreat-dietary\n\nGrace"
      ~thr:"retreat" ~act:true ()
  ]

(* ── Thread 9: Customer Escalation — Widget Corp (5 emails) ── *)
let t09 =
  [ e ~id:"escalation-001@acme.com" ~from_:"Jake Reeves <jake.reeves@acme.com>"
      ~to_:"Alice Chen <alice.chen@acme.com>" ~cc:"Frank O'Brien <frank.obrien@acme.com>"
      ~subject:"URGENT: Widget Corp critical escalation"
      ~date:"Wed, 19 Mar 2025 08:00:00 +0000"
      ~body:"Alice, Frank,\n\nWidget Corp ($180K ARR, #3 customer) threatening to churn. Dashboard stale 3 days — webhook silently fails for payloads >5MB (they send 8-12MB). VP called directly. Need fix by Friday. P0.\n\nJake"
      ~thr:"escalation" ~act:true ()
  ; e ~id:"escalation-002@acme.com" ~from_:"Alice Chen <alice.chen@acme.com>"
      ~to_:"Jake Reeves <jake.reeves@acme.com>" ~cc:"Frank O'Brien <frank.obrien@acme.com>"
      ~subject:"Re: Widget Corp escalation"
      ~date:"Wed, 19 Mar 2025 10:00:00 +0000" ~irt:"<escalation-001@acme.com>"
      ~body:"Two-track: 1) Workaround — increase limit to 25MB (deploying today). 2) Proper fix — chunked upload (this sprint). Workaround live by 3pm. Frank, call their VP.\n\nAlice"
      ~thr:"escalation" ~act:true ()
  ; e ~id:"escalation-003@acme.com" ~from_:"Jake Reeves <jake.reeves@acme.com>"
      ~to_:"Alice Chen <alice.chen@acme.com>" ~cc:"Frank O'Brien <frank.obrien@acme.com>"
      ~subject:"Re: Widget Corp — workaround deployed"
      ~date:"Wed, 19 Mar 2025 16:00:00 +0000" ~irt:"<escalation-002@acme.com>"
      ~body:"Confirmed — webhooks processing, dashboard current. Widget Corp satisfied for now. They want ETA on chunked upload. Can we commit to April 4?\n\nJake"
      ~thr:"escalation" ~act:true ()
  ; e ~id:"escalation-004@acme.com" ~from_:"Alice Chen <alice.chen@acme.com>"
      ~to_:"Jake Reeves <jake.reeves@acme.com>" ~cc:"Frank O'Brien <frank.obrien@acme.com>"
      ~subject:"Widget Corp — permanent fix deployed"
      ~date:"Fri, 04 Apr 2025 14:00:00 +0000" ~irt:"<escalation-003@acme.com>"
      ~body:"Chunked upload complete: payloads up to 100MB via multipart, auto-chunking >5MB, backward compatible. Widget Corp migrated and tested. Root cause documented.\n\nAlice"
      ~thr:"escalation" ~act:false ()
  ; e ~id:"escalation-005@acme.com" ~from_:"Frank O'Brien <frank.obrien@acme.com>"
      ~to_:"Jake Reeves <jake.reeves@acme.com>" ~cc:"Alice Chen <alice.chen@acme.com>"
      ~subject:"Widget Corp — expansion incoming"
      ~date:"Mon, 07 Apr 2025 09:00:00 +0000" ~irt:"<escalation-004@acme.com>"
      ~body:"Widget Corp VP happy with turnaround — they want to expand, adding 3 more teams. Preparing expansion proposal. Alice, estimate infra cost for tripling their usage?\n\nFrank"
      ~thr:"escalation" ~act:true ()
  ]

(* ── Thread 10: ML Paper Collaboration (4 emails) ── *)
let t10 =
  [ e ~id:"mlpaper-001@acme.com" ~from_:"Hiro Tanaka <hiro.tanaka@acme.com>"
      ~to_:"Olivia Zhang <olivia.zhang@acme.com>"
      ~subject:"Collaboration on anomaly detection paper"
      ~date:"Tue, 04 Mar 2025 10:00:00 +0000"
      ~body:"Olivia,\n\nNovel anomaly detection approach: attention + time-series decomposition. F1: 0.94 vs 0.87 baseline. Co-author a paper? Targeting ICML 2025 (deadline May 30).\n\nHiro"
      ~thr:"mlpaper" ~act:true ()
  ; e ~id:"mlpaper-002@acme.com" ~from_:"Olivia Zhang <olivia.zhang@acme.com>"
      ~to_:"Hiro Tanaka <hiro.tanaka@acme.com>"
      ~subject:"Re: Anomaly detection paper"
      ~date:"Wed, 05 Mar 2025 09:00:00 +0000" ~irt:"<mlpaper-001@acme.com>"
      ~body:"Love to collaborate! Suggestions: use NAB benchmark + internal data, scalability analysis, compare vs SPOT/SR/USAD. I'll contribute our streaming pipeline. Weekly sync?\n\nOlivia"
      ~thr:"mlpaper" ~act:true ()
  ; e ~id:"mlpaper-003@acme.com" ~from_:"Hiro Tanaka <hiro.tanaka@acme.com>"
      ~to_:"Olivia Zhang <olivia.zhang@acme.com>"
      ~subject:"Revised paper outline"
      ~date:"Mon, 17 Mar 2025 10:00:00 +0000" ~irt:"<mlpaper-002@acme.com>"
      ~body:"Updated outline: Intro, Related Work, AttentionDecomp method, Evaluation (NAB + internal + scalability 1K-100K events/s + ablation), Streaming Pipeline, Discussion. Timeline: Mar baselines, Apr scalability, May writing, May 30 submit.\n\nHiro"
      ~thr:"mlpaper" ~act:true ()
  ; e ~id:"mlpaper-004@acme.com" ~from_:"Hiro Tanaka <hiro.tanaka@acme.com>"
      ~to_:"Olivia Zhang <olivia.zhang@acme.com>" ~cc:"Leo Mueller <leo.mueller@acme.com>"
      ~subject:"Paper accepted at ICML 2025!"
      ~date:"Mon, 14 Jul 2025 08:00:00 +0000" ~irt:"<mlpaper-003@acme.com>"
      ~body:"\"AttentionDecomp\" accepted at ICML 2025! Scores: 7, 8, 7 (strong accept). Minor camera-ready revision. Leo — would Acme sponsor the conference trip?\n\nHiro"
      ~thr:"mlpaper" ~act:false ()
  ]

(* ── Thread 11: CloudHost Contract (5 emails) ── *)
let t11 =
  [ e ~id:"cloudhost-001@acme.com" ~from_:"Karen Patel <karen.patel@acme.com>"
      ~to_:"Leo Mueller <leo.mueller@acme.com>" ~cc:"Carol Wu <carol.wu@acme.com>"
      ~subject:"CloudHost contract renewal — action by April 15"
      ~date:"Mon, 17 Mar 2025 09:00:00 +0000"
      ~body:"CloudHost expires May 1. Current $180K/yr, renewal $195K (8% up), AWS alternative ~$210K. They'll do 4% for 3-year. Leo: tech requirements? Carol: budget ceiling?\n\nKaren"
      ~thr:"cloudhost" ~act:true ()
  ; e ~id:"cloudhost-002@acme.com" ~from_:"Leo Mueller <leo.mueller@acme.com>"
      ~to_:"Karen Patel <karen.patel@acme.com>" ~cc:"Carol Wu <carol.wu@acme.com>"
      ~subject:"Re: CloudHost — technical requirements"
      ~date:"Tue, 18 Mar 2025 14:00:00 +0000" ~irt:"<cloudhost-001@acme.com>"
      ~body:"Requirements: GPU instances (ML workloads — dealbreaker), managed k8s with autoscaling, 99.99% SLA, EU data center, SOC2 Type II. Ask about GPU.\n\nLeo"
      ~thr:"cloudhost" ~act:true ()
  ; e ~id:"cloudhost-003@acme.com" ~from_:"Karen Patel <karen.patel@acme.com>"
      ~to_:"Leo Mueller <leo.mueller@acme.com>" ~cc:"Carol Wu <carol.wu@acme.com>"
      ~subject:"CloudHost revised terms — includes GPU"
      ~date:"Mon, 24 Mar 2025 11:00:00 +0000" ~irt:"<cloudhost-002@acme.com>"
      ~body:"Revised: $188K/yr (4.4% up), 3-year, GPU A100/H100 in Q3, EU DC included, 99.99% SLA with credits, SOC2. 3-year lock-in saves $21K vs annual. Carol: $188K work?\n\nKaren"
      ~thr:"cloudhost" ~act:true ()
  ; e ~id:"cloudhost-004@acme.com" ~from_:"Carol Wu <carol.wu@acme.com>"
      ~to_:"Karen Patel <karen.patel@acme.com>" ~cc:"Leo Mueller <leo.mueller@acme.com>"
      ~subject:"Re: CloudHost — approved"
      ~date:"Tue, 25 Mar 2025 09:00:00 +0000" ~irt:"<cloudhost-003@acme.com>"
      ~body:"$188K/yr approved for 3-year. Negotiate 30-day exit clause for material SLA breaches (3+ incidents/quarter).\n\nCarol"
      ~thr:"cloudhost" ~act:true ()
  ; e ~id:"cloudhost-005@acme.com" ~from_:"Karen Patel <karen.patel@acme.com>"
      ~to_:"All Staff <all@acme.com>"
      ~subject:"CloudHost contract renewed"
      ~date:"Wed, 09 Apr 2025 10:00:00 +0000" ~irt:"<cloudhost-004@acme.com>"
      ~body:"CloudHost renewed 3 years. Improvements: GPU instances Q3, EU data center, improved SLA with credits. For infra changes, work with Dave's team.\n\nKaren"
      ~thr:"cloudhost" ~act:false ()
  ]
(* ── Thread 12: Spring Marketing Campaign (4 emails) ── *)
let t12 =
  [ e ~id:"campaign-001@acme.com" ~from_:"Irene Costa <irene.costa@acme.com>"
      ~to_:"Marketing <marketing@acme.com>" ~cc:"Frank O'Brien <frank.obrien@acme.com>"
      ~subject:"Spring product launch campaign plan"
      ~date:"Mon, 10 Mar 2025 10:00:00 +0000"
      ~body:"Theme: \"Accelerate Everything.\" Launch: April 14. Budget: $45K. Channels: blog (4 posts), LinkedIn ads ($15K), Product Hunt, webinar Apr 17, email nurture (5 emails). Frank — sales enablement materials by April 7.\n\nIrene"
      ~thr:"campaign" ~act:true ()
  ; e ~id:"campaign-002@acme.com" ~from_:"Irene Costa <irene.costa@acme.com>"
      ~to_:"Frank O'Brien <frank.obrien@acme.com>"
      ~subject:"Campaign sales enablement ready"
      ~date:"Mon, 07 Apr 2025 09:00:00 +0000" ~irt:"<campaign-001@acme.com>"
      ~body:"Materials ready: battle cards (vs Competitor X and Y), demo script, one-pager, ROI calculator. All in Marketing > Spring 2025 > Sales Enablement. Review by Wednesday.\n\nIrene"
      ~thr:"campaign" ~act:true ()
  ; e ~id:"campaign-003@acme.com" ~from_:"Frank O'Brien <frank.obrien@acme.com>"
      ~to_:"Irene Costa <irene.costa@acme.com>"
      ~subject:"Re: Sales enablement feedback"
      ~date:"Wed, 09 Apr 2025 14:00:00 +0000" ~irt:"<campaign-002@acme.com>"
      ~body:"Great work. Tweaks: battle card vs X — add uptime SLA (99.99 vs 99.9); demo script — webhook config section; ROI calc — data migration savings field. Team is excited.\n\nFrank"
      ~thr:"campaign" ~act:true ()
  ; e ~id:"campaign-004@acme.com" ~from_:"Irene Costa <irene.costa@acme.com>"
      ~to_:"All Staff <all@acme.com>"
      ~subject:"Spring campaign LIVE!"
      ~date:"Mon, 14 Apr 2025 09:00:00 +0000" ~irt:"<campaign-003@acme.com>"
      ~body:"Campaign LIVE! Product Hunt: producthunt.com/posts/acme-v3. Blog: blog.acme.com/accelerate-everything. Webinar: acme.com/webinar-scale. We're #3 on Product Hunt — share to reach #1!\n\nIrene"
      ~thr:"campaign" ~act:false ()
  ]

(* ── Thread 13: Server Outage Post-mortem (5 emails) ── *)
let t13 =
  [ e ~id:"outage-001@acme.com" ~from_:"Nathan Brooks <nathan.brooks@acme.com>"
      ~to_:"Engineering <eng@acme.com>" ~cc:"Leo Mueller <leo.mueller@acme.com>"
      ~subject:"URGENT: Production database outage"
      ~date:"Thu, 20 Mar 2025 02:30:00 +0000"
      ~body:"INCIDENT IN PROGRESS\n\n02:15 PagerDuty: primary replica lag >30s. 02:18 primary unresponsive. 02:22 auto-failover FAILED. All APIs 503. Working on manual failover. ETA 30-45min. Channel: #incident-2025-03-20\n\nNathan"
      ~thr:"outage" ~act:true ()
  ; e ~id:"outage-002@acme.com" ~from_:"Dave Singh <dave.singh@acme.com>"
      ~to_:"Nathan Brooks <nathan.brooks@acme.com>" ~cc:"Engineering <eng@acme.com>"
      ~subject:"Re: Production outage — root cause"
      ~date:"Thu, 20 Mar 2025 03:00:00 +0000" ~irt:"<outage-001@acme.com>"
      ~body:"Root cause: primary out of disk — uncontrolled WAL growth from nightly VACUUM. Auto-failover failed (secondary 45s behind, threshold 30s). Cleaning WAL now, then promoting secondary.\n\nDave"
      ~thr:"outage" ~act:true ()
  ; e ~id:"outage-003@acme.com" ~from_:"Nathan Brooks <nathan.brooks@acme.com>"
      ~to_:"Engineering <eng@acme.com>"
      ~subject:"Service restored"
      ~date:"Thu, 20 Mar 2025 03:45:00 +0000" ~irt:"<outage-002@acme.com>"
      ~body:"Restored 03:40 UTC. Downtime: 1h 22m. Secondary promoted. No data loss. Post-mortem: Friday March 21 2pm.\n\nNathan"
      ~thr:"outage" ~act:true ()
  ; e ~id:"outage-004@acme.com" ~from_:"Dave Singh <dave.singh@acme.com>"
      ~to_:"Engineering <eng@acme.com>"
      ~subject:"Post-mortem: March 20 database outage"
      ~date:"Fri, 21 Mar 2025 15:00:00 +0000" ~irt:"<outage-003@acme.com>"
      ~body:"Cause: nightly VACUUM generated 80GB WAL, filled 500GB disk. Action items:\n1. Disk to 1TB [Nathan, Mar 28]\n2. 80% disk alert [Dave, Mar 25]\n3. Incremental VACUUM [Dave, Apr 4]\n4. Failover threshold 60s [Nathan, Mar 25]\n5. WAL monitoring [Dave, Mar 28]\n\nDave"
      ~thr:"outage" ~act:true ()
  ; e ~id:"outage-005@acme.com" ~from_:"Dave Singh <dave.singh@acme.com>"
      ~to_:"Engineering <eng@acme.com>" ~cc:"Leo Mueller <leo.mueller@acme.com>"
      ~subject:"Outage action items complete"
      ~date:"Fri, 04 Apr 2025 16:00:00 +0000" ~irt:"<outage-004@acme.com>"
      ~body:"All 5 items done: disk 1TB, alert at 80%, incremental VACUUM, failover threshold 60s, WAL monitoring. Tested failover — secondary promoted in 8 seconds.\n\nDave"
      ~thr:"outage" ~act:false ()
  ]

(* ── Thread 14: Data Privacy Compliance (4 emails) ── *)
let t14 =
  [ e ~id:"privacy-001@acme.com" ~from_:"Karen Patel <karen.patel@acme.com>"
      ~to_:"Dept Heads <dept-heads@acme.com>"
      ~subject:"GDPR compliance audit — April 21"
      ~date:"Mon, 24 Mar 2025 09:00:00 +0000"
      ~body:"External GDPR audit April 21. Each dept must submit: data inventory, retention policies, processing agreements, access controls. Due April 14. Non-compliance carries significant fines.\n\nKaren"
      ~thr:"privacy" ~act:true ()
  ; e ~id:"privacy-002@acme.com" ~from_:"Olivia Zhang <olivia.zhang@acme.com>"
      ~to_:"Karen Patel <karen.patel@acme.com>"
      ~subject:"Re: GDPR audit — data inventory"
      ~date:"Fri, 04 Apr 2025 14:00:00 +0000" ~irt:"<privacy-001@acme.com>"
      ~body:"Data Science inventory: customer analytics 2.3TB (18-month retention, anonymized after 90 days), ML training (derived features only, no PII), A/B test logs (6-month, opt-out supported).\n\nOlivia"
      ~thr:"privacy" ~act:false ()
  ; e ~id:"privacy-003@acme.com" ~from_:"Eve Nowak <eve.nowak@acme.com>"
      ~to_:"Karen Patel <karen.patel@acme.com>"
      ~subject:"Re: GDPR audit — security controls"
      ~date:"Mon, 07 Apr 2025 10:00:00 +0000" ~irt:"<privacy-001@acme.com>"
      ~body:"Security controls: AES-256 at rest, TLS 1.3 in transit, access logging, MFA, quarterly reviews, updated IR plan, DPO contact info.\n\nEve"
      ~thr:"privacy" ~act:false ()
  ; e ~id:"privacy-004@acme.com" ~from_:"Karen Patel <karen.patel@acme.com>"
      ~to_:"All Staff <all@acme.com>"
      ~subject:"GDPR audit passed!"
      ~date:"Fri, 25 Apr 2025 15:00:00 +0000" ~irt:"<privacy-003@acme.com>"
      ~body:"We passed with zero findings! Auditor praised our incident response and data inventory. Certificate valid 12 months. Thanks everyone.\n\nKaren"
      ~thr:"privacy" ~act:false ()
  ]

(* ── Thread 15: Product Roadmap (4 emails) ── *)
let t15 =
  [ e ~id:"roadmap-001@acme.com" ~from_:"Leo Mueller <leo.mueller@acme.com>"
      ~to_:"Leads <leads@acme.com>"
      ~subject:"H2 product roadmap brainstorm"
      ~date:"Mon, 14 Apr 2025 09:00:00 +0000"
      ~body:"Leads,\n\nTime for H2 2025 planning. Top 3 priorities by April 21. Consider: customer feedback, competitive landscape, tech debt, new markets. Brainstorm session April 25.\n\nLeo"
      ~thr:"roadmap" ~act:true ()
  ; e ~id:"roadmap-002@acme.com" ~from_:"Alice Chen <alice.chen@acme.com>"
      ~to_:"Leo Mueller <leo.mueller@acme.com>"
      ~subject:"Re: H2 roadmap — engineering priorities"
      ~date:"Mon, 21 Apr 2025 10:00:00 +0000" ~irt:"<roadmap-001@acme.com>"
      ~body:"Top 3: 1) Real-time streaming pipeline (most requested), 2) Custom RBAC (BigCorp requirement, broadly useful), 3) Tech debt — migrate off legacy auth.\n\nAlice"
      ~thr:"roadmap" ~act:false ()
  ; e ~id:"roadmap-003@acme.com" ~from_:"Maria Santos <maria.santos@acme.com>"
      ~to_:"Leo Mueller <leo.mueller@acme.com>"
      ~subject:"Re: H2 roadmap — customer features"
      ~date:"Mon, 21 Apr 2025 14:00:00 +0000" ~irt:"<roadmap-001@acme.com>"
      ~body:"Top customer requests: 1) Custom dashboards (12 customers), 2) API rate limiting + usage analytics, 3) Multi-region deployment. Full feedback analysis attached.\n\nMaria"
      ~thr:"roadmap" ~act:false ()
  ; e ~id:"roadmap-004@acme.com" ~from_:"Leo Mueller <leo.mueller@acme.com>"
      ~to_:"All Staff <all@acme.com>"
      ~subject:"H2 2025 roadmap published"
      ~date:"Fri, 02 May 2025 10:00:00 +0000" ~irt:"<roadmap-003@acme.com>"
      ~body:"H2 roadmap: Q3 — real-time streaming + custom RBAC. Q4 — custom dashboards + multi-region + API analytics. Ongoing: legacy auth migration. Full: wiki.acme.com/roadmap-h2-2025\n\nLeo"
      ~thr:"roadmap" ~act:false ()
  ]
(* ── Standalone emails (25 emails: FYI, system, edge cases) ── *)
let standalone =
  [ (* -- Newsletters / Digests -- *)
    e ~id:"newsletter-001@acme.com" ~from_:"Engineering Digest <digest@acme.com>"
      ~to_:"Engineering <eng@acme.com>"
      ~subject:"Weekly Engineering Digest — March 10"
      ~date:"Mon, 10 Mar 2025 07:00:00 +0000"
      ~body:"This week: Phoenix kickoff, 3 PRs merged to payments, Datadog dashboard refresh. Read more: wiki.acme.com/digest/2025-w11"
      ~thr:"" ~act:false ()
  ; e ~id:"newsletter-002@acme.com" ~from_:"Company News <news@acme.com>"
      ~to_:"All Staff <all@acme.com>"
      ~subject:"Monthly Update — March 2025"
      ~date:"Fri, 28 Mar 2025 08:00:00 +0000"
      ~body:"Highlights: Phoenix on track, security incident resolved, Q2 budget finalized, BigCorp demo success, CI/CD migration underway. Welcome Priya Sharma! Spotlight: Dave Singh (10 years)."
      ~thr:"" ~act:false ()
  ; e ~id:"newsletter-003@acme.com" ~from_:"Tech Radar <radar@acme.com>"
      ~to_:"Engineering <eng@acme.com>"
      ~subject:"Tech Radar Q1 2025"
      ~date:"Mon, 31 Mar 2025 08:00:00 +0000"
      ~body:"Adopt: GitHub Actions, ArgoCD, Istio. Trial: Deno 2.0, Bun. Assess: WebAssembly, WASI. Hold: Jenkins (migration underway). Full: wiki.acme.com/tech-radar"
      ~thr:"" ~act:false ()

    (* -- System Notifications -- *)
  ; e ~id:"sysnotify-001@acme.com" ~from_:"Monitoring <monitoring@acme.com>"
      ~to_:"Ops <ops@acme.com>"
      ~subject:"[ALERT] CPU >90% on prod-web-03"
      ~date:"Wed, 12 Mar 2025 14:22:00 +0000"
      ~body:"prod-web-03 CPU at 94% for >5min. Service: api-gateway. Auto-scaling triggered. Dashboard: grafana.acme.com/d/prod-web"
      ~thr:"" ~act:false ()
  ; e ~id:"sysnotify-002@acme.com" ~from_:"CI <ci@acme.com>"
      ~to_:"Alice Chen <alice.chen@acme.com>"
      ~subject:"[FAILED] Build #4521 — payments-service"
      ~date:"Thu, 13 Mar 2025 16:45:00 +0000"
      ~body:"Build #4521 failed on feature/retry-logic. Error: test_payment_retry_exhausted — expected 3 retries, got 2. Commit: a1b2c3d. Logs: ci.acme.com/builds/4521"
      ~thr:"" ~act:true ()
  ; e ~id:"sysnotify-003@acme.com" ~from_:"Jira <jira@acme.com>"
      ~to_:"Bob Martinez <bob.martinez@acme.com>"
      ~subject:"[Jira] Sprint Review — Phoenix Sprint 3"
      ~date:"Thu, 17 Apr 2025 09:00:00 +0000"
      ~body:"Reminder: Sprint Review today 3pm. 12 stories done, 2 in progress, 1 blocked. Velocity: 34 pts (target 30)."
      ~thr:"" ~act:false ()

    (* -- FYI Forwards -- *)
  ; e ~id:"fwd-001@acme.com" ~from_:"Leo Mueller <leo.mueller@acme.com>"
      ~to_:"Alice Chen <alice.chen@acme.com>"
      ~subject:"FWD: Gartner cloud migration trends"
      ~date:"Tue, 11 Mar 2025 15:00:00 +0000"
      ~body:"Thought this is relevant for Phoenix.\n\n--- Forwarded ---\n73% of enterprises plan k8s migration by 2026. Top challenges: observability (41%), security (38%), skill gaps (35%)."
      ~thr:"" ~act:false ()
  ; e ~id:"fwd-002@acme.com" ~from_:"Frank O'Brien <frank.obrien@acme.com>"
      ~to_:"Sales <sales@acme.com>"
      ~subject:"FWD: Competitor launched new analytics tier"
      ~date:"Wed, 19 Mar 2025 11:00:00 +0000"
      ~body:"FYI — CompetitorX launched analytics at $299/mo (we charge $499). Their real-time features still behind ours.\n\n--- Forwarded from TechCrunch ---\nCompetitorX announces Analytics Pro..."
      ~thr:"" ~act:false ()
  ; e ~id:"fwd-003@acme.com" ~from_:"Hiro Tanaka <hiro.tanaka@acme.com>"
      ~to_:"Olivia Zhang <olivia.zhang@acme.com>"
      ~subject:"FWD: Interesting talk on transformers"
      ~date:"Fri, 14 Mar 2025 10:00:00 +0000"
      ~body:"Relevant to our paper.\n\n--- Forwarded ---\nNeurIPS talk: \"Efficient Transformers for Time-Series\" by Prof. Kim (Stanford). 3x inference speedup with sparse attention."
      ~thr:"" ~act:false ()

    (* -- Meeting Invites -- *)
  ; e ~id:"meeting-001@acme.com" ~from_:"Maria Santos <maria.santos@acme.com>"
      ~to_:"Engineering <eng@acme.com>"
      ~subject:"Engineering standup — recurring March 3"
      ~date:"Fri, 28 Feb 2025 14:00:00 +0000"
      ~body:"Daily standup at 9:30am in #eng-standup (Slack huddle). 15min max. Format: done/doing/blocked. If absent, post async by 10am.\n\nMaria"
      ~thr:"" ~act:false ()
  ; e ~id:"meeting-002@acme.com" ~from_:"Carol Wu <carol.wu@acme.com>"
      ~to_:"Dept Heads <dept-heads@acme.com>"
      ~subject:"Board meeting prep — April 8"
      ~date:"Mon, 31 Mar 2025 09:00:00 +0000"
      ~body:"Board meeting April 8. Each dept: Q1 summary (1 slide), Q2 plans (1 slide), key risks (1 slide). Submit by April 4.\n\nCarol"
      ~thr:"" ~act:true ()

    (* -- Random / Misc -- *)
  ; e ~id:"misc-001@acme.com" ~from_:"Alice Chen <alice.chen@acme.com>"
      ~to_:"Bob Martinez <bob.martinez@acme.com>"
      ~subject:"Quick question about test coverage"
      ~date:"Mon, 24 Mar 2025 16:00:00 +0000"
      ~body:"Bob, what's our test coverage for payments service? Thinking 85% minimum target for all Phoenix-migrated services.\n\nAlice"
      ~thr:"" ~act:true ()
  ; e ~id:"misc-002@acme.com" ~from_:"Jake Reeves <jake.reeves@acme.com>"
      ~to_:"Alice Chen <alice.chen@acme.com>"
      ~subject:"Customer feature request compilation"
      ~date:"Fri, 21 Mar 2025 14:00:00 +0000"
      ~body:"Top 5 feature requests this quarter: 1) Bulk import (32 requests), 2) Report scheduling (28), 3) Slack integration (24), 4) 2FA for API keys (19), 5) Dark mode (17).\n\nJake"
      ~thr:"" ~act:false ()
  ; e ~id:"misc-003@acme.com" ~from_:"Nathan Brooks <nathan.brooks@acme.com>"
      ~to_:"Dave Singh <dave.singh@acme.com>"
      ~subject:"Server rack expansion proposal"
      ~date:"Tue, 25 Mar 2025 10:00:00 +0000"
      ~body:"With Phoenix + BigCorp EU, need 2 more racks us-east-2 and 1 eu-west-1. CloudHost can provision by end of April if we request by March 31. Budget included in new contract.\n\nNathan"
      ~thr:"" ~act:true ()

    (* -- Non-ASCII / International -- *)
  ; e ~id:"intl-001@acme.com"
      ~from_:"=?UTF-8?B?TMOpbyBNw7xsbGVy?= <leo.mueller@acme.com>"
      ~to_:"Engineering <eng@acme.com>"
      ~subject:"=?UTF-8?B?QsO8cm8tVXBkYXRlIGF1cyBNw7xuY2hlbg==?="
      ~date:"Mon, 17 Mar 2025 09:00:00 +0000"
      ~body:"Hallo zusammen,\n\nKurzes Update aus dem Muenchen-Buero: neue Auth-API fertiggestellt. Doku auf Englisch im Wiki. Performance: 40% besser als altes System.\n\nGruesse, Leo"
      ~thr:"" ~act:false ()
  ; e ~id:"intl-002@acme.com" ~from_:"Tokyo Office <tokyo@acme.co.jp>"
      ~to_:"All Staff <all@acme.com>"
      ~subject:"=?UTF-8?B?5p2x5Lqs44Kq44OV44Kj44K544GL44KJ44Gu5pu05paw?="
      ~date:"Tue, 18 Mar 2025 02:00:00 +0000"
      ~body:"Tokyo update: 3 new enterprise clients in Japan this quarter. Combined ARR: 45M JPY (~$300K). Japanese dashboard localization 80% complete."
      ~thr:"" ~act:false ()
  ; e ~id:"intl-003@acme.com"
      ~from_:"=?UTF-8?Q?Maria_Gon=C3=A7alves?= <maria.g@acme.com.br>"
      ~to_:"Frank O'Brien <frank.obrien@acme.com>"
      ~subject:"=?UTF-8?B?QXR1YWxpemHDp8OjbyBkbyBwcm9qZXRvIEJyYXNpbA==?="
      ~date:"Wed, 19 Mar 2025 13:00:00 +0000"
      ~body:"Brazil project: LGPD regulatory approval received. Can onboard Brazilian customers. 3 prospects in pipeline: R$800K (~$160K). Meetings scheduled April.\n\nMaria G."
      ~thr:"" ~act:true ()

    (* -- Long body for multi-chunk testing -- *)
  ; e ~id:"longbody-001@acme.com" ~from_:"Olivia Zhang <olivia.zhang@acme.com>"
      ~to_:"Engineering <eng@acme.com>"
      ~subject:"ML model evaluation report — Q1 2025"
      ~date:"Fri, 28 Mar 2025 14:00:00 +0000"
      ~body:"QUARTERLY ML MODEL EVALUATION REPORT — Q1 2025\n\n\
1. EXECUTIVE SUMMARY\n\
We evaluated 7 models across 4 use cases. Overall accuracy improved 12% over Q4.\n\n\
2. ANOMALY DETECTION\n\
Model: AttentionDecomp v2.1 — F1 0.94 on production data (450K events Jan-Mar).\n\
Compared vs SPOT (0.87), SR (0.89), USAD (0.91). Our model wins on latency too: 2.3ms/event vs 8.1ms.\n\n\
3. RECOMMENDATION ENGINE\n\
Model: CollabFilter v3 — precision@10 of 0.71 (target: 0.75). Needs more training data.\n\
Cold-start problem persists for new users. Exploring hybrid approach with content features.\n\n\
4. CHURN PREDICTION\n\
Model: GradientBoost v2 — AUC 0.89 (up from 0.84). Top features: login frequency, support tickets, \
feature adoption rate. 30-day prediction window. Model correctly flagged 3 of 4 actual churns in Q1.\n\n\
5. SEARCH RELEVANCE\n\
Model: BM25 + reranker — NDCG@10 of 0.82. Semantic reranker adds 0.07 NDCG over BM25 alone.\n\
Latency: 45ms median, 120ms p99 (within SLA). Index contains 2.1M documents.\n\n\
6. INFRASTRUCTURE\n\
Training costs: $3,200/month (GPU compute). Inference: $890/month. Total: $4,090/month.\n\
Model registry: 23 models versioned, 7 in production, automated A/B deployment pipeline.\n\n\
7. Q2 PRIORITIES\n\
- Improve recommendation engine (target p@10 0.75)\n\
- Deploy AttentionDecomp to production monitoring\n\
- Explore LLM-based search for Q3\n\
- Reduce inference latency for churn model\n\n\
8. APPENDIX: DETAILED METRICS\n\
Per-model breakdown with confusion matrices, ROC curves, and calibration plots available in the \
ML dashboard: ml.acme.com/q1-2025-eval. Raw experiment logs in MLflow.\n\n\
Olivia Zhang\nHead of Data Science"
      ~thr:"" ~act:false ()
  ; e ~id:"longbody-002@acme.com" ~from_:"Dave Singh <dave.singh@acme.com>"
      ~to_:"Engineering <eng@acme.com>"
      ~subject:"Infrastructure audit Q1 2025"
      ~date:"Mon, 31 Mar 2025 10:00:00 +0000"
      ~body:"INFRASTRUCTURE AUDIT — Q1 2025\n\n\
1. COMPUTE RESOURCES\n\
Production cluster: 48 nodes (expanded from 36 for Phoenix). Average utilization: 62%.\n\
Staging: 12 nodes. Development: 8 nodes. Total monthly compute: $28,400.\n\n\
2. DATABASE\n\
Primary PostgreSQL: 1TB disk (upgraded from 500GB post-outage). 340GB used.\n\
Replica lag: <1s average (improved from 3-5s). Connections: 180 avg, 420 peak.\n\
Redis: 3-node cluster, 12GB/node. Hit rate: 94%. Eviction rate: <0.1%.\n\n\
3. NETWORKING\n\
Bandwidth: 2.4TB/month outbound. CDN offloads 78% of static assets.\n\
Inter-service latency: 1.2ms median (Istio mesh). External API: 45ms median.\n\n\
4. SECURITY POSTURE\n\
Post-incident improvements: MFA 100%, VPN-only admin, rate limiting, Cloudflare Access.\n\
Vulnerability scan: 0 critical, 2 high (patched), 7 medium (scheduled Q2).\n\
Certificate management: automated via cert-manager. 0 expirations in Q1.\n\n\
5. COST ANALYSIS\n\
Total infra spend: $42,800/month. Breakdown: compute $28,400, database $6,200, \
networking $3,100, monitoring $2,800, security tools $2,300.\n\
QoQ change: +18% (Phoenix expansion). Per-customer cost: $8.56 (target: <$10).\n\n\
6. RELIABILITY\n\
Uptime: 99.94% (1h 22m outage on March 20). SLA target: 99.99%.\n\
Mean time to recovery: 82 minutes (target: <30min — action item from post-mortem).\n\
Incidents: 1 major (DB outage), 3 minor (auto-resolved by scaling).\n\n\
7. RECOMMENDATIONS\n\
- Complete Phoenix migration to reduce legacy infrastructure costs\n\
- Implement chaos engineering for Q2 (Litmus)\n\
- Evaluate spot instances for non-critical workloads (est. 30% savings)\n\
- Multi-region DR plan (required for BigCorp EU)\n\n\
Dave Singh\nHead of DevOps"
      ~thr:"" ~act:false ()

    (* -- HTML-only emails -- *)
  ; e ~id:"html-001@acme.com" ~from_:"Marketing Auto <marketing@acme.com>"
      ~to_:"All Staff <all@acme.com>"
      ~subject:"New product features — April 2025"
      ~date:"Tue, 01 Apr 2025 09:00:00 +0000"
      ~body:"<html><body><h1>April Product Update</h1><p>We shipped <b>3 major features</b> this month:</p><ul><li>Real-time analytics dashboard</li><li>Webhook configuration UI</li><li>Improved search with semantic reranking</li></ul><p>Read the full release notes at <a href='https://docs.acme.com/releases/april-2025'>docs.acme.com</a>.</p></body></html>"
      ~thr:"" ~act:false ()
  ; e ~id:"html-002@acme.com" ~from_:"HR System <hr-system@acme.com>"
      ~to_:"All Staff <all@acme.com>"
      ~subject:"Benefits enrollment reminder"
      ~date:"Mon, 14 Apr 2025 08:00:00 +0000"
      ~body:"<html><body><h2>Open Enrollment Closes April 30</h2><p>Don't forget to review and update your benefits selections.</p><table border='1'><tr><th>Plan</th><th>Monthly Cost</th></tr><tr><td>Medical - PPO</td><td>$150</td></tr><tr><td>Medical - HMO</td><td>$95</td></tr><tr><td>Dental</td><td>$25</td></tr><tr><td>Vision</td><td>$12</td></tr></table><p><a href='https://benefits.acme.com'>Enroll now</a></p></body></html>"
      ~thr:"" ~act:true ()

    (* -- Large CC lists -- *)
  ; e ~id:"bigcc-001@acme.com" ~from_:"Leo Mueller <leo.mueller@acme.com>"
      ~to_:"All Staff <all@acme.com>"
      ~cc:"Alice Chen <alice.chen@acme.com>, Bob Martinez <bob.martinez@acme.com>, Carol Wu <carol.wu@acme.com>, Dave Singh <dave.singh@acme.com>, Eve Nowak <eve.nowak@acme.com>, Frank O'Brien <frank.obrien@acme.com>, Grace Kim <grace.kim@acme.com>, Hiro Tanaka <hiro.tanaka@acme.com>, Irene Costa <irene.costa@acme.com>, Jake Reeves <jake.reeves@acme.com>, Karen Patel <karen.patel@acme.com>, Maria Santos <maria.santos@acme.com>, Nathan Brooks <nathan.brooks@acme.com>, Olivia Zhang <olivia.zhang@acme.com>, Priya Sharma <priya.sharma@acme.com>"
      ~subject:"Company-wide policy update — remote work"
      ~date:"Mon, 07 Apr 2025 09:00:00 +0000"
      ~body:"Effective May 1: updated remote work policy. 3 days in-office minimum (Tue/Wed/Thu). Exceptions require VP approval. Full policy: wiki.acme.com/remote-policy-2025\n\nLeo"
      ~thr:"" ~act:false ()

    (* -- Vendor outreach (external sender) -- *)
  ; e ~id:"vendor-001@cloudhost.io" ~from_:"Sales <sales@cloudhost.io>"
      ~to_:"Karen Patel <karen.patel@acme.com>"
      ~subject:"CloudHost Q2 promotional offer"
      ~date:"Wed, 02 Apr 2025 10:00:00 +0000"
      ~body:"Karen,\n\nAs a valued CloudHost customer, we'd like to offer a 15% discount on GPU instance reservations if committed before April 30. This applies to A100 and H100 instances.\n\nLet me know if you'd like to discuss.\n\nBest, CloudHost Sales"
      ~thr:"" ~act:false ()

    (* -- Empty / minimal body -- *)
  ; e ~id:"minimal-001@acme.com" ~from_:"Alice Chen <alice.chen@acme.com>"
      ~to_:"Bob Martinez <bob.martinez@acme.com>"
      ~subject:"Lunch?"
      ~date:"Tue, 18 Mar 2025 11:30:00 +0000"
      ~body:""
      ~thr:"" ~act:false ()

    (* -- Wiki update notification -- *)
  ; e ~id:"wiki-001@acme.com" ~from_:"Wiki Bot <wiki@acme.com>"
      ~to_:"Engineering <eng@acme.com>"
      ~subject:"[Wiki] Updated: Phoenix Migration Runbook"
      ~date:"Fri, 25 Apr 2025 11:00:00 +0000"
      ~body:"Dave Singh updated the Phoenix Migration Runbook. Changes: added rollback decision tree, updated service dependency map, added monitoring dashboard links. View: wiki.acme.com/phoenix-runbook"
      ~thr:"" ~act:false ()
  ]

let emails =
  t01 @ t02 @ t03 @ t04 @ t05 @ t06 @ t07
  @ t08 @ t09 @ t10 @ t11 @ t12 @ t13 @ t14 @ t15
  @ standalone
