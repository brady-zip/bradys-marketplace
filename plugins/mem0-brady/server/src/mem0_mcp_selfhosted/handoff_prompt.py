"""The resume-handoff synthesis prompt, shared by both execution paths.

Handoff synthesis can run in two places:

* **in-process** — ``hooks._synthesize_handoff`` calling ``mem.llm`` directly,
  which is what a managed/local stack does; and
* **server-side** — the ``synthesize_handoff`` MCP tool, which is what an
  external stack does so the host needs no LLM provider, no API key and no
  mem0 install of its own.

Both must produce *identical* recaps, or a machine's handoffs would silently
change character depending on which path it happened to take. Keeping the one
template here — rather than a copy on each side — is what makes that true by
construction rather than by discipline.

Only prompt construction lives here. Gathering the inputs (reading the
transcript, the previous handoff file and the workstream doc) is host-side work,
because those are host paths; running the completion is the LLM owner's work.
"""

from __future__ import annotations


def build_handoff_prompt(
    conversation: str,
    project_name: str,
    previous_handoff: str = "",
    recalled: str = "",
    workstream_overview: str = "",
    workstream_slug: str = "",
) -> str:
    """Assemble the handoff synthesis prompt.

    ``conversation`` is the pre-formatted recent transcript ("[User]: …"),
    ``recalled`` a newline-bulleted block of long-term memories, and
    ``previous_handoff`` the recap this run will overwrite — folded in so the
    new one is a continuation rather than a cold start.
    """
    previous_block = previous_handoff or "(none — first handoff for this project)"
    recalled_block = recalled or "(none)"

    # When the session is tagged with a workstream, fold its overview (goal +
    # the index of sibling pieces) into the synthesis so this per-cwd recap is
    # situated within the larger, multi-session objective. Per-piece current
    # state stays in each piece's own handoff — referenced, never inlined here.
    workstream_block = ""
    workstream_hint = ""
    if workstream_slug and workstream_overview:
        workstream_block = (
            f"## Active workstream '{workstream_slug}' "
            f"(overarching, multi-session context):\n{workstream_overview}\n\n"
        )
        workstream_hint = (
            " This session is part of the workstream above — keep the Goal "
            "consistent with its overarching objective, and do not restate "
            "sibling pieces' state (that lives in their own handoffs)."
        )

    return (
        "You are writing a terse resume handoff so a future agent (or the same "
        "user returning to a cold context) can pick up a coding session "
        "immediately. Be concrete: name files, PR numbers, identifiers.\n\n"
        f"{workstream_block}"
        f"## Previous handoff (the recap you are updating):\n{previous_block}\n\n"
        f"## Recent conversation (oldest first), project '{project_name}':\n"
        f"{conversation}\n\n"
        f"## Relevant long-term memory:\n{recalled_block}\n\n"
        "Treat the previous handoff as prior state: carry forward goals and "
        "watch-outs that still hold, update State/Next from the recent "
        "conversation, and drop anything now done. Do not copy it verbatim."
        f"{workstream_hint}\n\n"
        "Write markdown under ~180 words, omitting any section that does not "
        "apply, with these headers:\n"
        "- **Goal** — the overarching objective in one sentence.\n"
        "- **State** — what is done/shipped so far (bullets).\n"
        "- **Next** — the immediate next step(s).\n"
        "- **Watch out** — gotchas, blockers, or pending user decisions.\n"
        "Start directly with the **Goal** line — no document title, no "
        "preamble, no closing remarks."
    )


def coerce_completion(resp: object) -> str:
    """Normalise an LLM response to text.

    ``generate_response`` returns a str on the no-tools path across providers,
    but be defensive about a dict-shaped return.
    """
    if isinstance(resp, dict):
        resp = resp.get("content") or resp.get("text") or ""
    return (resp or "").strip() if isinstance(resp, str) else ""
