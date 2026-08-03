#!/usr/bin/env python3
"""Volcano Codex Observer.

Zero-dependency Responses API proxy and dashboard server.
"""

from __future__ import annotations

import json
import mimetypes
import os
import re
import sys
import time
import traceback
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from responses_protocol import ResponsesStreamNormalizer


HOST = os.environ.get("OBSERVER_HOST", "127.0.0.1")
PORT = int(os.environ.get("OBSERVER_PORT", "17860"))
UPSTREAM_BASE = os.environ.get(
    "ARK_UPSTREAM_BASE", "https://ark.cn-beijing.volces.com/api/v3"
).rstrip("/")
LOG_DIR = Path(os.environ.get("OBSERVER_LOG_DIR", Path.cwd() / ".ark-observer")).resolve()
STATIC_DIR = Path(__file__).resolve().parent / "public"
FILTER_REASONING_SUMMARY = os.environ.get("OBSERVER_FILTER_REASONING_SUMMARY") == "1"
MAX_BODY_BYTES = int(os.environ.get("OBSERVER_MAX_BODY_BYTES", str(25 * 1024 * 1024)))
REQUESTS_DIR = LOG_DIR / "requests"
ARK_MODEL = os.environ.get("ARK_MODEL", "volcengine-ark")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def ensure_dirs() -> None:
    REQUESTS_DIR.mkdir(parents=True, exist_ok=True)


def safe_file_name(value: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_.-]", "_", value)


def request_prefix(request_id: str) -> Path:
    return REQUESTS_DIR / safe_file_name(request_id)


def read_json_if_exists(path: Path) -> Any | None:
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def parse_json_maybe(value: str | bytes) -> Any | None:
    try:
        if isinstance(value, bytes):
            value = value.decode("utf-8")
        return json.loads(value)
    except Exception:
        return None


def models_payload() -> dict[str, Any]:
    return {
        "models": [
            {
                "slug": ARK_MODEL,
                "display_name": ARK_MODEL,
                "description": "Volcengine Ark model served through volcano-codex observer",
                "default_reasoning_level": "medium",
                "supported_reasoning_levels": [
                    {"effort": "low", "description": "low"},
                    {"effort": "medium", "description": "medium"},
                    {"effort": "high", "description": "high"},
                ],
                "shell_type": "shell_command",
                "visibility": "list",
                "supported_in_api": True,
                "priority": 1,
                "availability_nux": None,
                "upgrade": None,
                "base_instructions": "",
                "supports_reasoning_summary_parameter": True,
                "default_reasoning_summary": "auto",
                "support_verbosity": False,
                "default_verbosity": None,
                "apply_patch_tool_type": None,
                "web_search_tool_type": "text",
                "truncation_policy": {"mode": "bytes", "limit": 10000},
                "supports_parallel_tool_calls": False,
                "supports_image_detail_original": False,
                "context_window": 272000,
                "max_context_window": 272000,
                "auto_compact_token_limit": None,
                "comp_hash": None,
                "effective_context_window_percent": 95,
                "experimental_supported_tools": [],
                "input_modalities": ["text"],
                "supports_search_tool": False,
                "use_responses_lite": False,
                "auto_review_model_override": None,
                "tool_mode": None,
                "multi_agent_version": None,
            }
        ],
    }


def redact_headers(headers: dict[str, str]) -> dict[str, str]:
    redacted: dict[str, str] = {}
    for key, value in headers.items():
        if re.search(r"authorization|api[-_]key|token|cookie", key, re.I):
            redacted[key] = "<redacted>"
        else:
            redacted[key] = value
    return redacted


def parse_sse_block(block: str) -> tuple[str, str]:
    event = ""
    data: list[str] = []
    for line in block.splitlines():
        if line.startswith("event:"):
            event = line[6:].strip()
        elif line.startswith("data:"):
            data.append(line[5:].lstrip())
    return event, "\n".join(data)


def format_sse_block(event: str, data: str) -> bytes:
    lines: list[str] = []
    if event:
        lines.append(f"event: {event}")
    if data:
        lines.extend(f"data: {line}" for line in data.split("\n"))
    return ("\n".join(lines) + "\n\n").encode("utf-8")


