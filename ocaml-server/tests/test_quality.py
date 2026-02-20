#!/usr/bin/env python3
"""
ThunderRAG Quality Test Harness

Bypasses Thunderbird entirely. Ingests a synthetic email corpus, runs a battery
of test questions through the full 3-phase query flow, collects every
intermediate artefact, performs qualitative anomaly detection, and optionally
scores answers against criteria.

Usage:
    python test_quality.py                             # single run
    python test_quality.py --server-log /tmp/server.log  # include server log in output
    python test_quality.py --base-url http://localhost:9090

Requires: OCaml server + python-engine + Ollama running.
"""

import argparse
import json
import os
import re
import shutil
import sys
import time
from datetime import datetime
from pathlib import Path

import requests

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
CORPUS_PATH = SCRIPT_DIR / "corpus.json"
TEST_CASES_PATH = SCRIPT_DIR / "test_cases.json"
RUNS_DIR = SCRIPT_DIR / "runs"

DEFAULT_BASE_URL = "http://localhost:8080"
INGEST_TIMEOUT = 120
QUERY_TIMEOUT = 60
EVIDENCE_TIMEOUT = 30
COMPLETE_TIMEOUT = 300


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def load_json(path):
    with open(path) as f:
        return json.load(f)


def post(base_url, path, **kwargs):
    """POST with defaults."""
    kwargs.setdefault("timeout", 30)
    return requests.post(base_url + path, **kwargs)


def make_run_dir():
    """Create a timestamped run directory."""
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    d = RUNS_DIR / ts
    d.mkdir(parents=True, exist_ok=True)
    return d


# ---------------------------------------------------------------------------
# Phase 0: Reset
# ---------------------------------------------------------------------------

def reset_index(base_url):
    """Reset the vector index and OCaml ingestion ledger."""
    print("[reset] Resetting vector index and ingestion ledger...")
    r = post(base_url, "/admin/reset", json={})
    if r.status_code != 200:
        print(f"  WARNING: /admin/reset returned {r.status_code}: {r.text[:200]}")
        return False
    print(f"  OK: {r.json()}")
    return True


def reset_session(base_url, session_id):
    r = post(base_url, "/admin/session/reset", json={"session_id": session_id})
    return r.status_code == 200


# ---------------------------------------------------------------------------
# Phase 1: Ingest corpus
# ---------------------------------------------------------------------------

def ingest_corpus(base_url, corpus):
    """Ingest all emails from the corpus. Returns dict of message_id -> rfc822."""
    emails = corpus["emails"]
    corpus_by_mid = {}
    print(f"\n[ingest] Ingesting {len(emails)} emails...")
    for i, email in enumerate(emails):
        mid = email["message_id"]
        rfc822 = email["rfc822"]
        corpus_by_mid[mid] = rfc822

        r = post(
            base_url, "/ingest",
            data=rfc822.encode("utf-8"),
            headers={
                "Content-Type": "message/rfc822",
                "X-Thunderbird-Message-Id": mid,
            },
            timeout=INGEST_TIMEOUT,
        )
        status = "OK" if r.status_code == 200 else f"FAIL({r.status_code})"
        print(f"  [{i+1}/{len(emails)}] {status} {email['id']} ({mid})")
        if r.status_code != 200:
            print(f"    Response: {r.text[:300]}")

    # Mark processed emails
    for email in emails:
        if email.get("mark_processed"):
            mid = email["message_id"]
            r = post(base_url, "/admin/mark_processed", json={"id": mid})
            print(f"  mark_processed {email['id']}: {r.status_code}")

    return corpus_by_mid


# ---------------------------------------------------------------------------
# Phase 2: Run test cases
# ---------------------------------------------------------------------------

