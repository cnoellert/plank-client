import importlib.util
import json
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/check_visionos_wacom_preflight.py"
SPEC = importlib.util.spec_from_file_location("wacom_preflight_check", SCRIPT)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class WacomPreflightCheckTests(unittest.TestCase):
    def record(self, **changes):
        base = {
            "schema_version": 1,
            "session_id": "session-1",
            "timestamp_utc": "2026-09-26T19:00:00Z",
            "client_version": "0.1.0",
            "relay_version": "0.1.0",
            "host_version": "1.0.154",
            "ready": True,
            "gates": {gate: "passed" for gate in CHECK.GATES},
        }
        base.update(changes)
        return base

    def test_passes_only_complete_record(self):
        self.assertEqual(CHECK.evaluate(self.record())["result"], "pass")
        partial = self.record(gates={**self.record()["gates"], "device_ownership": "pending"})
        result = CHECK.evaluate(partial)
        self.assertEqual(result["result"], "fail")
        self.assertIn("device_ownership: pending", result["reasons"])

    def test_uses_latest_record_and_rejects_stale_versions(self):
        complete = self.record()
        disconnected = self.record(ready=False)
        lines = [f"prefix {CHECK.MARKER}{json.dumps(item)}" for item in (complete, disconnected)]
        self.assertFalse(CHECK.latest_record("\n".join(lines))["ready"])
        self.assertEqual(CHECK.evaluate(self.record(relay_version=None))["result"], "fail")
        self.assertEqual(CHECK.evaluate(complete, max_age_seconds=60)["result"], "fail")


if __name__ == "__main__":
    unittest.main()
