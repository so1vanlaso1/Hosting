"""
proxy-logger.py
A tiny logging reverse-proxy that sits in front of llama-server.

Clients connect to this proxy (e.g. 0.0.0.0:8080); it forwards every request to
llama-server (e.g. 127.0.0.1:8081) and logs each model call -- the full input
messages, ALL request settings, and the model's output (answer + reasoning +
token usage) -- to two files in .\logs\:

    logs\model-calls.log     human-readable, one block per call
    logs\model-calls.jsonl   structured, one JSON object per call

Streaming (SSE) and non-streaming responses are both supported; streamed chunks
are passed through to the client in real time AND reassembled for the log.

Stdlib only -- no pip installs needed.

Usage:
    python proxy-logger.py --listen-host 0.0.0.0 --listen-port 8080 \
        --upstream-host 127.0.0.1 --upstream-port 8081 --log-dir logs
"""

import argparse
import http.client
import json
import os
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Endpoints whose bodies we parse + log in detail. Everything else (health, the
# web UI, static assets, /props ...) is proxied transparently without logging.
LOGGED_PATHS = (
    "/v1/chat/completions",
    "/v1/completions",
    "/completions",
    "/completion",
)

# Headers we must NOT copy verbatim when relaying.
HOP_BY_HOP = {
    "host", "content-length", "connection", "keep-alive",
    "proxy-connection", "transfer-encoding", "te", "trailer", "upgrade",
}

_log_lock = threading.Lock()
CFG = None  # filled in by main()


def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_response(content_type, body_bytes):
    """Reduce an upstream response (JSON or SSE) to content/reasoning/usage."""
    text = body_bytes.decode("utf-8", "replace")
    is_sse = "text/event-stream" in (content_type or "") or text.lstrip().startswith("data:")

    content, reasoning, finish, usage, model = "", "", None, None, None

    if is_sse:
        for line in text.splitlines():
            line = line.strip()
            if not line.startswith("data:"):
                continue
            data = line[len("data:"):].strip()
            if not data or data == "[DONE]":
                continue
            try:
                obj = json.loads(data)
            except json.JSONDecodeError:
                continue
            model = obj.get("model", model)
            if obj.get("usage"):
                usage = obj["usage"]
            for ch in obj.get("choices", []):
                delta = ch.get("delta", {}) or {}
                content += delta.get("content") or ""
                reasoning += delta.get("reasoning_content") or ""
                if "text" in ch:  # text-completion style streaming
                    content += ch.get("text") or ""
                if ch.get("finish_reason"):
                    finish = ch["finish_reason"]
    else:
        try:
            obj = json.loads(text)
        except json.JSONDecodeError:
            return {"raw": text[:4000]}
        model = obj.get("model")
        usage = obj.get("usage")
        choices = obj.get("choices", [])
        if choices:
            ch = choices[0]
            finish = ch.get("finish_reason")
            msg = ch.get("message", {}) or {}
            content = msg.get("content") or ch.get("text") or ""
            reasoning = msg.get("reasoning_content") or ""

    return {
        "model": model,
        "content": content,
        "reasoning_content": reasoning,
        "finish_reason": finish,
        "usage": usage,
    }


def _indent(text, pad="    "):
    """Indent every line of text; return a list of lines."""
    s = "" if text is None else str(text)
    return [pad + ln for ln in s.splitlines()] or [pad]


def _write_log(entry):
    """Append one call to both the JSONL and the human-readable log."""
    jsonl_path = os.path.join(CFG.log_dir, "model-calls.jsonl")
    text_path = os.path.join(CFG.log_dir, "model-calls.log")

    req = entry.get("request", {})
    messages = req.get("messages")
    prompt = req.get("prompt")
    settings = {k: v for k, v in req.items() if k not in ("messages", "prompt")}
    resp = entry.get("response", {})
    usage = resp.get("usage") or {}

    # UTC -> local time, for a friendlier header
    try:
        ts = (datetime.fromisoformat(entry["time"].replace("Z", "+00:00"))
              .astimezone().strftime("%Y-%m-%d %H:%M:%S"))
    except Exception:
        ts = entry.get("time", "")

    kind = "chat" if "chat" in entry["endpoint"] else "completion"
    header = f"{ts}   {kind}   {entry['duration_ms'] / 1000:.1f}s   client={entry['client']}"
    if usage:
        header += (f"   tokens in={usage.get('prompt_tokens', '?')} "
                   f"out={usage.get('completion_tokens', '?')} "
                   f"total={usage.get('total_tokens', '?')}")

    L = ["", "=" * 80, header, "=" * 80]

    # settings on one compact line
    if settings:
        kv = "  ".join(
            f"{k}={v if isinstance(v, (str, int, float, bool)) else json.dumps(v, ensure_ascii=False)}"
            for k, v in settings.items())
        L.append("SETTINGS  " + kv)

    # input
    if messages is not None:
        L.append("")
        L.append(f"INPUT  ({len(messages)} message(s))")
        for m in messages:
            role = str(m.get("role", "?")).upper()
            c = m.get("content", "")
            if isinstance(c, list):  # multimodal content parts
                c = json.dumps(c, ensure_ascii=False)
            L.append(f"  --- {role} ---")
            L += _indent(c)
    elif prompt is not None:
        L.append("")
        L.append("INPUT  (prompt)")
        L += _indent(prompt)

    # reasoning (only if present)
    if resp.get("reasoning_content"):
        L.append("")
        L.append("REASONING")
        L += _indent(resp["reasoning_content"])

    # output
    L.append("")
    L.append("OUTPUT")
    out = resp.get("content") or resp.get("raw") or ""
    if not out.strip():
        out = "(empty -- the max_tokens budget was likely consumed by reasoning; " \
              "raise max_tokens or disable thinking)"
    L += _indent(out)
    L.append("")

    block = "\n".join(L) + "\n"

    with _log_lock:
        with open(jsonl_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        # Human log: write a UTF-8 BOM on first creation so Windows editors
        # (Notepad, etc.) detect UTF-8 and render Vietnamese/emoji correctly.
        new_file = (not os.path.exists(text_path)) or os.path.getsize(text_path) == 0
        with open(text_path, "ab") as f:
            if new_file:
                f.write(b"\xef\xbb\xbf")
            f.write(block.encode("utf-8"))


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"  # body-until-close: simplest correct path for SSE + JSON
    server_version = "llama-logging-proxy/1.0"

    def log_message(self, *args):  # silence default per-request stderr spam
        pass

    def _relay(self):
        method = self.command
        path = self.path
        body = b""
        clen = int(self.headers.get("Content-Length", 0) or 0)
        if clen:
            body = self.rfile.read(clen)

        # Forward headers, minus hop-by-hop. Keep Authorization, Content-Type, etc.
        fwd_headers = {k: v for k, v in self.headers.items()
                       if k.lower() not in HOP_BY_HOP}

        should_log = method == "POST" and any(path.startswith(p) for p in LOGGED_PATHS)
        req_obj = None
        if should_log:
            try:
                req_obj = json.loads(body.decode("utf-8", "replace"))
            except json.JSONDecodeError:
                should_log = False

        started = datetime.now(timezone.utc)
        try:
            conn = http.client.HTTPConnection(
                CFG.upstream_host, CFG.upstream_port, timeout=CFG.timeout)
            conn.request(method, path, body=body, headers=fwd_headers)
            resp = conn.getresponse()
        except Exception as exc:  # upstream unreachable
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": f"proxy upstream error: {exc}"}).encode())
            return

        # Relay status + headers (drop hop-by-hop; we stream until close).
        self.send_response(resp.status)
        resp_ctype = resp.getheader("Content-Type", "")
        for k, v in resp.getheaders():
            if k.lower() in HOP_BY_HOP:
                continue
            self.send_header(k, v)
        self.end_headers()

        # Pump body through, flushing each chunk; tee into buffer if logging.
        captured = bytearray()
        try:
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
                if should_log:
                    captured += chunk
        except (BrokenPipeError, ConnectionResetError):
            pass  # client hung up mid-stream
        finally:
            conn.close()

        if should_log:
            duration_ms = int((datetime.now(timezone.utc) - started).total_seconds() * 1000)
            try:
                parsed = _parse_response(resp_ctype, bytes(captured))
                _write_log({
                    "time": _now_iso(),
                    "client": self.client_address[0],
                    "endpoint": path,
                    "stream": bool(req_obj.get("stream")),
                    "duration_ms": duration_ms,
                    "request": req_obj,
                    "response": parsed,
                })
            except Exception as exc:
                # never let logging break the proxy
                with _log_lock:
                    with open(os.path.join(CFG.log_dir, "model-calls.log"), "a",
                              encoding="utf-8") as f:
                        f.write(f"[proxy-logger error: {exc}]\n")

    # all methods funnel through _relay
    do_GET = _relay
    do_POST = _relay
    do_PUT = _relay
    do_DELETE = _relay
    do_OPTIONS = _relay
    do_HEAD = _relay


def main():
    global CFG
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen-host", default="0.0.0.0")
    ap.add_argument("--listen-port", type=int, default=8080)
    ap.add_argument("--upstream-host", default="127.0.0.1")
    ap.add_argument("--upstream-port", type=int, default=8081)
    ap.add_argument("--log-dir", default="logs")
    ap.add_argument("--timeout", type=int, default=600)
    CFG = ap.parse_args()

    os.makedirs(CFG.log_dir, exist_ok=True)

    httpd = ThreadingHTTPServer((CFG.listen_host, CFG.listen_port), ProxyHandler)
    print(f"[proxy] logging {CFG.listen_host}:{CFG.listen_port} "
          f"-> {CFG.upstream_host}:{CFG.upstream_port}")
    print(f"[proxy] writing logs to {os.path.abspath(CFG.log_dir)}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[proxy] shutting down")
        httpd.shutdown()


if __name__ == "__main__":
    main()
