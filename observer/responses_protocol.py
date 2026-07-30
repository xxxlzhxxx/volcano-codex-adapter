#!/usr/bin/env python3
"""Responses API stream normalization for OpenAI-compatible providers."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class NormalizedFrame:
    event: str
    payload: Any
    changes: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


class ResponsesStreamNormalizer:
    """Normalize provider SSE frames to the public Responses item schema.

    Streaming ``output_item.added`` frames may legally contain an item whose
    content is not populated yet. Some compatible providers omit the required
    empty container fields instead of sending them as empty values. Codex
    deserializes these frames into the same public ResponseItem schema used for
    completed items, so this adapter supplies only those schema defaults.
    """

    def __init__(self) -> None:
        self.active_item_id: str | None = None
        self.active_item_type: str | None = None

    def normalize(self, event: str, payload: Any) -> NormalizedFrame:
        event_name = event or (
            str(payload.get("type", "")) if isinstance(payload, dict) else ""
        )
        if not isinstance(payload, dict):
            return NormalizedFrame(event_name, payload)

        normalized = dict(payload)
        changes: list[str] = []
        warnings: list[str] = []

        if event_name in {"response.output_item.added", "response.output_item.done"}:
            item = normalized.get("item")
            if isinstance(item, dict):
                normalized_item = dict(item)
                self._normalize_item(normalized_item, changes)
                normalized["item"] = normalized_item

                item_id = normalized_item.get("id") or normalized_item.get("call_id")
                item_type = normalized_item.get("type")
                if event_name == "response.output_item.added":
                    self.active_item_id = str(item_id) if item_id else None
                    self.active_item_type = str(item_type) if item_type else None
                elif self._same_active_item(item_id, item_type):
                    self.active_item_id = None
                    self.active_item_type = None
            else:
                warnings.append(f"{event_name} has no object item")

        if event_name.startswith("response.output_text.") and self.active_item_type != "message":
            warnings.append(
                f"{event_name} arrived without an active message item"
            )

        if event_name.startswith("response.reasoning_summary") and self.active_item_type != "reasoning":
            warnings.append(
                f"{event_name} arrived without an active reasoning item"
            )

        return NormalizedFrame(event_name, normalized, changes, warnings)

    @staticmethod
    def _normalize_item(item: dict[str, Any], changes: list[str]) -> None:
        item_type = item.get("type")
        if item_type == "message" and "content" not in item:
            item["content"] = []
            changes.append("message.content=[]")
        elif item_type == "reasoning":
            if "summary" not in item:
                item["summary"] = []
                changes.append("reasoning.summary=[]")
            if "encrypted_content" not in item:
                item["encrypted_content"] = None
                changes.append("reasoning.encrypted_content=null")
        elif item_type == "function_call" and "arguments" not in item:
            item["arguments"] = ""
            changes.append("function_call.arguments=''")

    def _same_active_item(self, item_id: Any, item_type: Any) -> bool:
        if self.active_item_id and item_id:
            return self.active_item_id == str(item_id)
        return self.active_item_type == str(item_type)
