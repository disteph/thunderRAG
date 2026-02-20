# ThunderRAG Quality Test Harness

A test harness that bypasses Thunderbird and the add-on to interact directly with the OCaml server endpoints. It ingests a synthetic email corpus, runs a suite of queries through the full 3-phase query flow, and produces detailed reports for qualitative review.

## Overview

The harness exercises the same endpoints the Thunderbird add-on uses:

1. **Reset** — wipes the vector index and ingestion ledger (`/admin/reset_index`, `/admin/reset_sessions`)
2. **Ingest** — sends each synthetic email as RFC822 via `POST /ingest`
3. **Mark processed** — marks all ingested emails via `POST /admin/mark_processed`
4. **Query** — for each test case, runs the 3-phase flow:
   - `POST /query` → returns retrieved source `message_id`s
   - `POST /query/evidence` × N → uploads the RFC822 body for each retrieved email
   - `POST /query/complete` → triggers the LLM chat answer
5. **Session debug** — fetches session state via `POST /admin/session_debug` to inspect the tail and history summary
6. **Analyze** — runs qualitative anomaly detection and numeric scoring on every result
7. **Report** — saves `results.json`, `summary.txt`, and optionally an HTML report

## Files

| File | Purpose |
|---|---|
| `corpus.json` | 16 synthetic RFC822 emails (threads, attachments, urgency, deadlines, cross-references) |
| `test_cases.json` | 15 test cases with questions, session groups, dependencies, and scoring criteria |
| `test_quality.py` | Main harness script — reset, ingest, query, analyze, report |
| `render_report.py` | Generates a standalone HTML report from a run's `results.json` |
| `runs/<timestamp>/` | Output directory for each run |

## Prerequisites

Three services must be running:

1. **Ollama** with the configured embed + chat models pulled
2. **python-engine** (vector index)
3. **OCaml server** (main RAG server)

## Step-by-step

### 1. Start Ollama

```bash
ollama serve
```

### 2. Start the python-engine

```bash
cd python-engine
source .venv/bin/activate          # or create: python -m venv .venv && pip install -r requirements.txt
uvicorn app:app --port 8000
```

### 3. Start the OCaml server with debug logging

The debug environment variables make the server print all LLM responses and retrieval details to stdout — useful for diagnosing issues.

```bash
cd ocaml-server
RAG_DEBUG_OLLAMA_CHAT=1 RAG_DEBUG_RETRIEVAL=1 dune exec -- rag-email-server -p 8080
```

To capture the server log for inclusion in the run output:

```bash
RAG_DEBUG_OLLAMA_CHAT=1 RAG_DEBUG_RETRIEVAL=1 dune exec -- rag-email-server -p 8080 2>&1 | tee /tmp/rag-server.log
```

### 4. Run the harness

```bash
cd ocaml-server/tests

# Full run: reset → ingest → query all test cases
python test_quality.py

# Include the server log in the run directory
python test_quality.py --server-log /tmp/rag-server.log

# Skip reset+ingest (reuse data from a previous run, only re-run queries)
python test_quality.py --skip-ingest

# Use a different server URL
python test_quality.py --base-url http://localhost:9090
```

The harness takes ~5–10 minutes depending on the LLM model speed. Progress is printed to stdout as it goes.

### 5. View the results

Each run creates a timestamped directory under `runs/`:

```
runs/20260220_135832/
├── results.json      # Full structured output (all responses, sources, session state)
├── summary.txt       # Human-readable report with anomalies and scores
└── report.html       # (after render_report.py) Visual HTML report
```

#### Generate the HTML report

```bash
# Render the latest run
python render_report.py

# Render a specific run
python render_report.py runs/20260220_135832
```

Then open `runs/<timestamp>/report.html` in a browser. It has:

- **Left sidebar** — all test cases with score badges, clickable to jump
- **User/assistant bubbles** — styled like the ThunderRAG addon chat UI
- **Collapsible Sources** — email cards with metadata and relevance scores
- **Answer text** — with `[Email N]` citations highlighted
- **Anomaly badges** — orange warnings for detected issues
- **Collapsible Session tail** — full conversation state as the server sees it
- **Score pills** — per-criterion pass/fail breakdown

## What the harness checks

### Qualitative anomalies (automatic)

- **Citation out of range** — `[Email 5]` when only 3 sources exist
- **Citation mismatch** — answer cites `[Email 2, 3]` but the `EMAILS REFERENCED ABOVE` section lists different numbers
- **Missing reference section** — answer has citations but the session tail lacks the email index
- **Answer too short / too long** — suspiciously terse or verbose responses
- **Hallucinated names** — first names appearing in the answer that don't exist in the corpus
- **Malformed sources** — missing `doc_id` or non-dict source entries

### Numeric scoring (per test case criteria)

Each test case in `test_cases.json` defines criteria:

| Criterion | What it checks |
|---|---|
| `must_contain_any` | Answer includes at least one of these keywords |
| `must_not_contain` | Answer does not include any of these keywords |
| `must_cite_emails` | Answer contains `[Email N]` references |
| `expected_email_subjects_any` | At least one expected email appears in retrieved sources |
| `hallucination_keywords` | Answer doesn't affirm the presence of fabricated topics |

The overall score is the average of all applicable criteria (0.0–1.0).

## Iterating

The typical workflow:

1. Run the harness → review `report.html`
2. Identify issues (bad retrieval, wrong citations, hallucinations, etc.)
3. Edit prompts in `~/.thunderRAG/prompts.json` (hot-reloadable, no server restart needed)  
   — or fix OCaml server logic and rebuild
4. Re-run: `python test_quality.py --skip-ingest` (fast, skips re-ingestion)
5. Compare before/after in the HTML reports
