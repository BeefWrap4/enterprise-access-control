from __future__ import annotations

import argparse
import json
import statistics
import time
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib import parse, request


def http_call(url: str, *, token: str | None = None, body: dict | None = None) -> tuple[int, float]:
    headers = {"Accept": "application/json"}
    data = None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    started = time.perf_counter()
    with request.urlopen(request.Request(url, headers=headers, data=data), timeout=10) as response:
        response.read()
        return response.status, (time.perf_counter() - started) * 1000


def token() -> str:
    data = parse.urlencode({
        "grant_type": "password",
        "client_id": "qa-client",
        "client_secret": "qa-client-dev-secret",
        "username": "ops-user",
        "password": "Ops-demo-2026!",
        "scope": "openid profile email",
    }).encode()
    with request.urlopen(request.Request(
        "http://localhost:8180/realms/baseops/protocol/openid-connect/token",
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    ), timeout=10) as response:
        return json.load(response)["access_token"]


def percentile(values: list[float], ratio: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int((len(ordered) - 1) * ratio))]


def run_target(name: str, count: int, concurrency: int, fn) -> dict:
    latencies: list[float] = []
    errors: list[str] = []
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(fn) for _ in range(count)]
        for future in as_completed(futures):
            try:
                status, latency = future.result()
                latencies.append(latency)
                if status != 200:
                    errors.append(f"HTTP_{status}")
            except Exception as error:  # evidence captures the concrete failure class
                errors.append(type(error).__name__)
    return {
        "target": name,
        "requests": count,
        "concurrency": concurrency,
        "success": len(latencies) - sum(1 for item in errors if item.startswith("HTTP_")),
        "errors": len(errors),
        "error_types": sorted(set(errors)),
        "latency_ms": {
            "mean": round(statistics.fmean(latencies), 2) if latencies else None,
            "p50": round(percentile(latencies, 0.50), 2) if latencies else None,
            "p95": round(percentile(latencies, 0.95), 2) if latencies else None,
            "max": round(max(latencies), 2) if latencies else None,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmark the local Keycloak introspection and Cerbos decision paths.")
    parser.add_argument("--requests", type=int, default=200)
    parser.add_argument("--concurrency", type=int, default=20)
    args = parser.parse_args()
    access_token = token()
    targets = []
    for port, name in ((8101, "rag_auth_me"), (8102, "cache_auth_me"), (8103, "agent_auth_me")):
        targets.append(run_target(name, args.requests, args.concurrency, lambda port=port: http_call(f"http://localhost:{port}/api/v1/auth/me", token=access_token)))

    def cerbos_check() -> tuple[int, float]:
        payload = {
            "requestId": f"bench-{uuid.uuid4().hex}",
            "principal": {"id": "ops-user", "roles": ["ops"], "attr": {"workspace_id": "demo"}},
            "resources": [{"resource": {"kind": "agent_tool", "id": "alarm/query", "attr": {"workspace_id": "demo", "station_allowed": True, "long_window": False, "risk": "L1", "approval_consumed": False}}, "actions": ["execute"]}],
        }
        return http_call("http://localhost:3592/api/check/resources", body=payload)

    targets.append(run_target("cerbos_check", args.requests, args.concurrency, cerbos_check))
    report = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "environment": "single-host-docker-compose",
        "scope": "local reproduction evidence; not a production SLO",
        "targets": targets,
    }
    output = Path("reports/access-control-benchmark-latest.json")
    output.parent.mkdir(exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if any(item["errors"] for item in targets):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
