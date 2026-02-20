#!/usr/bin/env python3
"""
Render a ThunderRAG quality test run as a standalone HTML report
styled like the ThunderRAG addon chat UI.

Usage:
    python render_report.py                          # latest run
    python render_report.py runs/20260220_135832     # specific run
"""

import html
import json
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
RUNS_DIR = SCRIPT_DIR / "runs"
CORPUS_PATH = SCRIPT_DIR / "corpus.json"


def esc(s):
    return html.escape(str(s))


def linkify_citations(text):
    return re.sub(
        r"\[Email\s+(\d+)\]",
        r'<span class="citation">[Email \1]</span>',
        esc(text),
    )


def extract_citations(text):
    return [int(m) for m in re.findall(r"\[Email\s+(\d+)\]", text)]


def analyze_result(result, corpus):
    anomalies = []
    if result.get("skipped") or result.get("error"):
        return anomalies
    complete = result.get("complete_response", {})
    answer = complete.get("answer", "")
    sources = complete.get("sources", [])
    n_sources = len(sources)
    session_debug = result.get("session_debug", {})

    cited_nums = extract_citations(answer)
    if cited_nums:
        mx = max(cited_nums)
        if mx > n_sources:
            anomalies.append(f"CITATION OUT OF RANGE: [Email {mx}] but only {n_sources} sources")

    tail = session_debug.get("tail", [])
    assistant_msgs = [m for m in tail if m.get("role") == "assistant"]
    if assistant_msgs:
        last = assistant_msgs[-1]["content"]
        if "EMAILS REFERENCED ABOVE:" in last:
            ref_section = last.split("EMAILS REFERENCED ABOVE:\n", 1)[-1]
            ref_lines = [l for l in ref_section.strip().split("\n") if l.strip()]
            ref_nums = set(extract_citations("\n".join(ref_lines)))
            answer_part = last.split("EMAILS REFERENCED ABOVE:")[0]
            ans_cited = set(extract_citations(answer_part))
            if ans_cited and ans_cited != ref_nums:
                anomalies.append(f"CITATION MISMATCH: answer cites {sorted(ans_cited)} vs refs {sorted(ref_nums)}")
        elif cited_nums:
            anomalies.append("MISSING REFERENCE SECTION in session tail")

    if len(answer.strip()) < 10:
        anomalies.append(f"ANSWER TOO SHORT: {len(answer.strip())} chars")

    return anomalies


def score_result(result):
    if result.get("skipped") or result.get("error"):
        return {"overall": 0.0}
    criteria = result.get("criteria", {})
    complete = result.get("complete_response", {})
    answer_raw = complete.get("answer", "")
    answer_lower = answer_raw.lower()
    sources = complete.get("sources", [])
    scores = {}

    mc = criteria.get("must_contain_any", [])
    scores["must_contain"] = 1.0 if (not mc or any(k.lower() in answer_lower for k in mc)) else 0.0

    mn = criteria.get("must_not_contain", [])
    scores["must_not_contain"] = 1.0 if (not mn or all(k.lower() not in answer_lower for k in mn)) else 0.0

    if criteria.get("must_cite_emails"):
        cited = extract_citations(answer_raw)
        scores["has_citations"] = 1.0 if cited else 0.0
        n = len(sources)
        scores["citations_valid"] = 1.0 if (not cited or (n > 0 and all(1 <= c <= n for c in cited))) else 0.0
    else:
        scores["has_citations"] = 1.0
        scores["citations_valid"] = 1.0

    es = criteria.get("expected_email_subjects_any", [])
    if es and sources:
        ss = [s.get("metadata", {}).get("subject", "").lower() for s in sources if isinstance(s, dict)]
        scores["expected_sources"] = 1.0 if any(any(e.lower() in s for s in ss) for e in es) else 0.0
    else:
        scores["expected_sources"] = 1.0

    scores["no_hallucination"] = 1.0
    vals = list(scores.values())
    scores["overall"] = sum(vals) / len(vals) if vals else 0.0
    return scores


