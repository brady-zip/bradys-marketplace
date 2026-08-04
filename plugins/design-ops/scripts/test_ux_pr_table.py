#!/usr/bin/env python3
"""Self-checks for the attribution rule and window math. Run: python3 test_ux_pr_table.py"""

import importlib.util
import pathlib
from datetime import date

spec = importlib.util.spec_from_file_location(
    "ux_pr_table", pathlib.Path(__file__).with_name("ux_pr_table.py")
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

JENNY_ID, JENNY_GH = m.DESIGNERS["Jenny Liu"][0], m.DESIGNERS["Jenny Liu"][1]
JANET_GH = m.DESIGNERS["Janet Peng"][1]


def issue(*pr_numbers, assignee=JENNY_ID, state=("Done", "completed")):
    return {
        "identifier": "UX-1",
        "title": "t",
        "url": "u",
        "state": {"name": state[0], "type": state[1]},
        "assignee": {"id": assignee, "name": "x"},
        "pr_numbers": list(pr_numbers),
    }


def pr(number, author, assignees=()):
    return {
        "number": number,
        "url": f"https://github.com/{m.REPO}/pull/{number}",
        "title": "pr",
        "state": "MERGED",
        "author": author,
        "assignees": list(assignees),
    }


def credited_for(issues, prs, name="Jenny Liu"):
    return m.attribute(issues, {p["number"]: p for p in prs})[name]


def test_designer_authored_counts():
    got = credited_for([issue(1)], [pr(1, JENNY_GH)])
    assert len(got) == 1 and got[0]["prs"][0]["via"] == "self"


def test_engineer_authored_does_not_count():
    assert credited_for([issue(1)], [pr(1, "some-engineer")]) == []


def test_z_star_assigned_to_designer_counts():
    got = credited_for([issue(1)], [pr(1, "z-star-agent", [JENNY_GH])])
    assert len(got) == 1 and got[0]["prs"][0]["via"] == "z-star"


def test_z_star_assigned_to_someone_else_does_not_count():
    assert credited_for([issue(1)], [pr(1, "z-star-agent", [JANET_GH])]) == []


def test_z_star_unassigned_falls_back_to_ticket_assignee():
    got = credited_for([issue(1)], [pr(1, "z-star-agent")])
    assert len(got) == 1 and got[0]["prs"][0]["via"] == "z-star-unassigned"


def test_gh_cli_app_prefix_is_normalized():
    assert m.normalize_login("app/z-star-agent") in m.Z_STAR_LOGINS
    got = credited_for([issue(1)], [pr(1, m.normalize_login("app/z-star-agent"), [JENNY_GH])])
    assert len(got) == 1


def test_z_prefixed_humans_are_not_treated_as_z_star():
    for human in ("zelongjiang-byte", "zipster-vibhav", "zip-it"):
        assert credited_for([issue(1)], [pr(1, human, [JENNY_GH])]) == [], human


def test_designer_pr_behind_an_engineer_pr_still_counts():
    got = credited_for([issue(1, 2)], [pr(1, "some-engineer"), pr(2, JENNY_GH)])
    assert len(got) == 1 and [p["number"] for p in got[0]["prs"]] == [2]


def test_case_insensitive_handle_match():
    got = credited_for([issue(1)], [pr(1, JENNY_GH.upper())])
    assert len(got) == 1


def test_missing_pr_data_is_skipped():
    assert credited_for([issue(999)], []) == []


def test_quarter_starts():
    cases = {
        date(2026, 8, 4): date(2026, 8, 1),
        date(2026, 2, 1): date(2026, 2, 1),
        date(2026, 4, 30): date(2026, 2, 1),
        date(2026, 7, 31): date(2026, 5, 1),
        date(2026, 10, 15): date(2026, 8, 1),
        date(2026, 12, 25): date(2026, 11, 1),
        date(2027, 1, 15): date(2026, 11, 1),  # January belongs to Nov-Jan
    }
    for today, want in cases.items():
        assert m.quarter_start(today) == want, (today, m.quarter_start(today), want)


def test_date_rule_done_vs_merged():
    start, end = date(2026, 5, 1), date(2026, 7, 31)
    done_in = {"state": {"type": "completed"}, "completedAt": "2026-06-01T00:00:00.000Z",
               "updatedAt": "2026-08-04T00:00:00.000Z"}
    done_out = {"state": {"type": "completed"}, "completedAt": "2026-04-01T00:00:00.000Z",
                "updatedAt": "2026-06-01T00:00:00.000Z"}
    merged_in = {"state": {"type": "started"}, "completedAt": None,
                 "updatedAt": "2026-06-01T00:00:00.000Z"}
    assert m.keep_issue(done_in, start, end)
    assert not m.keep_issue(done_out, start, end)  # updatedAt must not rescue it
    assert m.keep_issue(merged_in, start, end)


def test_pr_url_matching():
    assert m.PR_URL_RE.match("https://github.com/Greenbax/evergreen/pull/123").group(2) == "123"
    assert not m.PR_URL_RE.match("https://github.com/Greenbax/evergreen/issues/123")
    assert not m.PR_URL_RE.match("https://linear.app/ziphq/issue/UX-1")


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
        print(f"ok  {t.__name__}")
    print(f"\n{len(tests)} passed")
