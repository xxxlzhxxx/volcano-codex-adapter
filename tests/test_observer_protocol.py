#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path


ADAPTER_DIR = Path(__file__).resolve().parents[1]
OBSERVER_DIR = ADAPTER_DIR / "observer"
sys.path.insert(0, str(OBSERVER_DIR))

from responses_protocol import ResponsesStreamNormalizer


class ResponsesStreamNormalizerTests(unittest.TestCase):
    def test_message_added_gets_required_empty_content(self) -> None:
        normalizer = ResponsesStreamNormalizer()
        frame = normalizer.normalize(
            "response.output_item.added",
            {
                "type": "response.output_item.added",
                "item": {
                    "id": "msg_1",
                    "type": "message",
                    "role": "assistant",
                    "status": "in_progress",
                },
            },
        )
        self.assertEqual(frame.payload["item"]["content"], [])
        self.assertEqual(frame.changes, ["message.content=[]"])

        delta = normalizer.normalize(
            "response.output_text.delta",
            {"type": "response.output_text.delta", "delta": "OK"},
        )
        self.assertEqual(delta.warnings, [])

    def test_reasoning_added_gets_public_schema_defaults(self) -> None:
        frame = ResponsesStreamNormalizer().normalize(
            "response.output_item.added",
            {
                "type": "response.output_item.added",
                "item": {"id": "rs_1", "type": "reasoning", "status": "in_progress"},
            },
        )
        self.assertEqual(frame.payload["item"]["summary"], [])
        self.assertIsNone(frame.payload["item"]["encrypted_content"])
        self.assertEqual(
            frame.changes,
            ["reasoning.summary=[]", "reasoning.encrypted_content=null"],
        )

    def test_function_call_added_gets_empty_arguments(self) -> None:
        frame = ResponsesStreamNormalizer().normalize(
            "response.output_item.added",
            {
                "type": "response.output_item.added",
                "item": {
                    "type": "function_call",
                    "id": "fc_1",
                    "call_id": "call_1",
                    "name": "get_time",
                },
            },
        )
        self.assertEqual(frame.payload["item"]["arguments"], "")

    def test_delta_without_active_item_is_reported_not_rewritten(self) -> None:
        frame = ResponsesStreamNormalizer().normalize(
            "response.output_text.delta",
            {"type": "response.output_text.delta", "delta": "OK"},
        )
        self.assertEqual(frame.payload["delta"], "OK")
        self.assertEqual(
            frame.warnings,
            ["response.output_text.delta arrived without an active message item"],
        )


class ObserverImportTests(unittest.TestCase):
    def load_proxy(self, temp_dir: str):
        os.environ["OBSERVER_LOG_DIR"] = temp_dir
        module_path = OBSERVER_DIR / "proxy.py"
        spec = importlib.util.spec_from_file_location(
            f"observer_proxy_test_{id(self)}", module_path
        )
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_import_rebuilds_usage_and_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            module = self.load_proxy(temp_dir)

            result = module.import_observer_log(
                {
                    "schema_version": "observer.import.v1",
                    "request_id": "import-test",
                    "source": {"kind": "codex_cli", "name": "codex"},
                    "thread": {"thread_id": "thread-1", "originator": "codex_exec"},
                    "request": {
                        "method": "POST",
                        "path": "/responses",
                        "status": 200,
                        "body": {"model": "ep-test", "input": []},
                    },
                    "events": [
                        {
                            "elapsed_ms": 12,
                            "event": "response.output_item.added",
                            "data": {
                                "type": "response.output_item.added",
                                "item": {
                                    "id": "msg_1",
                                    "type": "message",
                                    "role": "assistant",
                                },
                            },
                        },
                        {
                            "elapsed_ms": 20,
                            "event": "response.output_text.delta",
                            "data": {
                                "type": "response.output_text.delta",
                                "delta": "OK",
                            },
                        },
                        {
                            "elapsed_ms": 25,
                            "event": "response.completed",
                            "data": {
                                "type": "response.completed",
                                "response": {
                                    "model": "ep-test",
                                    "usage": {
                                        "input_tokens": 100,
                                        "output_tokens": 5,
                                        "total_tokens": 105,
                                        "input_tokens_details": {"cached_tokens": 64},
                                    },
                                },
                            },
                        },
                    ],
                }
            )

            summary = result["summary"]
            self.assertEqual(summary["total_tokens"], 105)
            self.assertEqual(summary["cached_tokens"], 64)
            self.assertEqual(summary["cache_hit_ratio"], 0.64)
            self.assertEqual(summary["output_text_preview"], "OK")
            self.assertEqual(summary["source"]["kind"], "codex_cli")

            events_path = Path(temp_dir) / "requests" / "import-test.events.jsonl"
            records = [
                json.loads(line)
                for line in events_path.read_text(encoding="utf-8").splitlines()
            ]
            self.assertEqual(
                records[0]["normalizations"], ["message.content=[]"]
            )

    def test_import_maps_cli_and_app_server_events(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            module = self.load_proxy(temp_dir)
            summary = module.make_initial_summary(
                "surface-test", "IMPORT", "/api/import", None, 0
            )
            module.observe_event(
                summary,
                "item.completed",
                {
                    "item": {
                        "type": "agent_message",
                        "text": "CLI_OK",
                    }
                },
                10,
            )
            module.observe_event(
                summary,
                "thread/tokenUsage/updated",
                {
                    "tokenUsage": {
                        "total": {
                            "inputTokens": 8000,
                            "cachedInputTokens": 4096,
                            "cacheWriteInputTokens": 128,
                            "outputTokens": 40,
                            "reasoningOutputTokens": 20,
                            "totalTokens": 8040,
                        }
                    }
                },
                20,
            )
            self.assertEqual(summary["output_text_preview"], "CLI_OK")
            self.assertEqual(summary["total_tokens"], 8040)
            self.assertEqual(summary["cached_tokens"], 4096)
            self.assertEqual(summary["cache_write_tokens"], 128)
            self.assertEqual(summary["reasoning_output_tokens"], 20)


if __name__ == "__main__":
    unittest.main()
