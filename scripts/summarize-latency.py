"""Summarize the temporary LATENCY JSONL benchmark protocol."""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATES = ("visible", "minimized", "hidden")
COMMANDS = ("play", "pause", "next", "previous")
RUNS = (1, 2, 3)
EXPECTED_SAMPLES = {"play": 10, "pause": 10, "next": 3, "previous": 3}
EXPECTED_BASELINES = 5


class ValidationError(ValueError):
    pass


def path_from_root(value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else ROOT / path


def number(value, field: str, line: int, *, allow_null: bool = False):
    if value is None and allow_null:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValidationError(f"line {line}: {field} must be a finite nonnegative number")
    if not math.isfinite(value) or value < 0:
        raise ValidationError(f"line {line}: {field} must be a finite nonnegative number")
    return value


def run_number(value, line: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value not in RUNS:
        raise ValidationError(f"line {line}: run must be an integer from 1 to 3")
    return value


def validate_record(record, line: int):
    if not isinstance(record, dict):
        raise ValidationError(f"line {line}: record must be a JSON object")
    kind = record.get("kind")
    if kind not in {"sample", "baseline", "end"}:
        raise ValidationError(f"line {line}: unknown kind")

    if kind == "end":
        if not isinstance(record.get("completed"), bool):
            raise ValidationError(f"line {line}: end.completed must be boolean")
        return {"kind": kind, "completed": record["completed"]}

    state = record.get("state")
    if state not in STATES:
        raise ValidationError(f"line {line}: state must be visible, minimized, or hidden")
    run = run_number(record.get("run"), line)
    ack = number(record.get("ackMs"), "ackMs", line)

    if kind == "baseline":
        return {"kind": kind, "state": state, "run": run, "ackMs": ack}

    command = record.get("command")
    if command not in COMMANDS:
        raise ValidationError(f"line {line}: unknown sample command")
    outcome = record.get("outcome")
    if outcome not in {"observed", "timeout", "refused", "error"}:
        raise ValidationError(f"line {line}: unknown sample outcome")
    observed = number(record.get("observedMs"), "observedMs", line, allow_null=True)
    lower = number(record.get("lowerMs"), "lowerMs", line, allow_null=True)
    if outcome == "observed" and observed is None:
        raise ValidationError(f"line {line}: observed samples need observedMs")
    if outcome != "observed" and observed is not None:
        raise ValidationError(f"line {line}: failed samples must have observedMs=null")
    if observed is not None and lower is not None and observed < lower:
        raise ValidationError(f"line {line}: observedMs cannot be less than lowerMs")
    return {
        "kind": kind,
        "state": state,
        "run": run,
        "command": command,
        "ackMs": ack,
        "observedMs": observed,
        "lowerMs": lower,
        "outcome": outcome,
    }


def read_records(path: Path):
    records = []
    ignored = 0
    try:
        source = path.open("r", encoding="utf-8")
    except OSError as exc:
        raise ValidationError(f"cannot read input {path}: {exc}") from exc
    with source:
        for line_number, raw in enumerate(source, 1):
            text = raw.strip()
            if not text:
                continue
            if text.startswith("LATENCY "):
                payload = text[8:]
            elif text.startswith("{"):
                payload = text
            else:
                ignored += 1
                continue
            try:
                record = json.loads(payload)
            except json.JSONDecodeError as exc:
                raise ValidationError(f"line {line_number}: invalid JSON: {exc.msg}") from exc
            records.append(validate_record(record, line_number))

    ends = [record for record in records if record["kind"] == "end"]
    if len(ends) != 1:
        raise ValidationError("input must contain exactly one end record")
    if records[-1]["kind"] != "end":
        raise ValidationError("end record must be last")

    counts = {}
    for record in records:
        if record["kind"] == "sample":
            key = ("sample", record["state"], record["command"], record["run"])
            limit = EXPECTED_SAMPLES[record["command"]]
        elif record["kind"] == "baseline":
            key = ("baseline", record["state"], record["run"])
            limit = EXPECTED_BASELINES
        else:
            continue
        counts[key] = counts.get(key, 0) + 1
        if counts[key] > limit:
            raise ValidationError(f"too many {key[0]} records for {key[1:]}; expected at most {limit}")
    return records, ignored


def nearest_rank(values, percentile):
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(percentile * len(ordered)))
    return ordered[rank - 1]


def stats(values):
    return {
        "count": len(values),
        "p50": nearest_rank(values, 0.50),
        "p95": nearest_rank(values, 0.95),
    }


def sample_cell(records, state, command, run):
    return [
        record
        for record in records
        if record["kind"] == "sample"
        and record["state"] == state
        and record["command"] == command
        and record["run"] == run
    ]


def summarize(records, ignored):
    end = next(record for record in records if record["kind"] == "end")
    samples = [record for record in records if record["kind"] == "sample"]
    baselines = [record for record in records if record["kind"] == "baseline"]

    grouped = {}
    missing = []
    for state in STATES:
        grouped[state] = {}
        for command in COMMANDS:
            values = [
                record
                for record in samples
                if record["state"] == state and record["command"] == command
            ]
            ack_values = [record["ackMs"] for record in values]
            observed_values = [
                record["observedMs"] for record in values if record["outcome"] == "observed"
            ]
            interval_values = [
                record["observedMs"] - record["lowerMs"]
                for record in values
                if record["outcome"] == "observed"
                and record["observedMs"] is not None
                and record["lowerMs"] is not None
            ]
            per_run = {}
            for run in RUNS:
                cell = sample_cell(samples, state, command, run)
                per_run[str(run)] = {
                    "total": len(cell),
                    "success": sum(record["outcome"] == "observed" for record in cell),
                    "failure": sum(record["outcome"] != "observed" for record in cell),
                    "expected": EXPECTED_SAMPLES[command],
                }
                if len(cell) < EXPECTED_SAMPLES[command]:
                    missing.append(
                        {
                            "kind": "sample",
                            "state": state,
                            "command": command,
                            "run": run,
                            "expected": EXPECTED_SAMPLES[command],
                            "actual": len(cell),
                        }
                    )
            grouped[state][command] = {
                "expectedPerRun": EXPECTED_SAMPLES[command],
                "total": len(values),
                "success": sum(record["outcome"] == "observed" for record in values),
                "failure": sum(record["outcome"] != "observed" for record in values),
                "perRun": per_run,
                "ackMs": stats(ack_values),
                "observedMs": stats(observed_values),
                "intervalWidthsMs": interval_values,
                "intervalWidthMissing": len(observed_values) - len(interval_values),
                "intervalWidthMs": stats(interval_values),
            }

    baseline_report = {}
    for state in STATES:
        baseline_report[state] = {}
        for run in RUNS:
            values = [
                record["ackMs"]
                for record in baselines
                if record["state"] == state and record["run"] == run
            ]
            if len(values) < EXPECTED_BASELINES:
                missing.append(
                    {
                        "kind": "baseline",
                        "state": state,
                        "run": run,
                        "expected": EXPECTED_BASELINES,
                        "actual": len(values),
                    }
                )
            baseline_report[state][str(run)] = {
                "expected": EXPECTED_BASELINES,
                "count": len(values),
                "ackMs": stats(values),
                "valuesMs": values,
                "ipcFloorMs": stats(values),
            }

    failed_samples = sum(record["outcome"] != "observed" for record in samples)
    return {
        "schemaVersion": 1,
        "completed": end["completed"],
        "protocolComplete": not missing and not failed_samples and end["completed"],
        "records": {
            "samples": len(samples),
            "baselines": len(baselines),
            "ignoredLines": ignored,
        },
        "failedSamples": failed_samples,
        "samples": grouped,
        "baselineIpcFloor": baseline_report,
        "missingCells": missing,
        "limitations": [
            "Three repeat blocks are from the same build; this is not a previous-build comparison.",
            "Visible, minimized, and hidden are page/window states, not an audible-playback claim.",
            "Observed latency intervals are upper bounds; no baseline is subtracted and no speedup is invented.",
            "With nine complete Next/Previous samples, nearest-rank p95 is the maximum sample.",
            "Refused commands and incomplete runs remain failures/incomplete; they are not discarded.",
        ],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "input",
        nargs="?",
        default="artifacts/latency.jsonl",
        help="JSONL input, relative to the repository root (default: artifacts/latency.jsonl)",
    )
    parser.add_argument(
        "output",
        nargs="?",
        default="artifacts/latency-summary.json",
        help="JSON output, relative to the repository root (default: artifacts/latency-summary.json)",
    )
    args = parser.parse_args(argv)
    try:
        records, ignored = read_records(path_from_root(args.input))
        summary = summarize(records, ignored)
        output = path_from_root(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    except (OSError, ValidationError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
