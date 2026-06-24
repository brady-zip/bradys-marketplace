# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Render the Slack unread board HTML.

Reads ~/.config/slack-bridge/triaged.json (model-produced) → writes ~/.config/slack-bridge/board.html.

    {
      "stamp": "2026-06-24 12:30",
      "groups": [
        {"urgency": "high", "topic": "...", "items": [
            {"text","author","channel_label","channel_id","ts","permalink"}, ...
        ]}, ...
      ]
    }

Each item carries channel_id + ts so the page can POST real mark-read to /api/mark.
Click tracking + checkbox bulk-select live in the page JS.
"""

from __future__ import annotations

import html
import json
import os
import pathlib
import re
import time

DATA_DIR = os.path.expanduser("~/.config/slack-bridge")

URGENCY_META = {
    "high": ("🔴", "High priority"),
    "medium": ("🟡", "Medium priority"),
    "low": ("⚪", "Low priority"),
}


def slack_to_plain(text):
    text = re.sub(r"<(https?://[^|>]+)\|([^>]+)>", r"\2", text or "")
    text = re.sub(r"<(https?://[^>]+)>", r"\1", text)
    text = re.sub(r"<@([A-Z0-9]+)>", r"@\1", text)
    text = re.sub(r"<!(\w+)>", r"@\1", text)
    text = re.sub(r"<https?://\S*$", "", text)
    text = re.sub(r"<https?://[^|>]+\|", "", text)
    return text.strip()


def fmt_age(ts, now):
    try:
        d = now - float(ts)
    except (TypeError, ValueError):
        return ""
    if d < 3600:
        return f"{int(d / 60)}m ago"
    if d < 86400:
        return f"{int(d / 3600)}h ago"
    return f"{int(d / 86400)}d ago"


def esc(s):
    return html.escape(s or "")


def render_item(row, now):
    key = esc(row.get("permalink") or (row.get("channel_label", "") + row.get("ts", "")))
    link = esc(row.get("permalink", ""))
    meta = " · ".join(
        x
        for x in [
            esc(row.get("author")),
            esc(row.get("channel_label")),
            fmt_age(row.get("ts"), now),
        ]
        if x
    )
    text = esc(slack_to_plain(row.get("text", ""))) or "<em>(no preview)</em>"
    cid = esc(row.get("channel_id", ""))
    ts = esc(row.get("ts", ""))
    return f"""
      <div class="item" data-key="{key}" data-cid="{cid}" data-ts="{ts}">
        <input type="checkbox" class="chk" onchange="onCheck(this)">
        <a class="body" href="{link}" target="_blank" onclick="markClicked('{key}')">
          <div class="meta">{meta}</div>
          <div class="text">{text}</div>
        </a>
      </div>"""


def render_group(g, now):
    items = g.get("items", [])
    if not items:
        return ""
    keys = json.dumps([
        (r.get("permalink") or (r.get("channel_label", "") + r.get("ts", "")))
        for r in items
    ])
    body = "".join(render_item(r, now) for r in items)
    topic = esc(g.get("topic", "Other"))
    return f"""
    <details class="group" open data-keys='{esc(keys)}'>
      <summary>
        <input type="checkbox" class="gchk" onclick="event.stopPropagation()" onchange="toggleGroup(this)">
        <span class="gtitle">{topic}</span>
        <span class="count">{len(items)}</span>
        <span class="unreadbadge"></span>
      </summary>
      <div class="items">{body}</div>
    </details>"""


def render_board(triaged):
    now = time.time()
    if triaged and triaged.get("groups"):
        stamp = triaged.get("stamp") or time.strftime("%Y-%m-%d %H:%M", time.localtime(now))
        groups = triaged["groups"]
    else:
        stamp = time.strftime("%Y-%m-%d %H:%M", time.localtime(now))
        groups = []

    total = sum(len(g.get("items", [])) for g in groups)

    body = ""
    for urg in ("high", "medium", "low"):
        gs = [g for g in groups if g.get("urgency") == urg]
        if not gs:
            continue
        icon, label = URGENCY_META[urg]
        inner = "".join(render_group(g, now) for g in gs)
        body += f"<section><h2>{icon} {esc(label)}</h2>{inner}</section>"

    return (
        PAGE
        .replace("{{TOTAL}}", str(total))
        .replace("{{STAMP}}", esc(stamp))
        .replace("{{BODY}}", body or "<p class='empty'>Nothing unread. 🎉</p>")
    )


PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Slack unread</title>
<style>
  :root { --bg:#f7f7f8; --card:#fff; --ink:#1d1c1d; --muted:#696969; --line:#e4e4e6;
          --accent:#611f69; --unread:#1264a3; --ok:#2bac76; }
  * { box-sizing:border-box; }
  body { margin:0; font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
         background:var(--bg); color:var(--ink); }
  header { position:sticky; top:0; background:var(--card); border-bottom:1px solid var(--line);
           padding:12px 20px; display:flex; align-items:center; gap:12px; z-index:5; }
  header h1 { margin:0; font-size:17px; }
  header .sub { color:var(--muted); font-size:12px; }
  .bar { margin-left:auto; display:flex; gap:8px; align-items:center; }
  .selinfo { font-size:12px; color:var(--muted); }
  button { font-size:12px; padding:5px 12px; border:1px solid var(--line); background:var(--card);
           border-radius:6px; cursor:pointer; color:var(--ink); }
  button.primary { background:var(--accent); color:#fff; border-color:var(--accent); }
  button.primary:disabled { opacity:.4; cursor:default; }
  main { max-width:880px; margin:0 auto; padding:18px 20px 80px; }
  section { margin-bottom:26px; }
  section h2 { font-size:13px; text-transform:uppercase; letter-spacing:.04em;
               color:var(--muted); margin:0 0 10px; }
  .group { background:var(--card); border:1px solid var(--line); border-radius:10px;
           margin-bottom:8px; overflow:hidden; }
  .group summary { list-style:none; cursor:pointer; padding:10px 14px; display:flex;
                   align-items:center; gap:8px; user-select:none; }
  .group summary::-webkit-details-marker { display:none; }
  .group summary::after { content:"▸"; color:var(--muted); font-size:11px; order:99;
                          margin-left:6px; transition:transform .15s; }
  .group[open] summary::after { transform:rotate(90deg); }
  .gtitle { font-weight:600; }
  .count { color:var(--muted); font-size:12px; background:var(--bg); border-radius:10px; padding:1px 8px; }
  .unreadbadge { margin-left:auto; font-size:11px; color:var(--unread); font-weight:600; }
  .items { border-top:1px solid var(--line); }
  .item { display:flex; gap:10px; padding:10px 14px; border-bottom:1px solid var(--line);
          align-items:flex-start; }
  .item:last-child { border-bottom:none; }
  .item:hover { background:#fafafa; }
  .item .chk { margin-top:3px; }
  .item .body { flex:1; text-decoration:none; color:var(--ink); }
  .item .meta { font-size:11px; color:var(--muted); margin-bottom:2px; }
  .item .text { font-weight:700; }                      /* unclicked = bold */
  .item.read .text { font-weight:400; color:var(--muted); }
  .item.read .meta { opacity:.7; }
  .item.marked { opacity:.45; }
  .empty { color:var(--muted); }
  .toast { position:fixed; bottom:20px; left:50%; transform:translateX(-50%); background:var(--ink);
           color:#fff; padding:8px 16px; border-radius:8px; font-size:13px; opacity:0;
           transition:opacity .2s; pointer-events:none; }
  .toast.show { opacity:1; }
</style>
</head>
<body>
<header>
  <h1>Slack unread</h1>
  <span class="sub">{{TOTAL}} items · {{STAMP}}</span>
  <span class="bar">
    <span class="selinfo" id="selinfo">0 selected</span>
    <button id="markbtn" class="primary" disabled onclick="markSelected()">Mark selected read</button>
    <button onclick="resetClicks()">reset clicks</button>
  </span>
</header>
<main>{{BODY}}</main>
<div class="toast" id="toast"></div>
<script>
  const LS="slackUnreadRead";
  function readSet(){ try{ return new Set(JSON.parse(localStorage.getItem(LS)||"[]")); }catch(e){ return new Set(); } }
  function saveSet(s){ localStorage.setItem(LS, JSON.stringify([...s])); }
  function cssEsc(k){ return (window.CSS&&CSS.escape)?CSS.escape(k):k.replace(/["\\]/g,"\\$&"); }

  function markClicked(key){
    const s=readSet(); s.add(key); saveSet(s);
    document.querySelectorAll(`.item[data-key="${cssEsc(key)}"]`).forEach(el=>el.classList.add("read"));
    refreshBadges();
  }
  function applyState(){
    const s=readSet();
    document.querySelectorAll(".item").forEach(el=>{ if(s.has(el.dataset.key)) el.classList.add("read"); });
    refreshBadges();
  }
  function refreshBadges(){
    const s=readSet();
    document.querySelectorAll(".group").forEach(g=>{
      let keys=[]; try{ keys=JSON.parse(g.dataset.keys||"[]"); }catch(e){}
      const n=keys.filter(k=>!s.has(k)).length;
      g.querySelector(".unreadbadge").textContent=n?n+" unread":"";
    });
  }
  function resetClicks(){ localStorage.removeItem(LS);
    document.querySelectorAll(".item.read").forEach(el=>el.classList.remove("read")); refreshBadges(); }

  // ---- selection ----
  function selected(){ return [...document.querySelectorAll(".item .chk:checked")].map(c=>c.closest(".item")); }
  function onCheck(){ updateSel(); }
  function toggleGroup(box){
    box.closest(".group").querySelectorAll(".item .chk").forEach(c=>{ c.checked=box.checked; });
    updateSel();
  }
  function updateSel(){
    const n=selected().length;
    document.getElementById("selinfo").textContent=n+" selected";
    document.getElementById("markbtn").disabled=n===0;
  }
  function toast(msg){ const t=document.getElementById("toast"); t.textContent=msg; t.classList.add("show");
    setTimeout(()=>t.classList.remove("show"),2500); }

  async function markSelected(){
    const els=selected();
    if(!els.length) return;
    const items=els.map(el=>({channel_id:el.dataset.cid, ts:el.dataset.ts}));
    const btn=document.getElementById("markbtn"); btn.disabled=true; btn.textContent="Marking…";
    try{
      const r=await fetch("/api/mark",{method:"POST",headers:{"Content-Type":"application/json"},
        body:JSON.stringify({items})});
      const j=await r.json();
      if(j.ok){
        els.forEach(el=>{ el.classList.add("marked","read"); el.querySelector(".chk").checked=false; });
        toast(`Marked read in Slack (${j.channels_marked} channel${j.channels_marked!==1?"s":""})`);
      } else { toast("Error: "+(j.error||"mark failed")); }
    }catch(e){ toast("Error: "+e.message); }
    btn.textContent="Mark selected read"; updateSel(); refreshBadges();
  }
  applyState(); updateSel();
</script>
</body>
</html>"""


if __name__ == "__main__":
    # Runtime files (triaged.json in, board.html out) live in DATA_DIR — git-tracked code
    # stays clean of secrets/data.
    with open(os.path.join(DATA_DIR, "triaged.json")) as fh:
        triaged = json.load(fh)
    pathlib.Path(os.path.join(DATA_DIR, "board.html")).write_text(render_board(triaged))
    n = sum(len(g.get("items", [])) for g in triaged.get("groups", []))
    print(f"wrote board.html ({n} items)")
