#!/usr/bin/env python3
import argparse
import json
import math
import shutil
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


API = "https://api.us5.datadoghq.com"
APP = "https://us5.datadoghq.com"
PHASES = {
    "session_and_native_view_setup", "idle", "eight_streams_one_offscreen_raster",
    "all_streams_one_offscreen_raster", "all_session_repository_refresh", "idle_soak_after_handoff",
}


def request(url, payload=None, headers=None):
    headers = {"User-Agent": "VCX-Synthetic-Verification/1.0", **(headers or {})}
    if payload is not None:
        payload = json.dumps(payload, allow_nan=False).encode()
        headers["Content-Type"] = "application/json"
    with urllib.request.urlopen(urllib.request.Request(url, data=payload, headers=headers), timeout=20) as response:
        data = response.read(2 * 1024 * 1024)
        return response.status, json.loads(data) if data else {}


def key():
    result = subprocess.run(
        ["security", "find-generic-password", "-s", "datadog-api-key", "-w"],
        capture_output=True, text=True, timeout=5, check=True,
    )
    value = result.stdout.strip()
    if not value:
        raise ValueError("The configured Datadog API key is empty.")
    return value


def cookies():
    profile = Path.home() / "Library/Application Support/Firefox/Profiles/77xcox0v.default-release"
    with tempfile.TemporaryDirectory(prefix="vcx-datadog-cookies-") as directory:
        path = Path(directory) / "cookies.sqlite"
        for suffix in ("", "-wal", "-shm"):
            source = profile / ("cookies.sqlite" + suffix)
            if source.exists():
                shutil.copyfile(source, Path(str(path) + suffix))
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            rows = connection.execute(
                "SELECT name,value FROM moz_cookies WHERE host IN (?, ?, ?)",
                (".datadoghq.com", ".us5.datadoghq.com", "us5.datadoghq.com"),
            ).fetchall()
        finally:
            connection.close()
    if not rows:
        raise ValueError("No existing Datadog Firefox session cookies were found.")
    return "; ".join(name + "=" + value for name, value in rows)


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 <= value <= 2 ** 53 or not math.isfinite(value):
        raise ValueError("Verification metrics must be finite nonnegative numbers.")
    return value


def series(report, run, stage, timestamp):
    result = []

    def add(metric, value, *tags):
        result.append({"metric": "vcx.verification." + metric, "type": "gauge",
                       "points": [[timestamp, number(value)]],
                       "tags": ["service:vcx", "env:verification", "workload:synthetic", "run_id:" + run, "stage:" + stage, *tags]})

    if report is None:
        add("probe", 1)
        return result
    load = report.get("load", report)
    if load.get("status") != "passed" or load.get("realModelCostIncluded") is not False or load.get("providerProcesses") != 0:
        raise ValueError("A completed synthetic VCX report is required.")
    for scenario in load.get("scenarios", []):
        count = scenario.get("sessions")
        if count not in (20, 50, 100):
            raise ValueError("Unsupported synthetic session count.")
        tags = ("sessions:" + str(count),)
        for phase in scenario.get("phases", []):
            name = phase.get("name")
            if name not in PHASES:
                raise ValueError("Unsupported verification phase.")
            base = (*tags, "phase:" + name)
            for field, component in [("totalCPUPercent", "combined"), ("frontendCPUPercent", "frontend"), ("workerCPUPercent", "runtime")]:
                add("cpu.percent", phase[field], *base, "component:" + component)
            add("rss.bytes", phase["frontendRSSBytes"], *base, "component:frontend")
            add("rss.bytes", phase["workerRSSBytes"], *base, "component:runtime")
        for field in ("attachReadyMs", "checkpointAckMs", "checkpointProjectionMs", "replacementAttachMs"):
            for statistic in ("p50", "p95", "max"):
                add("latency.ms", scenario[field][statistic], *tags, "operation:" + field.lower(), "stat:" + statistic)
    for field in ("boundsChecks", "frontendChecks", "recoveryChecks", "loadChecks"):
        if field in report:
            add("checks", report[field], "suite:" + field.lower())
    if not result or len(result) > 128:
        raise ValueError("The report contains no allowlisted verification metrics.")
    return result