def run_query_flow(base_url, session_id, question, user_name, corpus_by_mid):
    """Execute the full 3-phase query flow. Returns a dict of all artefacts."""
    result = {
        "question": question,
        "session_id": session_id,
        "user_name": user_name,
        "query_response": None,
        "evidence_uploads": [],
        "complete_response": None,
        "session_debug": None,
        "error": None,
    }

    # Phase 1: /query
    try:
        r1 = post(
            base_url, "/query",
            json={
                "session_id": session_id,
                "question": question,
                "user_name": user_name,
                "top_k": 5,
            },
            timeout=QUERY_TIMEOUT,
        )
    except Exception as e:
        result["error"] = f"Phase 1 (/query) failed: {e}"
        return result

    if r1.status_code != 200:
        result["error"] = f"Phase 1 (/query) returned {r1.status_code}: {r1.text[:300]}"
        return result

    q = r1.json()
    result["query_response"] = q

    if q.get("status") != "need_messages":
        result["error"] = f"Unexpected /query status: {q.get('status')}"
        return result

    request_id = q["request_id"]
    message_ids = q["message_ids"]

    # Phase 2: /query/evidence for each message_id
    for mid in message_ids:
        if mid in corpus_by_mid:
            rfc822 = corpus_by_mid[mid]
        else:
            # Try bracket variations
            bare = mid.strip("<>")
            bracketed = f"<{bare}>" if not mid.startswith("<") else mid
            rfc822 = corpus_by_mid.get(bracketed) or corpus_by_mid.get(bare)
            if rfc822 is None:
                # Synthesize a placeholder
                rfc822 = (
                    f"From: unknown@example.com\r\n"
                    f"To: bob@acme.com\r\n"
                    f"Subject: (placeholder - not in test corpus)\r\n"
                    f"Message-Id: {mid}\r\n"
                    f"Date: Mon, 01 Jan 2025 00:00:00 +0000\r\n"
                    f"MIME-Version: 1.0\r\n"
                    f"Content-Type: text/plain; charset=UTF-8\r\n"
                    f"\r\n"
                    f"No content available for this message."
                )
                print(f"    WARNING: message_id {mid} not in corpus, using placeholder")

        try:
            r2 = post(
                base_url, "/query/evidence",
                data=rfc822.encode("utf-8"),
                headers={
                    "Content-Type": "message/rfc822",
                    "X-RAG-Request-Id": request_id,
                    "X-Thunderbird-Message-Id": mid,
                },
                timeout=EVIDENCE_TIMEOUT,
            )
            result["evidence_uploads"].append({
                "message_id": mid,
                "status": r2.status_code,
            })
        except Exception as e:
            result["evidence_uploads"].append({
                "message_id": mid,
                "status": -1,
                "error": str(e),
            })

    # Phase 3: /query/complete
    try:
        r3 = post(
            base_url, "/query/complete",
            json={"session_id": session_id, "request_id": request_id},
            timeout=COMPLETE_TIMEOUT,
        )
    except Exception as e:
        result["error"] = f"Phase 3 (/query/complete) failed: {e}"
        return result

    if r3.status_code != 200:
        result["error"] = f"Phase 3 returned {r3.status_code}: {r3.text[:300]}"
        return result

    result["complete_response"] = r3.json()

    # Capture session debug
    try:
        r_debug = post(
            base_url, "/admin/session/debug",
            json={"session_id": session_id},
            timeout=10,
        )
        if r_debug.status_code == 200:
            result["session_debug"] = r_debug.json()
    except Exception:
        pass

    return result


def run_all_test_cases(base_url, test_cases, corpus_by_mid):
    """Run all test cases, respecting depends_on ordering."""
    cases = test_cases["cases"]
    user_name = test_cases.get("user_name", "")
    results = []

    # Build dependency graph
    completed_cases = {}  # id -> result

    print(f"\n[test] Running {len(cases)} test cases...")
    for i, tc in enumerate(cases):
        tc_id = tc["id"]
        session_group = tc.get("session_group", f"session_{tc_id}")
        depends_on = tc.get("depends_on")

        # If this case depends on another, make sure it already ran
        if depends_on and depends_on not in completed_cases:
            print(f"  SKIP {tc_id}: dependency {depends_on} not completed")
            results.append({"test_id": tc_id, "skipped": True, "reason": f"dependency {depends_on} not met"})
            continue

        print(f"\n  [{i+1}/{len(cases)}] {tc_id} ({tc['category']})")
        print(f"    Q: {tc['question']}")

        session_id = f"quality-test-{session_group}"

        result = run_query_flow(base_url, session_id, tc["question"], user_name, corpus_by_mid)
        result["test_id"] = tc_id
        result["category"] = tc["category"]
        result["criteria"] = tc.get("criteria", {})

        if result.get("error"):
            print(f"    ERROR: {result['error']}")
        else:
            answer = result["complete_response"].get("answer", "")
            answer_preview = answer[:150].replace("\n", " ")
            print(f"    A: {answer_preview}...")
            n_sources = len(result["query_response"].get("sources", []))
            n_mids = len(result["query_response"].get("message_ids", []))
            print(f"    Sources: {n_sources}, Message IDs: {n_mids}")

        results.append(result)
        completed_cases[tc_id] = result

    return results


