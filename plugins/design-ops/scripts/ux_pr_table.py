#!/usr/bin/env python3
"""Build the UX quality ticket completion table from Linear + GitHub.

Deterministic parts of the report live here: window math, Linear paging,
PR attribution (including Z*-authored PRs), and the uncounted-PR sweep.
Judgment calls (is an uncounted PR really UX-quality work?) stay with the
caller -- this script reports candidates, it does not classify them.

Usage:
  ux_pr_table.py                        # current Zip fiscal quarter
  ux_pr_table.py 2026-06-01..today      # explicit window
  ux_pr_table.py --since 2026-06-01 --until 2026-07-31
  ux_pr_table.py --json                 # machine-readable instead of markdown
  ux_pr_table.py --no-sweep             # skip the uncounted-PR sweep (faster)

Requires: LINEAR_API_KEY in the environment, and an authenticated `gh`.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import date, datetime, timezone

LINEAR_API = "https://api.linear.app/graphql"
LABEL = "UX Quality"
PROJECT_URL = "https://linear.app/ziphq/project/ux-quality-9d2ed62523ef"
REPO = "Greenbax/evergreen"
MERGED_STATE_NAME = "Merged"

# Z* opens PRs on a person's behalf: the GitHub author is the agent, so
# attribution follows the PR assignee. GraphQL reports the login bare;
# the gh CLI prefixes app accounts with "app/". Match either, and never
# match on a bare "z" prefix -- real humans have z-prefixed handles.
Z_STAR_LOGINS = {"z-star-agent", "app/z-star-agent"}

# Designer name -> (Linear user id, GitHub handle or None if unresolved)
DESIGNERS: dict[str, tuple[str, str | None]] = {
    "Akash Talyan": ("cea55c77-c587-4a3b-bb62-36f5ee02cb8b", "akashtalyan1"),
    "Amanda Yam": ("977e8100-0dd9-4e29-9b4e-b08af594e2ff", "amandayam-zip"),
    "Ashley Quinn": ("44cbd156-bf6f-4abd-96a2-29f7c02aa233", "ashleyquinn28"),
    "Chris Duxbury": ("1226f282-f5cf-4124-9332-806a9c988e2b", "chrisduxbury-design"),
    "Esther Kwon": ("bae9ccb4-9a15-4d6b-b721-191d90bd25e1", "estheryjk"),
    "Forrest Kim": ("da552334-1ea7-45ff-8676-4482c59fe434", "forrestkim2012"),
    "Jack D'Aquila": ("f735bb06-fc9f-43af-bcfa-660a5ad03797", "jackdaquila"),
    "Jacob Esparza": ("eef733af-16fe-4472-9881-9d750333ad6f", "jacobespa"),
    "Janet Peng": ("ad596419-dd98-4922-88c3-8e40c97aebc9", "j-peng"),
    "Jenny Liu": ("d83e3069-665f-4482-9d1e-8f2dd7c15872", "jennyliu-0099"),
    "Jing Jian": ("bcc45ea5-147b-4919-ae5e-02aa178e2181", "thisisJing"),
    # Distinct from Jenny Liu above -- different person, different Linear id.
    "Joyce Liu": ("14f443dd-0823-4859-bb69-53e552307e2d", "jambajoyce"),
    "Xande Macedo": ("f37591a1-0e6f-47ff-b3b0-f28aab4fe17a", None),
    "Ying Wong": ("7a9dccde-6230-4238-8249-12cec27b4b63", "yg-wong"),
    "Yumei Feng": ("7bad4cb2-3af1-48cb-85c3-363a4cec3934", None),
    "Zack Karrasch": ("cee547a3-45bc-410e-9614-9b36e35ee77c", None),
}

PR_URL_RE = re.compile(r"https://github\.com/([^/]+/[^/]+)/pull/(\d+)")


# ---------------------------------------------------------------- window


def quarter_start(today: date) -> date:
    """Zip fiscal quarters: Feb-Apr, May-Jul, Aug-Oct, Nov-Jan.

    January belongs to the Nov-Jan quarter, so it starts in the prior year.
    """
    m = today.month
    if m == 1:
        return date(today.year - 1, 11, 1)
    start_month = {2: 2, 3: 2, 4: 2, 5: 5, 6: 5, 7: 5, 8: 8, 9: 8, 10: 8, 11: 11, 12: 11}[m]
    return date(today.year, start_month, 1)


def parse_window(args: argparse.Namespace, today: date) -> tuple[date, date]:
    since, until = args.since, args.until
    if args.range:
        raw = args.range.strip()
        if ".." not in raw:
            sys.exit(f"range must look like 2026-06-01..today (got {raw!r})")
        lo, _, hi = raw.partition("..")
        since = since or lo.strip()
        until = until or hi.strip()

    start = quarter_start(today) if not since or since == "quarter" else date.fromisoformat(since)
    end = today if not until or until == "today" else date.fromisoformat(until)
    if end < start:
        sys.exit(f"window ends before it starts: {start}..{end}")
    return start, end


def in_window(stamp: str | None, start: date, end: date) -> bool:
    if not stamp:
        return False
    d = datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone(timezone.utc).date()
    return start <= d <= end


# ---------------------------------------------------------------- linear

ISSUES_QUERY = """
query($f: IssueFilter, $after: String) {
  issues(filter: $f, first: 100, after: $after) {
    pageInfo { hasNextPage endCursor }
    nodes {
      identifier title url updatedAt completedAt
      state { name type }
      assignee { id name }
      attachments { nodes { url } }
    }
  }
}
"""


def linear(query: str, variables: dict) -> dict:
    key = os.environ.get("LINEAR_API_KEY")
    if not key:
        sys.exit("LINEAR_API_KEY is not set")
    req = urllib.request.Request(
        LINEAR_API,
        data=json.dumps({"query": query, "variables": variables}).encode(),
        headers={"Authorization": key, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = json.load(resp)
    except urllib.error.HTTPError as e:  # surface Linear's own message
        sys.exit(f"Linear HTTP {e.code}: {e.read().decode()[:500]}")
    if body.get("errors"):
        sys.exit(f"Linear error: {json.dumps(body['errors'])[:800]}")
    return body["data"]


def fetch_issues() -> list[dict]:
    """Every Done-or-Merged UX Quality issue assigned to a tracked designer."""
    issue_filter = {
        "labels": {"name": {"eq": LABEL}},
        "assignee": {"id": {"in": [uid for uid, _ in DESIGNERS.values()]}},
        "or": [
            {"state": {"type": {"eq": "completed"}}},
            {"state": {"name": {"eq": MERGED_STATE_NAME}}},
        ],
    }
    out: list[dict] = []
    after = None
    while True:
        page = linear(ISSUES_QUERY, {"f": issue_filter, "after": after})["issues"]
        out.extend(page["nodes"])
        if not page["pageInfo"]["hasNextPage"]:
            return out
        after = page["pageInfo"]["endCursor"]


def keep_issue(issue: dict, start: date, end: date) -> bool:
    """Done tickets go by completedAt; Merged ones have none, so use updatedAt."""
    if issue["state"]["type"] == "completed":
        return in_window(issue["completedAt"], start, end)
    return in_window(issue["updatedAt"], start, end)


# ---------------------------------------------------------------- github


def gh(args: list[str]) -> str:
    proc = subprocess.run(["gh", *args], capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"gh {' '.join(args)} failed: {proc.stderr.strip()[:500]}")
    return proc.stdout


def normalize_login(login: str | None) -> str:
    return (login or "").removeprefix("app/")


def fetch_prs(numbers: list[int]) -> dict[int, dict]:
    """Author + assignees for many PRs, batched into aliased GraphQL fields."""
    owner, name = REPO.split("/")
    found: dict[int, dict] = {}
    for chunk_start in range(0, len(numbers), 50):
        chunk = numbers[chunk_start : chunk_start + 50]
        fields = " ".join(
            f'p{n}: pullRequest(number: {n}) {{ number url title state '
            f"author {{ login }} assignees(first: 20) {{ nodes {{ login }} }} }}"
            for n in chunk
        )
        query = f'query {{ repository(owner: "{owner}", name: "{name}") {{ {fields} }} }}'
        data = json.loads(gh(["api", "graphql", "-f", f"query={query}"]))
        for node in (data.get("data", {}).get("repository") or {}).values():
            if not node:  # deleted or inaccessible PR
                continue
            found[node["number"]] = {
                "number": node["number"],
                "url": node["url"],
                "title": node["title"],
                "state": node["state"],
                "author": normalize_login((node.get("author") or {}).get("login")),
                "assignees": [a["login"] for a in node["assignees"]["nodes"]],
            }
    return found


def merged_pr_sweep(start: date) -> dict[str, list[dict]]:
    """Merged PRs per designer since `start`: their own, plus Z*'s assigned to them.

    Used to surface work that never made it into the table, so it runs the
    same two lookups the attribution rule cares about.
    """
    jobs: list[tuple[str, list[str]]] = []
    since = f"merged:>={start.isoformat()}"
    for name, (_, handle) in DESIGNERS.items():
        if not handle:
            continue
        common = ["pr", "list", "--repo", REPO, "--state", "merged", "--search", since,
                  "--limit", "100", "--json", "number,title,url,mergedAt"]
        jobs.append((name, [*common, "--author", handle]))
        jobs.append((name, [*common, "--author", "app/z-star-agent", "--assignee", handle]))

    out: dict[str, list[dict]] = {name: [] for name in DESIGNERS}
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for (name, _), raw in zip(jobs, pool.map(lambda j: gh(j[1]), jobs)):
            for pr in json.loads(raw):
                if pr["number"] not in {p["number"] for p in out[name]}:
                    out[name].append(pr)
    return out


# ---------------------------------------------------------- attribution


def attribute(issues: list[dict], prs: dict[int, dict]) -> dict[str, list[dict]]:
    """Credit a ticket to its designer when an attached PR is attributable.

    Designer-authored PRs count outright. Z*-authored PRs count when the
    designer is a PR assignee; if a Z* PR has no assignee at all, the Linear
    ticket assignee stands in, flagged so the missing assignment is visible.
    """
    by_id = {uid: (name, handle) for name, (uid, handle) in DESIGNERS.items()}
    credited: dict[str, list[dict]] = {name: [] for name in DESIGNERS}

    for issue in issues:
        name, handle = by_id[issue["assignee"]["id"]]
        hits = []
        for number in issue["pr_numbers"]:
            pr = prs.get(number)
            if not pr:
                continue
            if handle and pr["author"].lower() == handle.lower():
                hits.append({**pr, "via": "self"})
            elif pr["author"] in Z_STAR_LOGINS:
                assignees = {a.lower() for a in pr["assignees"]}
                if handle and handle.lower() in assignees:
                    hits.append({**pr, "via": "z-star"})
                elif not pr["assignees"]:
                    hits.append({**pr, "via": "z-star-unassigned"})
        if hits:
            credited[name].append({
                "identifier": issue["identifier"],
                "title": issue["title"],
                "url": issue["url"],
                "state": issue["state"]["name"],
                "prs": hits,
            })
    return credited


# ---------------------------------------------------------------- render


def via_marker(via: str) -> str:
    return {"self": "", "z-star": " (Z\\*)", "z-star-unassigned": " (Z\\*, unassigned PR)"}[via]


def render(credited: dict[str, list[dict]], sweep: dict[str, list[dict]] | None,
           start: date, end: date) -> str:
    rows = []
    for name, tickets in credited.items():
        prs = {pr["number"]: pr for t in tickets for pr in t["prs"]}
        z_count = sum(1 for pr in prs.values() if pr["via"].startswith("z-star"))
        rows.append((name, len(tickets), len(prs), z_count, tickets))
    rows.sort(key=lambda r: (-r[1], -r[2], r[0]))

    lines = [
        f"## UX Quality: tickets completed or merged with an attributed PR",
        "",
        f"Window: **{start.isoformat()} .. {end.isoformat()}** · label `{LABEL}` · [project]({PROJECT_URL})",
        "",
        "| Designer | Completed or Merged, with an attributed PR | Unique PRs | Z\\* PRs |",
        "| --- | --- | --- | --- |",
    ]
    for name, tickets, prs, z_count, _ in rows:
        lines.append(f"| {name} | {tickets} | {prs} | {z_count} |")

    lines += ["", "### Qualifying tickets", ""]
    for name, count, _, _, tickets in rows:
        if not count:
            continue
        lines.append(f"**{name}** ({count})")
        for t in sorted(tickets, key=lambda x: x["identifier"]):
            links = ", ".join(
                f"[#{pr['number']}]({pr['url']}){via_marker(pr['via'])}" for pr in t["prs"]
            )
            lines.append(f"- [{t['identifier']}]({t['url']}) — {t['title']} → {links} · _{t['state']}_")
        lines.append("")

    unresolved = [n for n, (_, h) in DESIGNERS.items() if not h]
    if unresolved:
        lines += [f"_No GitHub handle configured (cannot attribute): {', '.join(unresolved)}._", ""]

    if sweep is not None:
        counted = {pr["number"] for ts in credited.values() for t in ts for pr in t["prs"]}
        lines += ["### Uncounted merged PRs (possible tracking gaps)", "",
                  "_Merged in-window but not in the table above. Judge which are UX-quality work "
                  "before counting anything here._", ""]
        any_gap = False
        for name in sorted(sweep):
            gaps = [pr for pr in sweep[name] if pr["number"] not in counted]
            if not gaps:
                continue
            any_gap = True
            lines.append(f"**{name}** ({len(gaps)})")
            for pr in sorted(gaps, key=lambda p: -p["number"]):
                lines.append(f"- [#{pr['number']}]({pr['url']}) {pr['title']}")
            lines.append("")
        if not any_gap:
            lines += ["None.", ""]

    return "\n".join(lines)


# ------------------------------------------------------------------ main


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("range", nargs="?", help="window as START..END, e.g. 2026-06-01..today")
    ap.add_argument("--since", help="window start (YYYY-MM-DD)")
    ap.add_argument("--until", help="window end (YYYY-MM-DD or 'today')")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of markdown")
    ap.add_argument("--no-sweep", action="store_true", help="skip the uncounted-PR sweep")
    args = ap.parse_args()

    today = datetime.now(timezone.utc).date()
    start, end = parse_window(args, today)

    issues = [i for i in fetch_issues() if i["assignee"] and keep_issue(i, start, end)]
    numbers: list[int] = []
    for issue in issues:
        found = []
        for att in issue["attachments"]["nodes"]:
            m = PR_URL_RE.match(att["url"] or "")
            if m and m.group(1).lower() == REPO.lower():
                found.append(int(m.group(2)))
        issue["pr_numbers"] = sorted(set(found))
        numbers.extend(issue["pr_numbers"])

    prs = fetch_prs(sorted(set(numbers)))
    credited = attribute(issues, prs)
    sweep = None if args.no_sweep else merged_pr_sweep(start)

    if args.json:
        counted = {pr["number"] for ts in credited.values() for t in ts for pr in t["prs"]}
        print(json.dumps({
            "window": {"start": start.isoformat(), "end": end.isoformat()},
            "issues_considered": len(issues),
            "credited": credited,
            "uncounted_merged_prs": None if sweep is None else {
                name: [pr for pr in prs_ if pr["number"] not in counted]
                for name, prs_ in sweep.items()
            },
        }, indent=2))
    else:
        print(render(credited, sweep, start, end))


if __name__ == "__main__":
    main()
