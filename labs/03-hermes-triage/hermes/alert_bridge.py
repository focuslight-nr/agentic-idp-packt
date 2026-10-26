"""Receives Alertmanager webhooks and runs one Hermes triage per firing alert.

The bridge holds no GitHub credentials. It posts structured results to runbook-bot,
which opens two PRs when possible: a fix PR (values.yaml) and a triage PR (report +
optional runbook entry).
"""

import json
import logging
import os
import queue
import re
import shlex
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.environ.get("PORT", "8080"))
# -Q prints only Hermes's final answer: no prompt echo, tool previews, or Markdown rendering.
HERMES_CMD = shlex.split(os.environ.get("HERMES_CMD", "hermes chat -Q -q"))
TRIAGE_TIMEOUT_SECONDS = int(os.environ.get("TRIAGE_TIMEOUT_SECONDS", "300"))
DEDUP_WINDOW_SECONDS = int(os.environ.get("DEDUP_WINDOW_SECONDS", "900"))
PROMPT_TEMPLATE = Path(os.environ.get("PROMPT_TEMPLATE", "/app/triage-prompt.md")).read_text()
REPORTS_DIR = Path(os.environ.get("REPORTS_DIR", "/tmp/reports"))
RUNBOOK_BOT_URL = os.environ.get("RUNBOOK_BOT_URL", "").rstrip("/")
RUNBOOK_DIR = os.environ.get("RUNBOOK_DIR", "/app/runbooks")

RUNBOOK_UPDATE = re.compile(r"<<<RUNBOOK_UPDATE\s*(.*?)\s*RUNBOOK_UPDATE>>>", re.DOTALL)
# Accept fenced ```yaml / bare "yaml" label / or raw body until FIX>>>.
FIX_BLOCK = re.compile(
    r"<<<FIX\s*\npath:\s*(\S+)\s*\n+"
    r"(?:```(?:yaml|yml)?\s*\n(.*?)```|yaml\s*\n(.*?)|(.*?))"
    r"\s*FIX>>>",
    re.DOTALL,
)
PLACEHOLDER_ENTRY = re.compile(
    r"^\s*-\s*\*\*Signal:\*\*\s*\.\.\.\s*"
    r"-\s*\*\*Root cause:\*\*\s*\.\.\.\s*"
    r"-\s*\*\*How it was confirmed:\*\*\s*\.\.\.\s*$",
    re.DOTALL,
)
VALUES_PATH = re.compile(r"^labs/[0-9]{2}-[a-z0-9-]+/apps/[a-z0-9-]+/values\.yaml$")
# Final answer usually starts at the last "1. Summary" (prompt text has an earlier copy).
REPORT_START = re.compile(
    r"(?m)^(?:#{1,3}\s*)?1\.\s*(?:\*\*)?Summary(?:\*\*)?(?!\*|\s*:\s*one sentence)",
)
SESSION_FOOTER = re.compile(r"(?m)^Resume this session with:\s*$")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("alert-bridge")

alerts: "queue.Queue[dict]" = queue.Queue()
last_seen: dict[str, float] = {}
last_seen_lock = threading.Lock()


def should_triage(alert: dict) -> bool:
    """Skips alerts already triaged in the dedup window, so an alert storm cannot burn the LLM budget."""
    fingerprint = alert.get("fingerprint") or json.dumps(alert.get("labels", {}), sort_keys=True)
    now = time.time()
    with last_seen_lock:
        if now - last_seen.get(fingerprint, 0) < DEDUP_WINDOW_SECONDS:
            return False
        last_seen[fingerprint] = now
    return True


def load_runbook(alertname: str) -> str:
    """Runbooks ship inside the image, because Hermes has no internet access to fetch runbook_url."""
    if not re.fullmatch(r"[A-Za-z0-9]{1,64}", alertname):
        return "No runbook is available for this alert."
    path = Path(RUNBOOK_DIR) / f"{alertname}.md"
    return path.read_text() if path.exists() else "No runbook is available for this alert."


def run_hermes(alert: dict) -> str:
    labels = alert.get("labels", {})
    prompt = PROMPT_TEMPLATE.replace("{{ALERT}}", json.dumps(alert, indent=2)).replace(
        "{{RUNBOOK}}", load_runbook(labels.get("alertname", ""))
    )
    log.info("triaging %s for pod %s", labels.get("alertname"), labels.get("pod"))
    result = subprocess.run(
        [*HERMES_CMD, prompt], capture_output=True, text=True, timeout=TRIAGE_TIMEOUT_SECONDS
    )
    if result.returncode != 0:
        log.error("hermes exited with %s: %s", result.returncode, result.stderr[-2000:])
    return result.stdout