# ---------------------------------------------------------------------------
# Qualitative Analysis
# ---------------------------------------------------------------------------

def extract_citations(text):
    """Extract all [Email N] references from text. Returns list of ints."""
    return [int(m) for m in re.findall(r"\[Email\s+(\d+)\]", text)]


def analyze_result(result, corpus):
    """Perform qualitative analysis on a single test result. Returns list of anomaly strings."""
    anomalies = []
    tc_id = result.get("test_id", "?")

    if result.get("skipped") or result.get("error"):
        if result.get("error"):
            anomalies.append(f"EXECUTION ERROR: {result['error']}")
        return anomalies

    complete = result.get("complete_response", {})
    query_resp = result.get("query_response", {})
    session_debug = result.get("session_debug", {})
    answer = complete.get("answer", "")
    sources = complete.get("sources", [])
    n_sources = len(sources)

    # --- Citation consistency ---
    cited_nums = extract_citations(answer)
    if cited_nums:
        max_cited = max(cited_nums)
        if max_cited > n_sources:
            anomalies.append(
                f"CITATION OUT OF RANGE: Answer cites [Email {max_cited}] but only {n_sources} sources returned"
            )
        for n in cited_nums:
            if n < 1:
                anomalies.append(f"CITATION INVALID: [Email {n}] — must be >= 1")

    # Check for duplicate citation numbers that shouldn't exist
    # (not necessarily an anomaly, but worth noting)

    # --- Session tail inspection ---
    tail = session_debug.get("tail", [])
    assistant_msgs = [m for m in tail if m.get("role") == "assistant"]
    if assistant_msgs:
        last_assistant = assistant_msgs[-1]["content"]

        # Check EMAILS REFERENCED ABOVE section
        if "EMAILS REFERENCED ABOVE:" in last_assistant:
            ref_section = last_assistant.split("EMAILS REFERENCED ABOVE:\n", 1)[-1]
            ref_lines = [l for l in ref_section.strip().split("\n") if l.strip()]
            ref_nums = extract_citations("\n".join(ref_lines))

            # The referenced emails should match the citations in the answer
            answer_part = last_assistant.split("EMAILS REFERENCED ABOVE:")[0]
            answer_cited = extract_citations(answer_part)

            if answer_cited:
                answer_cited_set = set(answer_cited)
                ref_nums_set = set(ref_nums)

                if answer_cited_set != ref_nums_set:
                    anomalies.append(
                        f"CITATION MISMATCH: Answer cites {sorted(answer_cited_set)} "
                        f"but EMAILS REFERENCED ABOVE lists {sorted(ref_nums_set)}"
                    )

            # Check metadata completeness in referenced section
            for line in ref_lines:
                if not re.search(r"date=", line):
                    anomalies.append(f"MISSING METADATA: No 'date=' in referenced email line: {line[:100]}")
                if not re.search(r"from=", line):
                    anomalies.append(f"MISSING METADATA: No 'from=' in referenced email line: {line[:100]}")
                if not re.search(r"subject=", line):
                    anomalies.append(f"MISSING METADATA: No 'subject=' in referenced email line: {line[:100]}")

        elif cited_nums:
            anomalies.append(
                "MISSING REFERENCE SECTION: Answer has citations but no EMAILS REFERENCED ABOVE in session tail"
            )

        # Check session tail size
        if len(last_assistant) > 10000:
            anomalies.append(
                f"LARGE ASSISTANT MESSAGE: {len(last_assistant)} chars in session tail"
            )

    # --- Empty / trivial answer ---
    if len(answer.strip()) < 10:
        anomalies.append(f"ANSWER TOO SHORT: only {len(answer.strip())} chars")

    if len(answer) > 5000:
        anomalies.append(f"ANSWER VERY LONG: {len(answer)} chars")

    # --- Source ordering ---
    # Check that sources have doc_id and basic structure
    for i, src in enumerate(sources):
        if isinstance(src, dict):
            if "doc_id" not in src and "metadata" not in src:
                anomalies.append(f"SOURCE {i} MALFORMED: missing doc_id and metadata")
        else:
            anomalies.append(f"SOURCE {i} NOT A DICT: {type(src)}")

    # --- Hallucination detection (against corpus) ---
    # Check for fabricated email subjects or senders not in corpus
    corpus_senders = set()
    corpus_subjects = set()
    for email in corpus["emails"]:
        rfc822 = email["rfc822"]
        for line in rfc822.split("\r\n"):
            if line.lower().startswith("from:"):
                corpus_senders.add(line.split(":", 1)[1].strip().lower())
            if line.lower().startswith("subject:"):
                corpus_subjects.add(line.split(":", 1)[1].strip().lower())

    # Look for quoted names in the answer that aren't in the corpus
    # Use word-boundary matching to avoid false positives (e.g. 'tom' in 'customer')
    answer_lower = answer.lower()
    fabricated_names = []
    for name in ["john", "jane", "mike", "sarah", "tom", "jennifer", "james", "mary"]:
        if re.search(r"\b" + re.escape(name) + r"\b", answer_lower) and not any(name in s for s in corpus_senders):
            fabricated_names.append(name)
    if fabricated_names:
        anomalies.append(f"POSSIBLE HALLUCINATED NAMES: {fabricated_names}")

    return anomalies