def make_initial_summary(
    request_id: str,
    method: str,
    request_path: str,
    parsed_body: dict[str, Any] | None,
    body_bytes: int,
) -> dict[str, Any]:
    return {
        "schema_version": "observer.summary.v1",
        "source": {"kind": "proxy"},
        "request_id": request_id,
        "started_at": now_iso(),
        "completed_at": None,
        "method": method,
        "path": request_path,
        "upstream_url": f"{UPSTREAM_BASE}/responses",
        "status": None,
        "model": parsed_body.get("model") if parsed_body else None,
        "input_items": len(parsed_body.get("input", []))
        if parsed_body and isinstance(parsed_body.get("input"), list)
        else None,
        "tool_count": len(parsed_body.get("tools", []))
        if parsed_body and isinstance(parsed_body.get("tools"), list)
        else 0,
        "request_body_bytes": body_bytes,
        "response_bytes": 0,
        "event_count": 0,
        "event_types": {},
        "latency_ms": None,
        "first_event_ms": None,
        "ttft_ms": None,
        "completed_event_ms": None,
        "input_tokens": None,
        "output_tokens": None,
        "total_tokens": None,
        "cached_tokens": None,
        "cache_write_tokens": None,
        "reasoning_output_tokens": None,
        "cache_hit_ratio": None,
        "output_text_preview": "",
        "tool_calls": [],
        "errors": [],
        "filtered_reasoning_summary": FILTER_REASONING_SUMMARY,
    }


def update_usage(summary: dict[str, Any], usage: dict[str, Any] | None) -> None:
    if not isinstance(usage, dict):
        return
    aggregate = usage.get("total")
    if isinstance(aggregate, dict):
        usage = aggregate
    summary["input_tokens"] = usage.get(
        "input_tokens", usage.get("inputTokens", summary.get("input_tokens"))
    )
    summary["output_tokens"] = usage.get(
        "output_tokens", usage.get("outputTokens", summary.get("output_tokens"))
    )
    summary["total_tokens"] = usage.get(
        "total_tokens", usage.get("totalTokens", summary.get("total_tokens"))
    )
    if summary["total_tokens"] is None and (
        summary["input_tokens"] is not None or summary["output_tokens"] is not None
    ):
        summary["total_tokens"] = (summary["input_tokens"] or 0) + (
            summary["output_tokens"] or 0
        )
    details = usage.get("input_tokens_details") or {}
    summary["cached_tokens"] = details.get(
        "cached_tokens",
        details.get(
            "cache_read_tokens",
            usage.get(
                "cached_input_tokens",
                usage.get("cachedInputTokens", summary.get("cached_tokens")),
            ),
        ),
    )
    summary["cache_write_tokens"] = details.get(
        "cache_write_tokens",
        details.get(
            "cache_write_input_tokens",
            usage.get(
                "cache_write_tokens",
                usage.get(
                    "cache_write_input_tokens",
                    usage.get(
                        "cacheWriteInputTokens", summary.get("cache_write_tokens")
                    ),
                ),
            ),
        ),
    )
    summary["reasoning_output_tokens"] = usage.get(
        "reasoning_output_tokens",
        usage.get("reasoningOutputTokens", summary.get("reasoning_output_tokens")),
    )
    if summary.get("input_tokens") and summary.get("cached_tokens") is not None:
        summary["cache_hit_ratio"] = round(
            summary["cached_tokens"] / summary["input_tokens"], 4
        )


