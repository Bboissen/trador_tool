from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import NoReturn


STATE_FILE = Path(os.getenv("LIGHTER_STATE_FILE", "/tmp/lighter_adapter/state.json"))
REST_MAX_AGE = float(os.getenv("LIGHTER_HEALTH_MAX_REST_AGE_SECONDS", "120"))
WS_MAX_AGE = float(os.getenv("LIGHTER_HEALTH_MAX_WS_AGE_SECONDS", "60"))


def fail(message: str) -> NoReturn:
    print(f"ERROR: {message}")
    sys.exit(1)


def load_state() -> dict:
    if not STATE_FILE.exists():
        fail(f"state file {STATE_FILE} not found")
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"invalid state file: {exc}")


def parse_csv_env(key: str) -> list[str]:
    raw = os.getenv(key, "")
    return [item.strip() for item in raw.split(",") if item.strip()]


def main() -> None:
    state = load_state()
    now = time.time()

    last_rest = state.get("last_rest")
    if not isinstance(last_rest, (int, float)):
        fail("missing last_rest timestamp")
    if now - float(last_rest) > REST_MAX_AGE:
        fail("REST heartbeat is stale")

    expect_ws = bool(parse_csv_env("LIGHTER_WS_ORDER_BOOK_IDS") or parse_csv_env("LIGHTER_WS_ACCOUNT_IDS"))
    if expect_ws:
        last_ws = state.get("last_ws")
        if not isinstance(last_ws, (int, float)):
            fail("missing last_ws timestamp")
        if now - float(last_ws) > WS_MAX_AGE:
            channel = state.get("last_ws_channel", "unknown")
            fail(f"WebSocket heartbeat stale (channel={channel})")

    print("OK")


if __name__ == "__main__":
    main()

