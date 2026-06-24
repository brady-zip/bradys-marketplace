const statusEl = document.getElementById("status");
const xoxcEl = document.getElementById("xoxc");
const xoxdEl = document.getElementById("xoxd");
const envEl = document.getElementById("envline");

function setStatus(msg, isErr) {
  statusEl.textContent = msg;
  statusEl.className = "status" + (isErr ? " err" : "");
}

function updateEnv() {
  const c = xoxcEl.value.trim();
  const d = xoxdEl.value.trim();
  if (c && d) {
    envEl.textContent = `mkdir -p ~/.config/slack-bridge && printf 'SLACK_XOXC=%s\\nSLACK_XOXD=%s\\n' '${c}' '${d}' > ~/.config/slack-bridge/.env && chmod 600 ~/.config/slack-bridge/.env`;
  }
}

// Pull xoxc out of the page's localStorage. Runs in the Slack tab's context.
function readXoxcFromPage() {
  try {
    const cfg = JSON.parse(localStorage.localConfig_v2);
    const teams = cfg && cfg.teams ? Object.values(cfg.teams) : [];
    // Prefer the team matching the currently active workspace if present.
    const active = cfg && cfg.lastActiveTeamId;
    const match = teams.find((t) => t.id === active) || teams[0];
    return match
      ? { token: match.token, team: match.name, url: match.url }
      : null;
  } catch (e) {
    return null;
  }
}

document.getElementById("grab").addEventListener("click", async () => {
  setStatus("Grabbing…");
  xoxcEl.value = "";
  xoxdEl.value = "";

  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab || !/^https:\/\/[^/]*\.slack\.com\//.test(tab.url || "")) {
    setStatus(
      "Active tab is not a slack.com page. Open Slack in the browser tab, then retry.",
      true,
    );
    return;
  }

  // 1. xoxc from page localStorage
  let xoxcResult = null;
  try {
    const [{ result }] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: readXoxcFromPage,
    });
    xoxcResult = result;
  } catch (e) {
    setStatus("Could not read page localStorage: " + e.message, true);
    return;
  }

  if (!xoxcResult || !xoxcResult.token) {
    setStatus(
      "No xoxc token found in localStorage. Are you fully logged in to this workspace?",
      true,
    );
  } else {
    xoxcEl.value = xoxcResult.token;
  }

  // 2. xoxd from the httpOnly `d` cookie (only the background/extension can read this)
  try {
    const cookie = await chrome.cookies.get({
      url: "https://slack.com",
      name: "d",
    });
    if (cookie && cookie.value) {
      // Slack expects the raw xoxd- value; cookie store keeps it URL-decoded already.
      const val = cookie.value.startsWith("xoxd-")
        ? cookie.value
        : "xoxd-" + cookie.value;
      xoxdEl.value = val;
    } else {
      setStatus(
        (statusEl.textContent ? statusEl.textContent + " " : "") +
          "No `d` cookie found.",
        true,
      );
    }
  } catch (e) {
    setStatus("Could not read cookie: " + e.message, true);
  }

  updateEnv();
  if (xoxcEl.value && xoxdEl.value) {
    const team = xoxcResult && xoxcResult.team ? ` (${xoxcResult.team})` : "";
    setStatus("Got both tokens" + team + ". Copy the env line below.");
  }
});

document.querySelectorAll(".copy").forEach((btn) => {
  btn.addEventListener("click", () => {
    const el = document.getElementById(btn.dataset.target);
    el.select();
    navigator.clipboard.writeText(el.value);
    setStatus("Copied " + btn.dataset.target + " to clipboard.");
  });
});

document.getElementById("copyenv").addEventListener("click", () => {
  navigator.clipboard.writeText(envEl.textContent);
  setStatus("Copied env line. Paste it into your terminal.");
});
