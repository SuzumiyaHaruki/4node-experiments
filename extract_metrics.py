#!/usr/bin/env python3
import argparse
import csv
import json
import math
from pathlib import Path
from statistics import mean

def percentile(vals, p):
    if not vals:
        return None
    vals = sorted(vals)
    if len(vals) == 1:
        return vals[0]
    k = (len(vals) - 1) * p
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return vals[int(k)]
    return vals[f] * (c - k) + vals[c] * (k - f)

def load_csv(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

def parse_fault_status(path):
    result = {"fault_status": None, "fault_message": None, "fault_name": None}
    if not path:
        return result
    p = Path(path)
    if not p.exists():
        return result
    with open(p, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip()
            v = v.strip()
            if k == "status":
                result["fault_status"] = v
            elif k == "message":
                result["fault_message"] = v
            elif k == "fault":
                result["fault_name"] = v
    return result

def parse_logs(paths):
    stats = {
        "disabled_skip": 0,
        "endorsement_satisfied": 0,
        "endorsement_failed": 0,
        "rebuild_count": 0,
        "remote_request_count": 0,
        "verify_ok_count": 0,
        "case_log_lines": 0,
    }
    for path in paths:
        p = Path(path)
        if not p.exists():
            continue
        with open(p, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                stats["case_log_lines"] += 1
                if "ENDORSEMENT_DISABLED_SKIP" in line:
                    stats["disabled_skip"] += 1
                if "candidate block endorsement satisfied" in line:
                    stats["endorsement_satisfied"] += 1
                if "candidate block endorsement failed" in line:
                    stats["endorsement_failed"] += 1
                if "rebuilding candidate block after endorsement failure" in line:
                    stats["rebuild_count"] += 1
                if "REMOTE_ENDORSEMENT_REQUEST" in line:
                    stats["remote_request_count"] += 1
                if "ENDORSEMENT_COMMITMENT_CERT_VERIFY_OK" in line:
                    stats["verify_ok_count"] += 1
    return stats

def classify_receipt_success(status_value):
    s = str(status_value).strip().lower()
    return s in {"1", "0x1"}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--case-name", required=True)
    ap.add_argument("--tx-csv", required=True)
    ap.add_argument("--sequencer-log", required=True)
    ap.add_argument("--endorser-log", action="append", default=[])
    ap.add_argument("--fault-status", default="")
    ap.add_argument("--out-json", required=True)
    ap.add_argument("--out-tsv", required=True)
    args = ap.parse_args()

    rows = load_csv(args.tx_csv)
    latencies = []
    keep_rows = []
    fail_rows = []
    tx_error_count = 0
    tx_receipt_count = 0
    tx_timeout_count = 0
    tx_send_error_count = 0
    tx_receipt_error_count = 0

    for r in rows:
      tx_type = r.get("tx_type", "")
      if tx_type == "keep":
        keep_rows.append(r)
      elif tx_type == "fail":
        fail_rows.append(r)
      err = str(r.get("error", "")).strip()
      err_stage = str(r.get("error_stage", "")).strip().lower()
      if err:
        tx_error_count += 1
        if err_stage == "send":
          tx_send_error_count += 1
        elif err_stage == "receipt":
          tx_receipt_error_count += 1
        if "timeout" in err.lower():
          tx_timeout_count += 1
      status = str(r.get("receipt_status", "")).strip()
      if status:
        tx_receipt_count += 1
      try:
        latencies.append(float(r["latency_ms"]))
      except Exception:
        pass

    keep_success = sum(1 for r in keep_rows if classify_receipt_success(r.get("receipt_status", "")))
    fail_success = sum(1 for r in fail_rows if classify_receipt_success(r.get("receipt_status", "")))
    log_stats = parse_logs([args.sequencer_log] + args.endorser_log)
    fault_info = parse_fault_status(args.fault_status)

    summary = {
        "case_name": args.case_name,
        "tx_total": len(rows),
        "tx_receipt_count": tx_receipt_count,
        "tx_error_count": tx_error_count,
        "tx_timeout_count": tx_timeout_count,
        "tx_send_error_count": tx_send_error_count,
        "tx_receipt_error_count": tx_receipt_error_count,
        "lat_avg_ms": round(mean(latencies), 3) if latencies else None,
        "lat_p50_ms": round(percentile(latencies, 0.50), 3) if latencies else None,
        "lat_p95_ms": round(percentile(latencies, 0.95), 3) if latencies else None,
        "lat_p99_ms": round(percentile(latencies, 0.99), 3) if latencies else None,
        "keep_total": len(keep_rows),
        "keep_success": keep_success,
        "keep_retention_rate": round(keep_success / len(keep_rows), 4) if keep_rows else None,
        "fail_total": len(fail_rows),
        "fail_success": fail_success,
        "fail_drop_rate": round((len(fail_rows) - fail_success) / len(fail_rows), 4) if fail_rows else None,
        **log_stats,
        **fault_info,
    }

    with open(args.out_json, "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)

    with open(args.out_tsv, "w", encoding="utf-8") as f:
        keys = list(summary.keys())
        f.write("\t".join(keys) + "\n")
        f.write("\t".join("" if summary[k] is None else str(summary[k]) for k in keys) + "\n")

if __name__ == "__main__":
    main()
