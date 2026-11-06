#!/usr/bin/env python3
"""Local ControlWard discovery handoff. Uses no provider keys and sends no messages."""
import argparse
import datetime as dt
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid
from urllib.parse import urlsplit, urlunsplit


def utc():
    return dt.datetime.now(dt.timezone.utc)


def date(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def v4(value):
    parsed = uuid.UUID(value)
    if parsed.version != 4:
        raise ValueError("Expected a UUID v4")
    return str(parsed)


def workspaces(include_normal=False):
    home = Path.home()
    bases = [home / "Library/Containers/com.pharos.contextward/Data/Library/Application Support", home / "Library/Application Support"]
    for base in bases:
        reviews = base / "ControlWard Reviews"
        if reviews.is_dir():
            for review in reviews.iterdir():
                try:
                    review_id = v4(review.name)
                except (ValueError, AttributeError):
                    continue
                yield review / "leads/agent-inbox", review_id
        if include_normal:
            yield base / "ControlWard/leads/agent-inbox", None


def select_workspace(args, paths=None):
    found = []
    for inbox, review_id in paths if paths is not None else workspaces(args.live):
        if args.review_id and review_id != v4(args.review_id):
            continue
        try:
            availability = json.loads((inbox / "available.json").read_text())
            if availability["schema"] != 1 or availability["mode"] != ("review" if review_id else "normal"):
                continue
            if review_id and v4(availability["reviewID"]) != review_id:
                continue
            pid = int(availability["pid"])
            alive = False
            if 0 <= (utc() - date(availability["updatedAt"])).total_seconds() < 240:
                try:
                    command = subprocess.check_output(["ps", "-p", str(pid), "-o", "comm="], text=True, timeout=3).strip()
                    alive = command.endswith("/FollowUpOSNative")
                except (subprocess.SubprocessError, OSError):
                    pass
            availability["app_running"] = alive
            availability["inbox"] = str(inbox)
            if args.command == "submit" and not alive:
                continue
            found.append((date(availability["updatedAt"]), inbox, availability))
        except (OSError, ValueError, KeyError, TypeError):
            continue
    if not found:
        raise ValueError("No compatible ControlWard research workspace found. Open the app; use --review-id for a review workspace. Normal-workspace access requires --live.")
    found.sort(key=lambda item: item[0], reverse=True)
    return found[0][1], found[0][2]


def sites_from_file(path):
    data = json.loads(Path(path).read_text())
    if not isinstance(data, list) or not 1 <= len(data) <= 10:
        raise ValueError("Supply 1–10 discovered businesses as a JSON array")
    out, seen = [], set()
    for item in data:
        if not isinstance(item, dict) or set(item) != {"name", "url"}:
            raise ValueError("Candidates accept only name and url; contact details and AI claims are researched by ControlWard")
        name, raw = item["name"], item["url"]
        if not isinstance(name, str) or not 1 <= len(name) <= 200 or any(c in name for c in "|\r\n"):
            raise ValueError("Invalid business name")
        if not isinstance(raw, str) or any(c in raw for c in "\r\n"):
            raise ValueError("Invalid website")
        parts = urlsplit(raw)
        host = (parts.hostname or "").lower().rstrip(".")
        if parts.scheme not in ("https", "http") or not host or "." not in host or parts.username or parts.password:
            raise ValueError("Only public HTTP(S) business websites are accepted")
        if parts.port and parts.port != (443 if parts.scheme == "https" else 80):
            raise ValueError("Non-default ports are refused")
        if host.endswith((".local", ".internal", ".localhost", ".lan", ".arpa")):
            raise ValueError("Private websites are refused")
        try:
            ipaddress.ip_address(host)
        except ValueError:
            pass
        else:
            raise ValueError("IP-literal websites are refused")
        domain = host.removeprefix("www.")
        if domain in seen:
            continue
        seen.add(domain)
        out.append({"name": name, "url": urlunsplit((parts.scheme, parts.netloc, parts.path or "/", "", ""))})
    return out


def private_json(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.parent / ("." + str(uuid.uuid4()) + ".tmp")
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump(value, handle, ensure_ascii=False)
            handle.flush()
            os.fsync(handle.fileno())
        # Publishing a complete file is atomic, and an existing job is never overwritten.
        os.link(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["capabilities", "submit", "status", "cancel"])
    parser.add_argument("--review-id")
    parser.add_argument("--live", action="store_true", help="Explicitly permit the normal workspace")
    parser.add_argument("--query")
    parser.add_argument("--input", type=Path)
    parser.add_argument("--batch-id")
    args = parser.parse_args()
    inbox, availability = select_workspace(args)
    if args.command == "capabilities":
        result = {"schema": 1, "mode": availability["mode"], "build": availability["build"], "app_running": availability["app_running"], "inbox": str(inbox), "max_candidates": 10, "auto_send": False}
    elif args.command == "submit":
        if not args.query or len(args.query) > 1000 or args.input is None:
            raise ValueError("Submit requires --query and --input")
        sites = sites_from_file(args.input)
        batch = str(uuid.uuid4())
        now = utc()
        ids = []
        for offset in range(0, len(sites), 3):
            job = str(uuid.uuid4())
            request = {"schema": 1, "id": job, "batchID": batch, "query": args.query,
                       "createdAt": now.isoformat(timespec="milliseconds"), "expiresAt": (now + dt.timedelta(hours=1)).isoformat(timespec="milliseconds"), "sites": sites[offset:offset + 3]}
            private_json(inbox / "requests" / (job + ".json"), request)
            ids.append(job)
        result = {"batch_id": batch, "request_ids": ids, "candidates": len(sites), "status": "submitted", "mode": availability["mode"], "outreach_sent": False}
    else:
        if not args.batch_id:
            raise ValueError("Status/cancel requires --batch-id")
        batch = v4(args.batch_id)
        if args.command == "cancel":
            marker = inbox / "cancel" / (batch + ".json")
            if not marker.exists():
                private_json(marker, {"cancelled": True})
            result = {"batch_id": batch, "status": "cancellation_requested"}
        else:
            results = []
            for path in sorted((inbox / "requests").glob("*.json")):
                request = json.loads(path.read_text())
                if request.get("batchID", "").lower() != batch:
                    continue
                output = inbox / "results" / path.name
                results.append(json.loads(output.read_text()) if output.exists() else {"id": request["id"], "status": "pending", "entries": []})
            if not results:
                raise ValueError("Unknown batch")
            result = {"batch_id": batch, "app_running": availability["app_running"], "finished": all(r["status"] not in ("pending", "running") for r in results), "requests": results}
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        sys.exit(1)
