"""Opens GitHub PRs on behalf of Hermes, so the agent itself never holds a token.

Two endpoints:

- POST /triage-pr — triage report (+ optional runbook learning) as one PR
- POST /fix-pr — proposed values.yaml fix as a separate PR

Both require human review via branch protection. Path allowlists and rate limits
bound what the bot can change.
"""

import base64
import json
import logging
import os
import re
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import StringIO

from ruamel.yaml import YAML
from ruamel.yaml.comments import CommentedMap, CommentedSeq
from ruamel.yaml.error import YAMLError

PORT = int(os.environ.get("PORT", "8080"))
GITHUB_TOKEN = os.environ["GITHUB_TOKEN"]
GITHUB_REPO = os.environ["GITHUB_REPO"]
RUNBOOK_DIR = "labs/02-knowledge-base/runbooks"
TRIAGE_REPORT_DIR = "labs/03-hermes-triage/triage-reports"
MAX_ENTRY_CHARS = 4000
MAX_REPORT_CHARS = 50000
MAX_VALUES_CHARS = 100_000
MAX_PRS_PER_HOUR = int(os.environ.get("MAX_PRS_PER_HOUR", "10"))

ALERTNAME = re.compile(r"^[A-Za-z0-9]{1,64}$")
SAFE_POD = re.compile(r"[^a-z0-9.-]")
VALUES_PATH = re.compile(r"^labs/[0-9]{2}-[a-z0-9-]+/apps/[a-z0-9-]+/values\.yaml$")

INJECTION_PATTERNS: list[tuple[str, str]] = [
    (r"ignore (all )?(previous|prior|earlier) (instructions|prompts|directives)", "instruction override"),
    (r"(you must|you should|do (not|now))\s+(run|execute|delete|post|send|curl|fetch)", "imperative action"),
    (r"send (your |the )?(environment|env vars?|secrets?|credentials?|tokens?|api keys?|keys?|passwords?)", "secret exfiltration"),
    (r"(api[_ ]?key|secret|password|token)\b.*\b(send|post|upload|exfiltrat)", "credential reference near exfil verb"),
    (r"https?://\S+", "embedded URL"),
    (r"\b(curl|wget|nc\s|netcat)\b", "network tool reference"),
    (r"system\s+(notice|prompt|message)\s+to\s+(ai|agent|automated)", "fake system notice"),
]
INJECTION_REGEXES = [(re.compile(p, re.IGNORECASE), label) for p, label in INJECTION_PATTERNS]

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("runbook-bot")

recent_prs: list[float] = []
recent_lock = threading.Lock()


class Rejected(Exception):
    pass


def scan_for_injection(text: str) -> list[str]:
    found: list[str] = []
    for rx, label in INJECTION_REGEXES:
        if rx.search(text) and label not in found:
            found.append(label)
    return found


def allow_pr() -> bool:
    now = time.time()
    with recent_lock:
        recent_prs[:] = [t for t in recent_prs if now - t < 3600]
        if len(recent_prs) >= MAX_PRS_PER_HOUR:
            return False
        recent_prs.append(now)
    return True