def observe_event(
    summary: dict[str, Any],
    event_name: str,
    payload: Any,
    elapsed_ms: int,
) -> None:
    summary["event_count"] += 1
    event_types = summary["event_types"]
    event_types[event_name or "<none>"] = event_types.get(event_name or "<none>", 0) + 1
    if summary["first_event_ms"] is None:
        summary["first_event_ms"] = elapsed_ms
    if not isinstance(payload, dict):
        return

    if event_name == "response.output_text.delta":
        if summary["ttft_ms"] is None:
            summary["ttft_ms"] = elapsed_ms
        summary["output_text_preview"] = (
            summary.get("output_text_preview", "") + str(payload.get("delta", ""))
        )[:5000]

    if event_name == "response.function_call_arguments.delta" and summary["ttft_ms"] is None:
        summary["ttft_ms"] = elapsed_ms

    if event_name in {"response.output_item.added", "response.output_item.done"}:
        item = payload.get("item")
        if isinstance(item, dict) and item.get("type") == "function_call":
            call = {
                "call_id": item.get("call_id"),
                "name": item.get("name"),
                "arguments": item.get("arguments", ""),
                "status": item.get("status"),
            }
            existing = next(
                (entry for entry in summary["tool_calls"] if entry.get("call_id") == call["call_id"]),
                None,
            )
            if existing:
                existing.update(call)
            else:
                summary["tool_calls"].append(call)

    if event_name == "response.completed":
        summary["completed_event_ms"] = elapsed_ms
        summary["completed_at"] = now_iso()
        response = payload.get("response") or {}
        if isinstance(response, dict):
            summary["model"] = response.get("model", summary.get("model"))
            update_usage(summary, response.get("usage"))

    if event_name in {"turn.completed", "turn/completed"}:
        usage = payload.get("usage")
        if not isinstance(usage, dict):
            usage = (payload.get("turn") or {}).get("usage")
        update_usage(summary, usage)
        summary["completed_event_ms"] = elapsed_ms
        summary["completed_at"] = now_iso()

    if event_name in {"item.agent_message.delta", "item/agentMessage/delta"}:
        delta = payload.get("delta", "")
        if summary["ttft_ms"] is None:
            summary["ttft_ms"] = elapsed_ms
        summary["output_text_preview"] = (
            summary.get("output_text_preview", "") + str(delta)
        )[:5000]

    if event_name in {"item.completed", "item/completed"}:
        item = payload.get("item")
        if isinstance(item, dict) and item.get("type") in {
            "agent_message",
            "agentMessage",
        }:
            text = item.get("text", "")
            if text and not summary.get("output_text_preview"):
                summary["output_text_preview"] = str(text)[:5000]

    if event_name == "thread/tokenUsage/updated":
        update_usage(summary, payload.get("tokenUsage"))


def list_summaries() -> list[dict[str, Any]]:
    ensure_dirs()
    summaries = [
        read_json_if_exists(path)
        for path in REQUESTS_DIR.glob("*.summary.json")
    ]
    return sorted(
        [item for item in summaries if item],
        key=lambda item: str(item.get("started_at", "")),
        reverse=True,
    )


def load_events(request_id: str) -> list[Any]:
    events_path = request_prefix(request_id).with_suffix(".events.jsonl")
    if not events_path.exists():
        return []
    events: list[Any] = []
    for line in events_path.read_text(encoding="utf-8").splitlines():
        parsed = parse_json_maybe(line)
        if parsed is not None:
            events.append(parsed)
    return events