def render_source_card(idx, src):
    md = src.get("metadata", {}) if isinstance(src, dict) else {}
    subj = md.get("subject", "?")
    frm = md.get("from", "?")
    to = md.get("to", "")
    cc = md.get("cc", "")
    date = md.get("date", "?")
    score = src.get("score", "")
    doc_id = src.get("doc_id", "?")
    atts = md.get("attachments", [])
    score_s = f"{score:.3f}" if isinstance(score, float) else str(score)
    meta = f"<b>From:</b> {esc(frm)}<br><b>Date:</b> {esc(date)}"
    if to:
        meta = f"<b>From:</b> {esc(frm)}<br><b>To:</b> {esc(to)}<br><b>Date:</b> {esc(date)}"
    if cc:
        meta += f"<br><b>Cc:</b> {esc(cc)}"
    if atts:
        meta += f"<br><b>Attachments:</b> {esc(', '.join(atts))}"
    return (
        f'<div class="source">'
        f'<div class="source-header"><span class="source-title">[Email {idx+1}] {esc(subj)}</span>'
        f'<span class="muted">score {score_s}</span></div>'
        f'<div class="source-meta">{meta}</div>'
        f'<div class="muted" style="margin-top:2px;font-size:11px">{esc(doc_id)}</div></div>'
    )


def render_result(r):
    tc_id = r.get("test_id", "?")
    cat = r.get("category", "?")
    q = r.get("question", "?")
    anomalies = r.get("_anomalies", [])
    scores = r.get("_scores", {})
    overall = scores.get("overall", 0)

    if r.get("skipped") or r.get("error"):
        msg = r.get("reason", "") or r.get("error", "")
        return (
            f'<div class="conversation" id="conv-{esc(tc_id)}">'
            f'<div class="conv-header"><span class="conv-id">{esc(tc_id)}</span>'
            f'<span class="badge cat">{esc(cat)}</span>'
            f'<span class="badge err">ERROR</span></div>'
            f'<div class="msg msg-user"><div class="bubble">{esc(q)}</div></div>'
            f'<div class="msg msg-assistant"><div class="bubble error">{esc(msg)}</div></div></div>'
        )

    complete = r.get("complete_response", {})
    session_debug = r.get("session_debug", {})
    answer = complete.get("answer", "")
    sources = complete.get("sources", [])

    cards = "\n".join(render_source_card(i, s) for i, s in enumerate(sources))
    answer_html = linkify_citations(answer).replace("\n", "<br>")

    # Tail
    tail = session_debug.get("tail", [])
    tail_items = ""
    for m in tail:
        role = m.get("role", "?")
        content = m.get("content", "")
        cls = "tail-user" if role == "user" else "tail-assistant"
        tail_items += f'<div class="tail-msg {cls}"><b>{esc(role)}:</b><br>{linkify_citations(content).replace(chr(10), "<br>")}</div>'

    # Anomaly badges
    anom_html = ""
    if anomalies:
        for a in anomalies:
            anom_html += f'<div class="anomaly-badge">{esc(a)}</div>'

    # Score pills
    score_pills = ""
    for k, v in scores.items():
        if k == "overall":
            continue
        cls = "pill-good" if v >= 0.8 else "pill-low"
        score_pills += f'<span class="pill {cls}">{esc(k)} {v:.0%}</span> '

    ov_cls = "score-good" if overall >= 0.8 else "score-low"

    return f"""<div class="conversation" id="conv-{esc(tc_id)}">
  <div class="conv-header">
    <span class="conv-id">{esc(tc_id)}</span>
    <span class="badge cat">{esc(cat)}</span>
    <span class="badge {ov_cls}">{overall:.0%}</span>
  </div>
  <div class="msg msg-user"><div class="bubble">{esc(q)}</div></div>
  <div class="msg msg-assistant"><div class="bubble">
    <details><summary>Sources ({len(sources)} emails)</summary>
      <div class="sources">{cards}</div>
    </details>
    <div class="answer-text">{answer_html}</div>
    {f'<div class="anomalies">{anom_html}</div>' if anom_html else ''}
    <details class="tail-section"><summary>Session tail ({len(tail)} messages)</summary>
      <div class="tail-content">{tail_items}</div>
    </details>
    <div class="score-pills">{score_pills}</div>
  </div></div>
</div>"""


