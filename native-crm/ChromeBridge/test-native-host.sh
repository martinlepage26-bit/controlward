#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
"$SCRIPT_DIR/build-native-host.sh"
HOST="$REPO_ROOT/.work/chrome-native-host/ControlWardChromeNativeHost"
python3 - "$HOST" <<'PY'
import json, os, pathlib, struct, subprocess, sys, tempfile
host = str(pathlib.Path(sys.argv[1]).resolve())
extension_id = "a" * 32

def call(env, op, request_id, token=None, extra=None):
    request = {"version": 1, "requestID": request_id, "op": op, "extensionID": extension_id}
    if token is not None:
        request["token"] = token
    if extra:
        request.update(extra)
    body = json.dumps(request, separators=(",", ":")).encode()
    result = subprocess.run([host, "--controlward-chrome-native-messaging"], input=struct.pack("<I", len(body)) + body,
                            env=env, capture_output=True, timeout=15)
    assert result.returncode == 0, f"{op}: host exit {result.returncode}: {result.stderr.decode(errors='replace')}"
    assert len(result.stdout) >= 4, f"{op}: no framed response"
    length = struct.unpack("<I", result.stdout[:4])[0]
    assert length == len(result.stdout) - 4, f"{op}: bad frame length"
    return json.loads(result.stdout[4:])

with tempfile.TemporaryDirectory(prefix="controlward-native-host-test-") as temporary:
    env = os.environ.copy()
    env["CONTROLWARD_LEADS_DIR"] = str(pathlib.Path(temporary) / "leads")
    bad_id = call(env, "status", "bad-id", extra={"extensionID": "z" * 32})
    assert bad_id.get("error", {}).get("code") == "extension-id", bad_id
    extra_field = call(env, "status", "extra", extra={"unexpected": True})
    assert extra_field.get("error", {}).get("code") == "unknown-field", extra_field
    status = call(env, "status", "status-1")
    assert status.get("ok") and status.get("paired") is False and len(status.get("segments", [])) == 7, status
    paired = call(env, "pair", "pair-1")
    token = paired.get("pairingToken")
    assert paired.get("ok") and paired.get("paired") and isinstance(token, str) and len(token) >= 40, paired
    wrong = "X" * len(token)
    for operation, extras in [("unpair", {}), ("evaluate", {"capture": {}}),
                              ("save", {"previewID": "test", "decision": "create", "confirm": True})]:
        denied = call(env, operation, f"bad-{operation}", wrong, extras)
        assert denied.get("error", {}).get("code") == "pairing-invalid", (operation, denied)
    still_paired = call(env, "status", "status-2")
    assert still_paired.get("paired") is True, still_paired
    unpaired = call(env, "unpair", "unpair-1", token)
    assert unpaired.get("ok") and unpaired.get("paired") is False, unpaired
    final_status = call(env, "status", "status-3")
    assert final_status.get("paired") is False, final_status
    print("Native host protocol tests passed: schema/extension checks, 7 bundled segments, pair, invalid-token denials, and unpair. Temporary test Leads directory only; no Chrome registration or app data access.")
PY
