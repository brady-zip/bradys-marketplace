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


def test_resolve_designer_by_id_and_name():
    assert m.resolve_designer({"id": JENNY_ID, "name": "whatever"})[0] == "Jenny Liu"
    assert m.resolve_designer({"id": None, "name": "Jenny Liu"})[1] == JENNY_GH
    assert m.resolve_designer({"name": "Joyce Liu"})[0] == "Joyce Liu"  # not Jenny
    assert m.resolve_designer({"name": "Some Engineer"}) is None
    assert m.resolve_designer(None) is None


def test_resolve_designer_alias_and_casing():
    """Linear's display name for Jing Jian is "JingZhi Jian" -- id-less feeds need the alias."""
    assert m.resolve_designer({"name": "JingZhi Jian"})[0] == "Jing Jian"
    assert m.resolve_designer({"name": "jenny liu"})[0] == "Jenny Liu"
    for alias, key in m.LINEAR_NAME_ALIASES.items():
        assert key in m.DESIGNERS, f"alias {alias!r} points at unknown roster key {key!r}"


def test_normalize_api_shape():
    got = m.normalize_issue({
        "identifier": "UX-1", "title": "t", "url": "u",
        "completedAt": "2026-06-01T00:00:00.000Z", "updatedAt": "2026-06-02T00:00:00.000Z",
        "state": {"name": "Done", "type": "completed"},
        "assignee": {"id": JENNY_ID, "name": "Jenny Liu"},
        "attachments": {"nodes": [{"url": "https://github.com/x/y/pull/1"}]},
    })
    assert got["state"] == {"name": "Done", "type": "completed"}
    assert got["assignee"]["id"] == JENNY_ID
    assert got["attachment_urls"] == ["https://github.com/x/y/pull/1"]


def test_normalize_mcp_shape_with_bare_fields():
    """An MCP dump may give a bare state name, a bare assignee name, bare URLs."""
    got = m.normalize_issue({
        "identifier": "UX-2", "title": "t", "url": "u",
        "updatedAt": "2026-06-02T00:00:00.000Z",
        "state": "Merged",
        "assignee": "Jenny Liu",
        "links": ["https://github.com/x/y/pull/2"],
    })
    assert got["state"] == {"name": "Merged", "type": "started"}  # Merged is not completed
    assert got["assignee"] == {"id": None, "name": "Jenny Liu"}
    assert got["attachment_urls"] == ["https://github.com/x/y/pull/2"]
    assert m.resolve_designer(got["assignee"])[0] == "Jenny Liu"


def test_normalize_infers_completed_for_non_merged_state_names():
    assert m.normalize_issue({"state": "Done"})["state"]["type"] == "completed"
    assert m.normalize_issue({"state": "merged"})["state"]["type"] == "started"
    assert m.normalize_issue({"state": "Done", "stateType": "completed"})["state"]["type"] == "completed"


def test_normalize_tolerates_missing_fields():
    got = m.normalize_issue({})
    assert got["identifier"] == "?" and got["assignee"] is None and got["attachment_urls"] == []


def test_load_issues_file_accepts_array_and_wrapper(tmp=None):
    import json as _json
    import tempfile
    payloads = [
        [{"identifier": "UX-1", "state": "Done", "assignee": "Jenny Liu"}],
        {"issues": [{"identifier": "UX-1", "state": "Done", "assignee": "Jenny Liu"}]},
        {"nodes": [{"identifier": "UX-1", "state": "Done", "assignee": "Jenny Liu"}]},
    ]
    for payload in payloads:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            _json.dump(payload, fh)
            path = fh.name
        got = m.load_issues_file(path)
        assert len(got) == 1 and got[0]["identifier"] == "UX-1", payload


def test_mcp_sourced_issue_attributes_end_to_end():
    """A ticket that arrived via --issues-file credits the same as an API one."""
    issue = m.normalize_issue({
        "identifier": "UX-9", "title": "t", "url": "u", "state": "Done",
        "completedAt": "2026-06-01T00:00:00.000Z",
        "assignee": "Jenny Liu",
        "attachments": [{"url": f"https://github.com/{m.REPO}/pull/7"}],
    })
    issue["pr_numbers"] = [7]
    got = m.attribute([issue], {7: pr(7, "z-star-agent", [JENNY_GH])})
    assert got["Jenny Liu"][0]["prs"][0]["via"] == "z-star"


def test_attribute_skips_non_roster_assignees():
    issue = m.normalize_issue({"identifier": "X-1", "state": "Done", "assignee": "Some Engineer"})
    issue["pr_numbers"] = [1]
    assert all(not v for v in m.attribute([issue], {1: pr(1, "some-engineer")}).values())


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