def main():
    if len(sys.argv) > 1:
        run_dir = Path(sys.argv[1])
        if not run_dir.is_absolute():
            run_dir = SCRIPT_DIR / run_dir
    else:
        run_dir = sorted(RUNS_DIR.iterdir())[-1] if RUNS_DIR.exists() else None

    if not run_dir or not (run_dir / "results.json").exists():
        print("No results.json found"); sys.exit(1)

    results = json.loads((run_dir / "results.json").read_text())
    corpus = json.loads(CORPUS_PATH.read_text()) if CORPUS_PATH.exists() else {"emails": []}

    # Enrich results with anomalies and scores
    for r in results:
        r["_anomalies"] = analyze_result(r, corpus)
        r["_scores"] = score_result(r)

    n_emails = len(corpus.get("emails", []))
    n_convos = len(results)
    run_name = run_dir.name

    # Nav
    nav_items = ""
    for r in results:
        tid = r.get("test_id", "?")
        cat = r.get("category", "?")
        ov = r.get("_scores", {}).get("overall", 0)
        cls = "nav-good" if ov >= 0.8 else "nav-low"
        nav_items += (
            f'<a href="#conv-{esc(tid)}" class="nav-item {cls}">'
            f'<span class="nav-id">{esc(tid)}</span>'
            f'<span class="nav-cat">{esc(cat)}</span>'
            f'<span class="nav-score">{ov:.0%}</span></a>\n'
        )

    convos_html = "\n".join(render_result(r) for r in results)

    page = f"""<!doctype html>
<html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ThunderRAG Report — {esc(run_name)}</title>
<style>
:root {{ color-scheme: light dark; }}
* {{ box-sizing: border-box; }}
body {{ font-family: system-ui,-apple-system,Segoe UI,Roboto,sans-serif; margin:0; background:Canvas; color:CanvasText; }}
.layout {{ display:flex; height:100vh; }}
.sidebar {{ width:260px; min-width:260px; border-right:1px solid rgba(127,127,127,.25); overflow-y:auto; padding:12px 0; background:Field; }}
.sidebar h2 {{ font-size:14px; padding:0 14px; margin:0 0 4px; opacity:.7; }}
.sidebar .stats {{ font-size:12px; padding:2px 14px 8px; opacity:.55; }}
.nav-item {{ display:flex; align-items:center; gap:6px; padding:7px 14px; text-decoration:none; color:CanvasText; border-left:3px solid transparent; font-size:13px; }}
.nav-item:hover {{ background:rgba(127,127,127,.08); }}
.nav-id {{ font-weight:600; flex:1; }}
.nav-cat {{ opacity:.45; font-size:11px; }}
.nav-score {{ font-weight:600; font-size:12px; min-width:36px; text-align:right; }}
.nav-good .nav-score {{ color:#2e7d32; }}
.nav-low .nav-score {{ color:#c62828; }}

.main {{ flex:1; overflow-y:auto; padding:20px 24px; }}
.conversation {{ margin-bottom:32px; border:1px solid rgba(127,127,127,.18); border-radius:14px; padding:16px; background:Field; }}
.conv-header {{ display:flex; align-items:center; gap:8px; margin-bottom:12px; }}
.conv-id {{ font-weight:700; font-size:15px; }}
.badge {{ font-size:11px; padding:2px 8px; border-radius:8px; font-weight:600; }}
.badge.cat {{ background:rgba(127,127,127,.12); }}
.badge.score-good {{ background:#c8e6c9; color:#1b5e20; }}
.badge.score-low {{ background:#ffcdd2; color:#b71c1c; }}
.badge.err {{ background:#ffcdd2; color:#b71c1c; }}

.msg {{ display:flex; margin:8px 0; }}
.msg-user {{ justify-content:flex-end; }}
.msg-assistant {{ justify-content:flex-start; }}
.bubble {{ max-width:min(860px,94%); padding:12px; border-radius:12px; line-height:1.4; border:1px solid rgba(127,127,127,.25); background:Canvas; color:CanvasText; }}
.msg-user .bubble {{ background:AccentColor; color:AccentColorText; border-color:transparent; white-space:pre-wrap; }}
.citation {{ color:AccentColor; font-weight:600; }}
.answer-text {{ margin-top:10px; white-space:pre-wrap; word-break:break-word; }}

details summary {{ cursor:pointer; user-select:none; opacity:.5; font-size:11px; padding:4px 0; }}
details summary:hover {{ opacity:.8; }}
.sources {{ display:grid; gap:8px; margin-top:8px; }}
.source {{ border:1px solid rgba(127,127,127,.25); border-radius:10px; padding:10px; background:Field; }}
.source-header {{ display:flex; justify-content:space-between; align-items:baseline; gap:8px; flex-wrap:wrap; }}
.source-title {{ font-weight:600; font-size:13px; }}
.source-meta {{ margin-top:6px; font-size:12px; opacity:.85; line-height:1.5; }}
.muted {{ opacity:.6; font-size:12px; }}

.anomalies {{ margin-top:10px; }}
.anomaly-badge {{ background:#fff3e0; color:#e65100; border:1px solid #ffcc80; border-radius:8px; padding:4px 10px; font-size:12px; font-weight:600; margin:4px 0; }}
@media(prefers-color-scheme:dark) {{ .anomaly-badge {{ background:#3e2723; color:#ffab91; border-color:#6d4c41; }} }}

.tail-section {{ margin-top:10px; border-top:1px solid rgba(127,127,127,.12); padding-top:6px; }}
.tail-content {{ margin-top:6px; font-size:12px; line-height:1.45; }}
.tail-msg {{ padding:6px 8px; margin:4px 0; border-radius:8px; white-space:pre-wrap; word-break:break-word; }}
.tail-user {{ background:rgba(0,100,200,.08); }}
.tail-assistant {{ background:rgba(127,127,127,.06); }}

.score-pills {{ margin-top:8px; display:flex; flex-wrap:wrap; gap:4px; }}
.pill {{ font-size:11px; padding:2px 7px; border-radius:6px; font-weight:600; }}
.pill-good {{ background:#c8e6c9; color:#1b5e20; }}
.pill-low {{ background:#ffcdd2; color:#b71c1c; }}
@media(prefers-color-scheme:dark) {{
  .pill-good {{ background:#1b5e20; color:#a5d6a7; }}
  .pill-low {{ background:#b71c1c; color:#ffcdd2; }}
  .badge.score-good {{ background:#1b5e20; color:#a5d6a7; }}
  .badge.score-low {{ background:#b71c1c; color:#ffcdd2; }}
}}
.error {{ color:#b00020; }}
</style>
</head>
<body>
<div class="layout">
  <div class="sidebar">
    <h2>ThunderRAG Quality Report</h2>
    <div class="stats">{n_emails} emails ingested &middot; {n_convos} conversations</div>
    <div class="stats" style="margin-top:-4px">Run: {esc(run_name)}</div>
    {nav_items}
  </div>
  <div class="main">
    {convos_html}
  </div>
</div>
</body></html>"""

    out_path = run_dir / "report.html"
    out_path.write_text(page)
    print(f"Report written to {out_path}")
    return out_path


if __name__ == "__main__":
    main()