def github(method: str, path: str, body: dict | None = None) -> dict:
    request = urllib.request.Request(
        f"https://api.github.com/repos/{GITHUB_REPO}{path}",
        method=method,
        data=json.dumps(body).encode() if body else None,
        headers={
            "Authorization": f"Bearer {GITHUB_TOKEN}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read() or b"{}")


def warning_preamble(warnings: list[str]) -> str:
    if not warnings:
        return ""
    return (
        "## WARNING: instruction-like text detected\n\n"
        "The platform flagged: "
        + ", ".join(f"`{w}`" for w in warnings)
        + ".\n\n"
        "Review as UNTRUSTED INPUT before merging. This may be prompt injection "
        "from logs or alert text.\n\n---\n\n"
    )


def create_branch(prefix: str, stamp: str) -> tuple[str, str]:
    base = github("GET", "")["default_branch"]
    base_sha = github("GET", f"/git/ref/heads/{base}")["object"]["sha"]
    branch = f"{prefix}/{stamp}"
    github("POST", "/git/refs", {"ref": f"refs/heads/{branch}", "sha": base_sha})
    return base, branch


def put_file(path: str, branch: str, message: str, content: str, sha: str | None) -> None:
    body: dict = {
        "message": message,
        "content": base64.b64encode(content.encode()).decode(),
        "branch": branch,
    }
    if sha:
        body["sha"] = sha
    github("PUT", f"/contents/{path}", body)


def get_file(path: str, ref: str) -> tuple[str, str] | None:
    try:
        current = github("GET", f"/contents/{path}?ref={ref}")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise
    return base64.b64decode(current["content"]).decode(), current["sha"]


def _tail_slot(parent, key) -> tuple[dict, object, int]:
    """Locate the comment lines after parent[key].

    ruamel stores a comment written above a key as the trailing comment of
    whatever comes before it, so these lines describe the next key.
    """
    value = parent[key]
    if isinstance(value, (CommentedMap, CommentedSeq)) and value:
        return _tail_slot(value, list(value)[-1] if isinstance(value, CommentedMap) else len(value) - 1)
    return parent.ca.items, key, 0 if isinstance(parent, CommentedSeq) else 2


def _get_tail(parent, key):
    items, slot_key, index = _tail_slot(parent, key)
    return items.get(slot_key, [None] * 4)[index]


def _set_tail(parent, key, token) -> None:
    items, slot_key, index = _tail_slot(parent, key)
    items.setdefault(slot_key, [None] * 4)[index] = token


def _merge_keys(target: CommentedMap, patch: dict) -> None:
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(target.get(key), dict):
            _merge_keys(target[key], value)
            continue
        tail = _get_tail(target, key) if key in target else None
        if value is None:
            if key not in target:
                continue
            keys = list(target)
            position = keys.index(key)
            del target[key]
            target.ca.items.pop(key, None)
            if position:
                _set_tail(target, keys[position - 1], tail)
        else:
            target[key] = value
            if tail is not None:
                _set_tail(target, key, tail)


def merge_values(current: str, proposed: str) -> str:
    """Merge Hermes's proposed keys into the current values.yaml.

    Hermes cannot read the repository, so it proposes only the keys it changes.
    Nested mappings merge, lists and scalars replace, and null removes a key.
    Comments and quoting in the current file are kept.
    """
    rt = YAML()
    rt.preserve_quotes = True
    rt.indent(mapping=2, sequence=4, offset=2)
    rt.width = 4096
    try:
        doc = rt.load(current)
        patch = rt.load(proposed)
    except YAMLError as error:
        raise Rejected(f"proposed fix is not valid YAML: {error}") from error
    if not isinstance(doc, dict):
        raise Rejected("target file is not a YAML mapping")
    if not isinstance(patch, dict) or not patch:
        raise Rejected("proposed fix must be a YAML mapping of the keys to change")
    _merge_keys(doc, patch)
    out = StringIO()
    rt.dump(doc, out)
    merged = out.getvalue()
    if merged == current:
        raise Rejected("proposed fix does not change the file")
    return merged


def open_triage_pr(alertname: str, pod: str, namespace: str, report: str, entry: str) -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    base, branch = create_branch(f"hermes-triage/{alertname}", stamp)

    scan_text = report + ("\n" + entry if entry else "")
    warnings = scan_for_injection(scan_text)
    if warnings:
        log.warning("triage content flagged: %s", ", ".join(warnings))

    report_path = f"{TRIAGE_REPORT_DIR}/{stamp}-{alertname}-{pod}.md"
    report_body = (
        f"# Hermes triage: {alertname}\n\n"
        f"- **When:** {stamp} UTC\n"
        f"- **Namespace:** {namespace or 'unknown'}\n"
        f"- **Pod:** {pod}\n"
        f"- **Repo:** `{GITHUB_REPO}`\n\n"
        "---\n\n"
        f"{report.strip()}\n"
    )
    put_file(
        report_path,
        branch,
        f"triage: report for {alertname} ({pod})",
        report_body,
        sha=None,
    )

    if entry:
        runbook_path = f"{RUNBOOK_DIR}/{alertname}.md"
        existing = get_file(runbook_path, base)
        if existing is None:
            raise Rejected(f"no runbook exists for {alertname}")
        content, sha = existing
        content = content.replace("_No entries yet._\n", "")
        content = content.rstrip("\n") + f"\n\n### {stamp} ({pod})\n\n{entry}\n"
        put_file(
            runbook_path,
            branch,
            f"runbook: learnings from {alertname} triage",
            content,
            sha=sha,
        )

    body = warning_preamble(warnings) + (
        f"## Hermes triage report\n\n"
        f"Alert `{alertname}` on pod `{pod}`"
        + (f" in `{namespace}`" if namespace else "")
        + ".\n\n"
        f"Full report committed at `{report_path}`"
        + (" and a runbook learning was appended." if entry else ".")
        + "\n\n"
        "### Report (from Hermes)\n\n"
        f"{report.strip()[:MAX_REPORT_CHARS]}\n\n"
        "---\n\n"
        "Opened by runbook-bot on behalf of Hermes. Hermes does not hold a GitHub token. "
        "Do not merge without human review."
    )

    pr = github("POST", "/pulls", {
        "title": f"Hermes triage: {alertname} ({pod})",
        "head": branch,
        "base": base,
        "body": body,
    })
    return pr.get("html_url", "")


def open_fix_pr(alertname: str, pod: str, path: str, content: str, report: str) -> str:
    if not VALUES_PATH.match(path):
        raise Rejected(f"path not allowlisted: {path}")
    if not content.strip() or len(content) > MAX_VALUES_CHARS:
        raise Rejected(f"values content must be 1-{MAX_VALUES_CHARS} characters")

    base = github("GET", "")["default_branch"]
    existing = get_file(path, base)
    if existing is None:
        raise Rejected(f"target file does not exist: {path}")
    current, sha = existing
    merged = merge_values(current, content)

    warnings = scan_for_injection(content + "\n" + report)
    if warnings:
        log.warning("fix PR content flagged: %s", ", ".join(warnings))

    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    base, branch = create_branch(f"hermes-fix/{alertname}", stamp)
    put_file(path, branch, f"fix: Hermes proposal for {alertname}", merged, sha=sha)

    # Keep the fix PR short: summary-style context only (full transcript stays out).
    context = report.strip()
    if len(context) > 6000:
        context = context[:6000].rstrip() + "\n\n_(truncated)_"

    body = warning_preamble(warnings) + (
        f"## Proposed fix from Hermes\n\n"
        f"Alert `{alertname}` on pod `{pod}`.\n\n"
        f"This PR merges the keys Hermes proposed after triage into `{path}`. "
        "Every other key is unchanged.\n\n"
        f"### Proposed keys\n\n```yaml\n{content.strip()}\n```\n\n"
        "### Triage report\n\n"
        f"{context}\n\n"
        "---\n\n"
        "Opened by runbook-bot on behalf of Hermes. Validate with "
        "`./labs/01-golden-path/scripts/validate-apps.sh` before merge. "
        "Hermes does not hold a GitHub token."
    )

    pr = github("POST", "/pulls", {
        "title": f"Hermes fix: {alertname} → {path}",
        "head": branch,
        "base": base,
        "body": body,
    })
    return pr.get("html_url", "")


class Handler(BaseHTTPRequestHandler):
    def reply(self, status: int, body: dict) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self.reply(200, {"status": "ok"})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self) -> None:
        try:
            payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            if not allow_pr():
                raise Rejected(f"rate limit of {MAX_PRS_PER_HOUR} PRs per hour reached")

            alertname = str(payload.get("alertname", ""))
            pod = SAFE_POD.sub("", str(payload.get("pod", "unknown")).lower())[:253] or "unknown"
            if not ALERTNAME.match(alertname):
                raise Rejected("invalid alertname")

            if self.path == "/triage-pr":
                report = str(payload.get("report", "")).strip()
                entry = str(payload.get("entry", "")).strip()
                namespace = str(payload.get("namespace", ""))[:253]
                if not report or len(report) > MAX_REPORT_CHARS:
                    raise Rejected(f"report must be 1-{MAX_REPORT_CHARS} characters")
                if entry and len(entry) > MAX_ENTRY_CHARS:
                    raise Rejected(f"entry must be at most {MAX_ENTRY_CHARS} characters")
                url = open_triage_pr(alertname, pod, namespace, report, entry)
                log.info("opened triage PR %s", url)
                self.reply(201, {"pr": url, "kind": "triage"})
                return

            if self.path == "/fix-pr":
                path = str(payload.get("path", "")).strip()
                content = str(payload.get("content", ""))
                report = str(payload.get("report", "")).strip()
                if not report:
                    report = f"Fix proposed for alert {alertname} on pod {pod}."
                if len(report) > MAX_REPORT_CHARS:
                    report = report[:MAX_REPORT_CHARS]
                url = open_fix_pr(alertname, pod, path, content, report)
                log.info("opened fix PR %s", url)
                self.reply(201, {"pr": url, "kind": "fix"})
                return

            # Back-compat: old bridge only sent runbook entries here.
            if self.path == "/runbook-entry":
                entry = str(payload.get("entry", "")).strip()
                if not entry or len(entry) > MAX_ENTRY_CHARS:
                    raise Rejected(f"entry must be 1-{MAX_ENTRY_CHARS} characters")
                url = open_triage_pr(
                    alertname,
                    pod,
                    str(payload.get("namespace", "")),
                    f"(legacy /runbook-entry) Learning for `{alertname}`.\n\n{entry}",
                    entry,
                )
                self.reply(201, {"pr": url, "kind": "triage"})
                return

            self.reply(404, {"error": "not found"})
        except Rejected as error:
            log.warning("rejected: %s", error)
            self.reply(400, {"error": str(error)})
        except Exception:
            log.exception("failed to open PR")
            self.reply(502, {"error": "github request failed"})

    def log_message(self, *args) -> None:
        pass


if __name__ == "__main__":
    log.info("listening on :%d for %s", PORT, GITHUB_REPO)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