def readback(run, stage, timestamp, expected):
    metric = expected[0]["metric"]
    group_names = sorted({tag.split(":", 1)[0] for row in expected for tag in row["tags"] if tag.split(":", 1)[0] not in {"service", "env", "workload", "run_id", "stage"}})
    query = "avg:" + metric + "{service:vcx,env:verification,run_id:" + run + ",stage:" + stage + "}"
    if group_names:
        query += " by {" + ",".join(group_names) + "}"
    params = urllib.parse.urlencode({"from": timestamp - 60, "to": int(time.time()) + 5, "query": query})
    status, data = request(APP + "/api/v1/query?" + params, headers={"Cookie": cookies()})
    rows = data.get("series", [])
    expected_values = {tuple(sorted(tag for tag in row["tags"] if tag.split(":", 1)[0] in group_names)): row["points"][0][1] for row in expected}
    matched = set()
    point_count = 0
    for row in rows:
        scope = row.get("tag_set", row.get("scope", "").split(","))
        identity = tuple(sorted(tag for tag in scope if tag.split(":", 1)[0] in group_names))
        for _, value in row.get("pointlist", []):
            if isinstance(value, (float, int)):
                point_count += 1
                if identity in expected_values and math.isclose(value, expected_values[identity], rel_tol=1e-5, abs_tol=1e-7):
                    matched.add(identity)
    return {"httpStatus": status, "series": len(rows), "points": point_count,
            "expectedSeries": len(expected_values), "matchedSeries": len(matched)}


def main():
    parser = argparse.ArgumentParser(description="Publish only synthetic VCX benchmark numbers to Datadog, then verify their readback. Credentials stay in Keychain and the existing Firefox session.")
    parser.add_argument("--report", type=Path, help="Completed --runtime-load-check or --verify-runtime JSON; omit for one probe metric.")
    parser.add_argument("--run", default="vcx-" + time.strftime("%Y%m%d%H%M%S", time.gmtime()), help="Short run correlation ID, shared by before and after reports.")
    parser.add_argument("--stage", choices=("before", "after", "probe"), default="probe")
    parser.add_argument("--wait", type=int, default=60, help="Maximum seconds for Datadog metric readback (0 to 300).")
    parser.add_argument("--output", type=Path, required=True, help="Private local JSON evidence containing only numeric counts and status.")
    args = parser.parse_args()
    if not args.run.isascii() or not args.run.replace("-", "").isalnum() or len(args.run) > 64:
        raise ValueError("A verification run tag must be short alphanumeric text.")
    args.run = args.run.lower()
    if not 0 <= args.wait <= 300:
        raise ValueError("The readback wait must be between zero and 300 seconds.")
    report = json.loads(args.report.read_text()) if args.report else None
    timestamp = int(time.time())
    points = series(report, args.run, args.stage, timestamp)
    api_key = key()
    status, validity = request(API + "/api/v1/validate", headers={"DD-API-KEY": api_key})
    if validity.get("valid") is not True:
        raise ValueError("Datadog rejected the configured API key.")
    intake_status, intake = request(API + "/api/v1/series", {"series": points}, {"DD-API-KEY": api_key})
    metrics = sorted({row["metric"] for row in points})
    deadline = time.monotonic() + args.wait
    result = {"run": args.run, "stage": args.stage, "apiKeyValid": True, "intakeHTTPStatus": intake_status,
              "submittedPoints": len(points), "onlySyntheticAllowlistedNumbers": True,
              "readback": []}
    while True:
        result["readback"] = [readback(args.run, args.stage, timestamp, [row for row in points if row["metric"] == metric]) for metric in metrics]
        result["allSeriesMatched"] = all(row["matchedSeries"] == row["expectedSeries"] for row in result["readback"])
        if result["allSeriesMatched"] or time.monotonic() >= deadline:
            break
        time.sleep(5)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    args.output.chmod(0o600)
    print(json.dumps(result, sort_keys=True))
    if not result["allSeriesMatched"]:
        raise SystemExit(1)


if __name__ == "__main__":
    try:
        main()
    except (urllib.error.URLError, subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError, OSError, KeyError) as error:
        print(json.dumps({"errorType": type(error).__name__, "httpStatus": getattr(error, "code", None)}))
        raise SystemExit(1)