def score_result(result):
    """Compute numeric scores for a test result against its criteria."""
    if result.get("skipped") or result.get("error"):
        return {"overall": 0.0, "details": "skipped or error"}

    criteria = result.get("criteria", {})
    complete = result.get("complete_response", {})
    answer_raw = complete.get("answer", "")
    answer_lower = answer_raw.lower()
    sources = complete.get("sources", [])
    scores = {}

    # must_contain_any
    must_contain = criteria.get("must_contain_any", [])
    if must_contain:
        found = any(kw.lower() in answer_lower for kw in must_contain)
        scores["must_contain"] = 1.0 if found else 0.0
    else:
        scores["must_contain"] = 1.0

    # must_not_contain
    must_not = criteria.get("must_not_contain", [])
    if must_not:
        clean = all(kw.lower() not in answer_lower for kw in must_not)
        scores["must_not_contain"] = 1.0 if clean else 0.0
    else:
        scores["must_not_contain"] = 1.0

    # citation check (use original case since regex is case-sensitive)
    if criteria.get("must_cite_emails"):
        cited = extract_citations(answer_raw)
        scores["has_citations"] = 1.0 if cited else 0.0

        # Check citations are in range
        n_sources = len(sources)
        if cited and n_sources > 0:
            valid = all(1 <= n <= n_sources for n in cited)
            scores["citations_valid"] = 1.0 if valid else 0.0
        else:
            scores["citations_valid"] = 1.0 if not cited else 0.0
    else:
        scores["has_citations"] = 1.0
        scores["citations_valid"] = 1.0

    # expected subjects
    expected_subjects = criteria.get("expected_email_subjects_any", [])
    if expected_subjects and sources:
        source_subjects = []
        for src in sources:
            if isinstance(src, dict):
                md = src.get("metadata", {})
                if isinstance(md, dict):
                    subj = md.get("subject", "")
                    source_subjects.append(subj.lower())
        found_subj = any(
            any(exp.lower() in s for s in source_subjects)
            for exp in expected_subjects
        )
        scores["expected_sources"] = 1.0 if found_subj else 0.0
    else:
        scores["expected_sources"] = 1.0

    # hallucination keywords — only flag if answer *affirms* them
    # (skip if answer negates them, e.g. "no emails about Mars")
    halluc_kws = criteria.get("hallucination_keywords", [])
    if halluc_kws:
        negation_pattern = re.compile(r"(no|not|none|don't|doesn't|couldn't|no relevant|never)\b", re.IGNORECASE)
        has_negation = bool(negation_pattern.search(answer_raw))
        if has_negation:
            # Answer is a denial — don't penalize for mentioning the keyword
            scores["no_hallucination"] = 1.0
        else:
            no_halluc = all(kw.lower() not in answer_lower for kw in halluc_kws)
            scores["no_hallucination"] = 1.0 if no_halluc else 0.0
    else:
        scores["no_hallucination"] = 1.0

    # Overall: simple average
    vals = list(scores.values())
    scores["overall"] = sum(vals) / len(vals) if vals else 0.0

    return scores


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def write_summary(run_dir, results, corpus, elapsed_seconds):
    """Write a human-readable summary.txt for qualitative inspection."""
    lines = []
    lines.append("=" * 80)
    lines.append("ThunderRAG Quality Test Report")
    lines.append(f"Run: {run_dir.name}")
    lines.append(f"Time: {datetime.now().isoformat()}")
    lines.append(f"Duration: {elapsed_seconds:.1f}s")
    lines.append(f"Test cases: {len(results)}")
    lines.append("=" * 80)

    all_anomalies = []
    all_scores = []
    category_scores = {}

    for result in results:
        tc_id = result.get("test_id", "?")
        category = result.get("category", "?")

        lines.append("")
        lines.append("-" * 80)
        lines.append(f"TEST: {tc_id} [{category}]")
        lines.append(f"Q: {result.get('question', '?')}")
        lines.append("-" * 80)

        if result.get("skipped"):
            lines.append(f"  SKIPPED: {result.get('reason', '?')}")
            continue

        if result.get("error"):
            lines.append(f"  ERROR: {result['error']}")
            continue

        complete = result.get("complete_response", {})
        query_resp = result.get("query_response", {})
        session_debug = result.get("session_debug", {})
        answer = complete.get("answer", "")
        sources = complete.get("sources", [])

        # --- Retrieved Sources ---
        lines.append("")
        lines.append("  RETRIEVED SOURCES:")
        message_ids = query_resp.get("message_ids", [])
        q_sources = query_resp.get("sources", [])
        lines.append(f"    message_ids returned: {len(message_ids)}")
        lines.append(f"    sources returned: {len(q_sources)}")
        for j, src in enumerate(q_sources):
            if isinstance(src, dict):
                doc_id = src.get("doc_id", "?")
                score = src.get("score", "?")
                md = src.get("metadata", {})
                subj = md.get("subject", "?") if isinstance(md, dict) else "?"
                fr = md.get("from", "?") if isinstance(md, dict) else "?"
                lines.append(f"    [{j+1}] score={score} doc_id={doc_id} from={fr} subject={subj}")

        # --- Evidence Upload Status ---
        lines.append("")
        lines.append("  EVIDENCE UPLOADS:")
        for ev in result.get("evidence_uploads", []):
            mid = ev.get("message_id", "?")
            st = ev.get("status", "?")
            lines.append(f"    {mid}: {st}")

        # --- Answer ---
        lines.append("")
        lines.append("  ANSWER:")
        for al in answer.split("\n"):
            lines.append(f"    {al}")

        # --- Sources in /query/complete response ---
        lines.append("")
        lines.append("  COMPLETE RESPONSE SOURCES:")
        for j, src in enumerate(sources):
            if isinstance(src, dict):
                doc_id = src.get("doc_id", "?")
                md = src.get("metadata", {})
                subj = md.get("subject", "?") if isinstance(md, dict) else "?"
                fr = md.get("from", "?") if isinstance(md, dict) else "?"
                dt = md.get("date", "?") if isinstance(md, dict) else "?"
                lines.append(f"    [{j+1}] doc_id={doc_id} from={fr} date={dt} subject={subj}")

        # --- Session Tail ---
        lines.append("")
        lines.append("  SESSION TAIL (last assistant message):")
        tail = session_debug.get("tail", [])
        assistant_msgs = [m for m in tail if m.get("role") == "assistant"]
        if assistant_msgs:
            last_msg = assistant_msgs[-1]["content"]
            for al in last_msg.split("\n"):
                lines.append(f"    {al}")
        else:
            lines.append("    (no assistant messages in tail)")

        lines.append(f"  Tail size: {len(tail)} messages")
        history_summary = session_debug.get("history_summary", "")
        if history_summary:
            lines.append(f"  History summary: {history_summary[:200]}...")

        # --- Anomalies ---
        anomalies = analyze_result(result, corpus)
        all_anomalies.extend([(tc_id, a) for a in anomalies])

        lines.append("")
        if anomalies:
            lines.append(f"  *** ANOMALIES ({len(anomalies)}) ***")
            for a in anomalies:
                lines.append(f"    ⚠ {a}")
        else:
            lines.append("  No anomalies detected.")

        # --- Numeric Scores ---
        scores = score_result(result)
        all_scores.append((tc_id, category, scores))
        category_scores.setdefault(category, []).append(scores.get("overall", 0.0))

        lines.append("")
        lines.append(f"  SCORES: overall={scores.get('overall', 0):.2f}")
        for k, v in scores.items():
            if k != "overall":
                lines.append(f"    {k}: {v:.1f}")

    # --- Summary ---
    lines.append("")
    lines.append("=" * 80)
    lines.append("SUMMARY")
    lines.append("=" * 80)

    # Anomaly summary
    lines.append("")
    lines.append(f"Total anomalies: {len(all_anomalies)}")
    if all_anomalies:
        lines.append("")
        lines.append("ALL ANOMALIES:")
        for tc_id, a in all_anomalies:
            lines.append(f"  [{tc_id}] {a}")

    # Score summary
    if all_scores:
        overall_scores = [s.get("overall", 0.0) for _, _, s in all_scores]
        mean_score = sum(overall_scores) / len(overall_scores)
        lines.append("")
        lines.append(f"Mean overall score: {mean_score:.2f}")
        lines.append("")
        lines.append("Per-category scores:")
        for cat, cat_scores in sorted(category_scores.items()):
            cat_mean = sum(cat_scores) / len(cat_scores) if cat_scores else 0.0
            lines.append(f"  {cat}: {cat_mean:.2f} ({len(cat_scores)} cases)")

        lines.append("")
        lines.append("Per-case scores:")
        for tc_id, category, scores in all_scores:
            overall = scores.get("overall", 0.0)
            marker = " *** LOW ***" if overall < 0.7 else ""
            lines.append(f"  {tc_id} [{category}]: {overall:.2f}{marker}")

    lines.append("")
    lines.append("=" * 80)
    lines.append("END OF REPORT")
    lines.append("=" * 80)

    summary_text = "\n".join(lines)

    summary_path = run_dir / "summary.txt"
    with open(summary_path, "w") as f:
        f.write(summary_text)

    return summary_text


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="ThunderRAG Quality Test Harness")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL, help="OCaml server URL")
    parser.add_argument("--server-log", default=None, help="Path to server stdout log to copy into run dir")
    parser.add_argument("--skip-ingest", action="store_true", help="Skip reset+ingest (reuse existing data)")
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")

    # Check server is reachable
    print(f"[init] Checking server at {base_url}...")
    try:
        r = requests.get(base_url + "/admin/models", timeout=5)
        print(f"  Server reachable (status {r.status_code})")
    except requests.ConnectionError:
        print(f"  ERROR: Server not reachable at {base_url}")
        print(f"  Start the server with:")
        print(f"    RAG_DEBUG_OLLAMA_CHAT=1 RAG_DEBUG_RETRIEVAL=1 dune exec -- rag-email-server -p 8080")
        sys.exit(1)

    # Load data
    corpus = load_json(CORPUS_PATH)
    test_cases = load_json(TEST_CASES_PATH)
    print(f"[init] Loaded {len(corpus['emails'])} emails, {len(test_cases['cases'])} test cases")

    # Create run directory
    run_dir = make_run_dir()
    print(f"[init] Run directory: {run_dir}")

    start_time = time.time()

    # Reset and ingest
    if not args.skip_ingest:
        if not reset_index(base_url):
            print("WARNING: Reset may have failed, continuing anyway...")
        # Reset all session groups used by test cases
        session_groups = set()
        for tc in test_cases["cases"]:
            sg = tc.get("session_group", f"session_{tc['id']}")
            session_groups.add(f"quality-test-{sg}")
        for sg in session_groups:
            reset_session(base_url, sg)

        corpus_by_mid = ingest_corpus(base_url, corpus)
    else:
        print("[init] Skipping reset+ingest (--skip-ingest)")
        corpus_by_mid = {}
        for email in corpus["emails"]:
            corpus_by_mid[email["message_id"]] = email["rfc822"]

    # Run test cases
    results = run_all_test_cases(base_url, test_cases, corpus_by_mid)

    elapsed = time.time() - start_time

    # Save results.json
    results_path = run_dir / "results.json"
    with open(results_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\n[output] Results saved to {results_path}")

    # Copy server log if provided
    if args.server_log and os.path.exists(args.server_log):
        shutil.copy2(args.server_log, run_dir / "server.log")
        print(f"[output] Server log copied to {run_dir / 'server.log'}")

    # Write summary
    summary_text = write_summary(run_dir, results, corpus, elapsed)

    # Print summary to stdout
    print("\n")
    print(summary_text)

    # Save summary
    print(f"\n[output] Summary saved to {run_dir / 'summary.txt'}")
    print(f"[output] Full results in {run_dir / 'results.json'}")


if __name__ == "__main__":
    main()
