#!/usr/bin/env python3
"""Check the latest structured Wacom preflight record from Vision Pro logs."""

import argparse
import datetime as dt
import json
import sys
from pathlib import Path


MARKER = "PLANK Wacom preflight: "
GATES = (
    "raw_hid",
    "focus_suspend",
    "relay_link",
    "device_ownership",
    "attach_sent",
    "host_acknowledgement",
)


def latest_record(text: str, session_id: str | None = None) -> dict | None:
    latest = None
    for line in text.splitlines():
        if MARKER not in line:
            continue
        try:
            candidate = json.loads(line.split(MARKER, 1)[1])
        except json.JSONDecodeError:
            latest = {"invalid_record": True}
            continue
        if isinstance(candidate, dict) and (
            session_id is None or candidate.get("session_id") == session_id
        ):
            latest = candidate
    return latest


def evaluate(record: dict | None, max_age_seconds: int | None = None) -> dict:
    reasons = []
    if record is None:
        return {"result": "fail", "reasons": ["no matching preflight record"]}
    if record.get("schema_version") != 1:
        reasons.append("unsupported or invalid record schema")
    if not isinstance(record.get("session_id"), str) or not record["session_id"]:
        reasons.append("missing session ID")
    for name in ("client_version", "relay_version", "host_version"):
        if not isinstance(record.get(name), str) or not record[name]:
            reasons.append(f"missing {name}")
    gates = record.get("gates")
    if not isinstance(gates, dict):
        gates = {}
    for gate in GATES:
        if gates.get(gate) != "passed":
            reasons.append(f"{gate}: {gates.get(gate, 'missing')}")
    if record.get("ready") is not True:
        reasons.append("client did not report ready")
    if max_age_seconds is not None:
        try:
            timestamp = dt.datetime.fromisoformat(record["timestamp_utc"].replace("Z", "+00:00"))
            age = (dt.datetime.now(dt.timezone.utc) - timestamp).total_seconds()
            if age < -5 or age > max_age_seconds:
                reasons.append("preflight record is outside the requested time window")
        except (KeyError, AttributeError, ValueError):
            reasons.append("missing or invalid UTC timestamp")
    return {
        "result": "fail" if reasons else "pass",
        "session_id": record.get("session_id"),
        "client_version": record.get("client_version"),
        "relay_version": record.get("relay_version"),
        "host_version": record.get("host_version"),
        "gates": gates,
        "reasons": reasons,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, help="exported Vision Pro app log")
    parser.add_argument("--session-id", help="select one specific session")
    parser.add_argument("--max-age-seconds", type=int,
                        help="reject a record older than this many seconds")
    args = parser.parse_args()
    if args.max_age_seconds is not None and args.max_age_seconds < 0:
        parser.error("--max-age-seconds must be nonnegative")
    try:
        record = latest_record(args.log.read_text(errors="replace"), args.session_id)
    except OSError as error:
        print(json.dumps({"result": "fail", "reasons": [str(error)]}))
        return 1
    result = evaluate(record, args.max_age_seconds)
    print(json.dumps(result, sort_keys=True))
    return 0 if result["result"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