def import_observer_log(envelope: dict[str, Any]) -> dict[str, Any]:
    if envelope.get("schema_version") != "observer.import.v1":
        raise ValueError("schema_version must be observer.import.v1")
    source = envelope.get("source")
    request_capture = envelope.get("request")
    events = envelope.get("events")
    if not isinstance(source, dict) or not source.get("kind"):
        raise ValueError("source.kind is required")
    if not isinstance(request_capture, dict):
        raise ValueError("request must be an object")
    if not isinstance(events, list):
        raise ValueError("events must be an array")

    request_id = str(
        envelope.get("request_id")
        or f"import-{datetime.now().strftime('%Y%m%d%H%M%S')}-{uuid.uuid4().hex[:8]}"
    )
    prefix = request_prefix(request_id)
    if prefix.with_suffix(".summary.json").exists() and envelope.get("mode") != "replace":
        raise ValueError(f"request_id already exists: {request_id}")

    body = request_capture.get("body")
    parsed_body = body if isinstance(body, dict) else None
    body_bytes = len(json.dumps(body, ensure_ascii=False).encode("utf-8")) if body is not None else 0
    summary = make_initial_summary(
        request_id,
        str(request_capture.get("method", "IMPORT")),
        str(request_capture.get("path", "/api/import")),
        parsed_body,
        body_bytes,
    )
    summary["schema_version"] = "observer.summary.v1"
    summary["source"] = {
        **source,
        "imported_at": now_iso(),
    }
    if isinstance(envelope.get("thread"), dict):
        summary["thread"] = envelope["thread"]
    summary["status"] = request_capture.get("status")
    summary["upstream_url"] = request_capture.get("upstream_url")

    normalized_records: list[dict[str, Any]] = []
    normalizer = ResponsesStreamNormalizer()
    for index, record in enumerate(events):
        if not isinstance(record, dict):
            raise ValueError(f"events[{index}] must be an object")
        elapsed_ms = int(record.get("elapsed_ms") or 0)
        event_name = str(record.get("event") or record.get("method") or "")
        payload = record.get("data", record.get("params", record.get("payload")))
        frame = normalizer.normalize(event_name, payload)
        normalized_record = {
            "schema_version": "observer.event.v1",
            "ts": str(record.get("ts") or now_iso()),
            "elapsed_ms": elapsed_ms,
            "event": frame.event,
            "data": frame.payload,
            "source_event": event_name,
            "normalizations": frame.changes,
            "protocol_warnings": frame.warnings,
        }
        normalized_records.append(normalized_record)
        observe_event(summary, frame.event, frame.payload, elapsed_ms)

    if summary["status"] is None:
        summary["status"] = 200 if summary["completed_at"] else "imported"
    supplied = envelope.get("summary")
    if isinstance(supplied, dict):
        for key in ("latency_ms", "first_event_ms", "ttft_ms", "completed_event_ms"):
            if supplied.get(key) is not None:
                summary[key] = supplied[key]
    summary["completed_at"] = summary.get("completed_at") or now_iso()

    if envelope.get("mode") == "dry_run":
        return {"request_id": request_id, "status": "validated", "summary": summary}

    ensure_dirs()
    prefix.with_suffix(".request.json").write_text(
        json.dumps(
            {
                "schema_version": "observer.request.v1",
                "request_id": request_id,
                "captured_at": now_iso(),
                "source": source,
                "headers": redact_headers(request_capture.get("headers") or {}),
                "body": body,
                "raw": request_capture.get("raw"),
            },
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    prefix.with_suffix(".events.jsonl").write_text(
        "".join(json.dumps(record, ensure_ascii=False) + "\n" for record in normalized_records),
        encoding="utf-8",
    )
    prefix.with_suffix(".summary.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    return {"request_id": request_id, "status": "imported", "summary": summary}


class ObserverHandler(BaseHTTPRequestHandler):
    server_version = "VolcanoCodexObserver/0.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def send_json(self, status: int, value: Any) -> None:
        body = json.dumps(value, indent=2, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("content-length", str(len(body)))
        self.send_header("access-control-allow-origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def send_text(self, status: int, value: str, content_type: str = "text/plain; charset=utf-8") -> None:
        body = value.encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_header("access-control-allow-origin", "*")
        self.send_header("access-control-allow-methods", "GET,POST,OPTIONS")
        self.send_header("access-control-allow-headers", "content-type,authorization,user-agent")
        self.end_headers()

    def do_GET(self) -> None:
        ensure_dirs()
        clean_path = self.path.split("?", 1)[0]
        if clean_path == "/health":
            self.send_json(
                200,
                {
                    "ok": True,
                    "upstream_base": UPSTREAM_BASE,
                    "log_dir": str(LOG_DIR),
                    "filter_reasoning_summary": FILTER_REASONING_SUMMARY,
                    "runtime": "python",
                },
            )
            return
        if clean_path in {"/api/v3/models", "/models"}:
            self.send_json(200, models_payload())
            return
        if clean_path == "/api/requests":
            self.send_json(200, {"requests": list_summaries()})
            return
        if clean_path.startswith("/api/requests/"):
            request_id = Path(clean_path).name
            summary = read_json_if_exists(request_prefix(request_id).with_suffix(".summary.json"))
            if not summary:
                self.send_json(404, {"error": "request not found"})
                return
            self.send_json(
                200,
                {
                    "summary": summary,
                    "request": read_json_if_exists(request_prefix(request_id).with_suffix(".request.json")),
                    "events": load_events(request_id),
                },
            )
            return
        self.serve_static(clean_path)

    def do_POST(self) -> None:
        clean_path = self.path.split("?", 1)[0]
        if clean_path in {"/api/v3/responses", "/responses"}:
            self.handle_proxy()
            return
        if clean_path == "/api/import":
            try:
                body = self.read_body()
                envelope = parse_json_maybe(body)
                if not isinstance(envelope, dict):
                    raise ValueError("import body must be a JSON object")
                result = import_observer_log(envelope)
                self.send_json(200, result)
            except ValueError as error:
                self.send_json(400, {"error": str(error)})
            return
        self.send_json(404, {"error": "not found"})

    def serve_static(self, clean_path: str) -> None:
        relative = "index.html" if clean_path == "/" else clean_path.lstrip("/")
        target = (STATIC_DIR / relative).resolve()
        try:
            target.relative_to(STATIC_DIR.resolve())
        except ValueError:
            self.send_text(403, "Forbidden")
            return
        if not target.is_file():
            self.send_text(404, "Not found")
            return
        content_type = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        body = target.read_bytes()
        self.send_response(200)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_body(self) -> bytes:
        length = int(self.headers.get("content-length") or "0")
        if length > MAX_BODY_BYTES:
            raise ValueError(f"request body exceeds {MAX_BODY_BYTES} bytes")
        return self.rfile.read(length)

    def handle_proxy(self) -> None:
        ensure_dirs()
        started = time.time()
        request_id = f"{datetime.now().strftime('%Y%m%d%H%M%S')}-{uuid.uuid4().hex[:8]}"
        prefix = request_prefix(request_id)
        events_path = prefix.with_suffix(".events.jsonl")
        summary: dict[str, Any] | None = None

        try:
            body = self.read_body()
            parsed_body = parse_json_maybe(body)
            if parsed_body is not None and not isinstance(parsed_body, dict):
                parsed_body = None
            summary = make_initial_summary(
                request_id,
                self.command,
                self.path,
                parsed_body,
                len(body),
            )

            prefix.with_suffix(".request.json").write_text(
                json.dumps(
                    {
                        "request_id": request_id,
                        "captured_at": now_iso(),
                        "headers": redact_headers(dict(self.headers.items())),
                        "body": parsed_body if parsed_body is not None else body.decode("utf-8", "replace"),
                    },
                    indent=2,
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )

            upstream_headers = {
                "content-type": self.headers.get("content-type", "application/json"),
                "accept": self.headers.get("accept", "text/event-stream"),
                "user-agent": self.headers.get(
                    "user-agent", os.environ.get("USER_AGENT", "volcano-codex-observer/0.1")
                ),
            }
            auth = None
            if os.environ.get("ARK_API_KEY"):
                auth = f"Bearer {os.environ['ARK_API_KEY']}"
            else:
                auth = self.headers.get("authorization")
            if auth:
                upstream_headers["authorization"] = auth

            request = urllib.request.Request(
                f"{UPSTREAM_BASE}/responses",
                data=body,
                headers=upstream_headers,
                method="POST",
            )

            with urllib.request.urlopen(request, timeout=300) as upstream, events_path.open(
                "a", encoding="utf-8"
            ) as events_file:
                normalizer = ResponsesStreamNormalizer()
                summary["status"] = upstream.status
                self.send_response(upstream.status)
                self.send_header(
                    "content-type",
                    upstream.headers.get("content-type", "text/event-stream; charset=utf-8"),
                )
                self.send_header("cache-control", "no-cache")
                self.send_header("x-observer-request-id", request_id)
                self.end_headers()

                pending = ""
                while True:
                    chunk = upstream.read(4096)
                    if not chunk:
                        break
                    text_chunk = chunk.decode("utf-8", "replace").replace("\r\n", "\n")
                    pending += text_chunk
                    summary["response_bytes"] += len(text_chunk.encode("utf-8"))

                    while "\n\n" in pending:
                        block, pending = pending.split("\n\n", 1)
                        if not block.strip():
                            continue
                        event, data = parse_sse_block(block)
                        payload = parse_json_maybe(data)
                        frame = normalizer.normalize(event, payload)
                        event_name = frame.event
                        normalized_payload = frame.payload
                        elapsed_ms = int((time.time() - started) * 1000)
                        events_file.write(
                            json.dumps(
                                {
                                    "schema_version": "observer.event.v1",
                                    "ts": now_iso(),
                                    "elapsed_ms": elapsed_ms,
                                    "event": event_name,
                                    "data": normalized_payload
                                    if normalized_payload is not None
                                    else data,
                                    "source_event": event
                                    or (
                                        payload.get("type", "")
                                        if isinstance(payload, dict)
                                        else ""
                                    ),
                                    "raw_data": payload if payload is not None else data,
                                    "normalizations": frame.changes,
                                    "protocol_warnings": frame.warnings,
                                },
                                ensure_ascii=False,
                            )
                            + "\n"
                        )
                        events_file.flush()
                        observe_event(summary, event_name, normalized_payload, elapsed_ms)
                        if FILTER_REASONING_SUMMARY and event_name.startswith("response.reasoning_summary"):
                            continue
                        forwarded_data = (
                            json.dumps(normalized_payload, ensure_ascii=False, separators=(",", ":"))
                            if normalized_payload is not None
                            else data
                        )
                        self.wfile.write(format_sse_block(event_name, forwarded_data))
                        self.wfile.flush()

                if pending:
                    elapsed_ms = int((time.time() - started) * 1000)
                    events_file.write(
                        json.dumps(
                            {
                                "ts": now_iso(),
                                "elapsed_ms": elapsed_ms,
                                "event": "<trailing-bytes>",
                                "data": pending,
                            },
                            ensure_ascii=False,
                        )
                        + "\n"
                    )
                    self.wfile.write(pending.encode("utf-8"))

            summary["latency_ms"] = int((time.time() - started) * 1000)
            summary["completed_at"] = summary.get("completed_at") or now_iso()
            prefix.with_suffix(".summary.json").write_text(
                json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8"
            )
        except urllib.error.HTTPError as error:
            self.write_proxy_error(prefix, summary, started, error.code, error)
        except Exception as error:
            self.write_proxy_error(prefix, summary, started, 500, error)

    def write_proxy_error(
        self,
        prefix: Path,
        summary: dict[str, Any] | None,
        started: float,
        status: int,
        error: BaseException,
    ) -> None:
        if summary is None:
            summary = {
                "request_id": prefix.name,
                "started_at": datetime.fromtimestamp(started, timezone.utc).isoformat(),
                "errors": [],
            }
        summary["status"] = summary.get("status") or status
        summary["completed_at"] = now_iso()
        summary["latency_ms"] = int((time.time() - started) * 1000)
        summary.setdefault("errors", []).append("".join(traceback.format_exception_only(type(error), error)).strip())
        prefix.with_suffix(".summary.json").write_text(
            json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8"
        )
        if not getattr(self, "_headers_buffer", None):
            self.send_json(status, {"error": str(error), "request_id": prefix.name})


def main() -> None:
    ensure_dirs()
    server = ThreadingHTTPServer((HOST, PORT), ObserverHandler)
    print("Volcano Codex Observer")
    print(f"  dashboard: http://{HOST}:{PORT}/")
    print(f"  proxy:     http://{HOST}:{PORT}/api/v3/responses")
    print(f"  upstream:  {UPSTREAM_BASE}/responses")
    print(f"  logs:      {LOG_DIR}")
    if FILTER_REASONING_SUMMARY:
        print("  filter:    response.reasoning_summary_* events")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
