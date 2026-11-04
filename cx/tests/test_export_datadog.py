import importlib.util
import json
import math
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("export_datadog", Path(__file__).with_name("export_datadog.py"))
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


class DatadogExportTests(unittest.TestCase):
    def report(self):
        phase = {"name": "idle", "totalCPUPercent": .5, "frontendCPUPercent": .4,
                 "workerCPUPercent": .1, "frontendRSSBytes": 1024, "workerRSSBytes": 2048,
                 "secret": "DO_NOT_EXPORT", "path": "/private/user/workspace"}
        scenario = {"sessions": 20, "phases": [phase]}
        for name in ("attachReadyMs", "checkpointAckMs", "checkpointProjectionMs", "replacementAttachMs"):
            scenario[name] = {"p50": 5, "p95": 10, "max": 11, "prompt": "DO_NOT_EXPORT"}
        return {"status": "passed", "realModelCostIncluded": False, "providerProcesses": 0,
                "scenarios": [scenario], "unknown": "DO_NOT_EXPORT"}

    def test_only_fixed_numeric_fields_leave_the_machine(self):
        rows = exporter.series(self.report(), "test-run", "before", 123)
        encoded = json.dumps(rows)
        self.assertNotIn("DO_NOT_EXPORT", encoded)
        self.assertNotIn("/private/", encoded)
        self.assertEqual(len(rows), 17)
        self.assertTrue(all(row["tags"][:5] == ["service:vcx", "env:verification", "workload:synthetic", "run_id:test-run", "stage:before"] for row in rows))
        self.assertTrue(all(tag == tag.lower() for row in rows for tag in row["tags"]))

    def test_probe_is_one_constant_point(self):
        rows = exporter.series(None, "test-run", "probe", 123)
        self.assertEqual(rows[0]["metric"], "vcx.verification.probe")
        self.assertEqual(rows[0]["points"], [[123, 1]])
        self.assertEqual(len(rows), 1)

    def test_opted_in_soak_exports_only_fixed_cpu_and_rss_fields(self):
        report = self.report()
        phase = report["scenarios"][0]["phases"][0]
        phase["name"] = "idle_soak_after_handoff"
        phase["rssSamples"] = [{"combinedRSSBytes": 3072, "secret": "DO_NOT_EXPORT"}]
        phase["rssSampleCount"] = 65
        phase["combinedRSSDeltaBytes"] = -1024
        rows = exporter.series(report, "test-run", "after", 123)
        soak = [row for row in rows if "phase:idle_soak_after_handoff" in row["tags"]]
        self.assertEqual(len(soak), 5)
        self.assertEqual({row["metric"] for row in soak}, {"vcx.verification.cpu.percent", "vcx.verification.rss.bytes"})
        self.assertNotIn("DO_NOT_EXPORT", json.dumps(rows))
        self.assertNotIn("rssSamples", json.dumps(rows))

    def test_nonfinite_negative_boolean_and_huge_values_are_rejected(self):
        for value in (math.nan, math.inf, -1, True, "5", 10 ** 1000):
            with self.subTest(value=type(value).__name__), self.assertRaises(ValueError):
                exporter.number(value)

    def test_unknown_phases_and_session_counts_are_rejected(self):
        report = self.report()
        report["scenarios"][0]["phases"][0]["name"] = "DO_NOT_EXPORT"
        with self.assertRaises(ValueError):
            exporter.series(report, "test-run", "before", 123)
        report = self.report()
        report["scenarios"][0]["sessions"] = 500
        with self.assertRaises(ValueError):
            exporter.series(report, "test-run", "before", 123)

    def test_incomplete_real_provider_and_oversized_reports_are_rejected(self):
        for field, value in (("status", "running"), ("realModelCostIncluded", True), ("providerProcesses", 1)):
            report = self.report()
            report[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                exporter.series(report, "test-run", "before", 123)
        report = self.report()
        report["scenarios"] *= 10
        with self.assertRaises(ValueError):
            exporter.series(report, "test-run", "before", 123)

    def test_full_verification_includes_fixed_suite_counts(self):
        report = {"load": self.report(), "boundsChecks": 229, "unexpected": "DO_NOT_EXPORT"}
        rows = exporter.series(report, "test-run", "after", 123)
        self.assertEqual(rows[-1]["points"], [[123, 229]])
        self.assertIn("suite:boundschecks", rows[-1]["tags"])

    def test_readback_matches_values_per_fixed_dimension(self):
        expected = exporter.series(self.report(), "test-run", "before", 123)[:3]
        response = {"series": [{"tag_set": [tag for tag in row["tags"] if tag.startswith(("sessions:", "phase:", "component:"))], "pointlist": [[123000, row["points"][0][1]]]} for row in expected]}
        with patch.object(exporter, "cookies", return_value="PRIVATE_COOKIE"), patch.object(exporter, "request", return_value=(200, response)) as request:
            result = exporter.readback("test-run", "before", 123, expected)
        self.assertEqual(result["matchedSeries"], 3)
        self.assertEqual(result["expectedSeries"], 3)
        self.assertNotIn("PRIVATE_COOKIE", request.call_args.args[0])

    def test_readback_rejects_wrong_values_and_missing_dimensions(self):
        expected = exporter.series(self.report(), "test-run", "before", 123)[:3]
        response = {"series": [{"scope": "component:frontend,phase:idle,sessions:20", "pointlist": [[123000, 99]]}]}
        with patch.object(exporter, "cookies", return_value="PRIVATE_COOKIE"), patch.object(exporter, "request", return_value=(200, response)):
            result = exporter.readback("test-run", "before", 123, expected)
        self.assertEqual(result["matchedSeries"], 0)


if __name__ == "__main__":
    unittest.main()