def extract_report(stdout: str) -> str:
    """Keep the structured triage answer; drop prompt echo, reasoning, and session chrome.

    Hermes stdout often reprints the whole prompt and tool-call trace before the
    final Markdown report. PRs should only carry that report (+ FIX / runbook blocks).
    """
    text = stdout.strip()
    if not text:
        return text

    starts = [m.start() for m in REPORT_START.finditer(text)]
    if starts:
        text = text[starts[-1] :]
    elif "<<<FIX" in text:
        # No Summary heading; still try to keep from the last FIX onward with preamble.
        text = text[text.rfind("<<<FIX") :]

    foot = SESSION_FOOTER.search(text)
    if foot:
        text = text[: foot.start()]

    # Drop common Hermes TUI chrome lines.
    cleaned: list[str] = []
    for line in text.splitlines():
        if line.startswith(("┌─", "└─", "├─", "│", "╭─", "╰─", "─ ☤")):
            continue
        if line.strip() in {"Initializing agent...", "────────────────────────────────────────"}:
            continue
        cleaned.append(line)
    return "\n".join(cleaned).strip()


def pick_runbook_entry(report: str) -> str | None:
    candidates = [m.group(1).strip() for m in RUNBOOK_UPDATE.finditer(report)]
    for entry in reversed(candidates):
        if entry and not PLACEHOLDER_ENTRY.match(entry):
            return entry
    return None


def fix_body(match: re.Match) -> str:
    return next((g for g in match.groups()[1:] if g is not None), "").strip()


# The prompt shows the FIX shape with an example body; a copy of it is never a real fix.
PROMPT_EXAMPLE_FIXES = {fix_body(m) for m in FIX_BLOCK.finditer(PROMPT_TEMPLATE)}


def pick_fix(report: str) -> tuple[str, str] | None:
    """Return (path, values_yaml) from the last valid FIX block, or None."""
    matches = list(FIX_BLOCK.finditer(report))
    if not matches and "<<<FIX" in report:
        log.warning("report contains <<<FIX but no parseable FIX block (check fences/path)")
    for match in reversed(matches):
        path = match.group(1).strip()
        body = fix_body(match)
        content = body + "\n"
        if "<" in path or ">" in path:
            log.warning("ignoring FIX block with placeholder path: %s", path)
            continue
        if body in PROMPT_EXAMPLE_FIXES:
            log.warning("ignoring FIX block copied from the prompt example")
            continue
        if VALUES_PATH.match(path) and content.strip():
            return path, content
        log.warning("ignoring FIX block with disallowed path or empty body: %s", path)
    return None


def post_bot(path: str, payload: dict) -> None:
    if not RUNBOOK_BOT_URL:
        return
    body = json.dumps(payload).encode()
    request = urllib.request.Request(
        f"{RUNBOOK_BOT_URL}{path}",
        data=body,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            log.info("runbook-bot %s: %s", path, response.read().decode())
    except urllib.error.HTTPError as error:
        log.warning("runbook-bot %s rejected: %s", path, error.read().decode())
    except urllib.error.URLError as error:
        log.warning("runbook-bot %s unreachable: %s", path, error)


def worker() -> None:
    while True:
        alert = alerts.get()
        try:
            raw = run_hermes(alert)
            report = extract_report(raw)
            # FIX / runbook markers are parsed from raw in case chrome trimming missed them,
            # but PRs only receive the cleaned report.
            parse_from = raw if ("<<<FIX" in raw or "<<<RUNBOOK_UPDATE" in raw) else report
            REPORTS_DIR.mkdir(parents=True, exist_ok=True)
            labels = alert.get("labels", {})
            name = f"{labels.get('alertname', 'alert')}-{int(time.time())}.md"
            (REPORTS_DIR / name).write_text(report)
            log.info("triage report (%d→%d chars):\n%s", len(raw), len(report), report)

            if not report:
                log.warning("hermes returned no report; skipping PRs")
                continue
            if not RUNBOOK_BOT_URL:
                continue

            entry = pick_runbook_entry(parse_from)
            post_bot("/triage-pr", {
                "alertname": labels.get("alertname", ""),
                "pod": labels.get("pod", ""),
                "namespace": labels.get("namespace", ""),
                "report": report,
                "entry": entry or "",
            })

            fix = pick_fix(parse_from)
            if fix:
                path, content = fix
                post_bot("/fix-pr", {
                    "alertname": labels.get("alertname", ""),
                    "pod": labels.get("pod", ""),
                    "path": path,
                    "content": content,
                    "report": report,
                })
            else:
                log.info("no FIX block in report; skipping fix PR")
        except Exception:
            log.exception("triage failed")
        finally:
            alerts.task_done()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_error(404)

    def do_POST(self) -> None:
        if self.path != "/alerts":
            self.send_error(404)
            return
        payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        accepted = 0
        for alert in payload.get("alerts", []):
            if alert.get("status") == "firing" and should_triage(alert):
                alerts.put(alert)
                accepted += 1
        log.info("received %d alerts, queued %d", len(payload.get("alerts", [])), accepted)
        self.send_response(202)
        self.end_headers()

    def log_message(self, *args) -> None:
        pass


if __name__ == "__main__":
    threading.Thread(target=worker, daemon=True).start()
    log.info("listening on :%d", PORT)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
