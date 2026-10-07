#!/usr/bin/env python3
"""Put an uploaded build into internal TestFlight.

Sets usesNonExemptEncryption to false when App Store Connect has no answer,
adds the build to each internal beta group, and waits until processing is
VALID and the internal state is ready for testers. Does not print API keys,
tokens, team ids, or tester addresses.
"""

import importlib.util
import json
import os
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path

BUNDLE_ID = "com.lojo.WatchRemote"
READY_INTERNAL = ("IN_BETA_TESTING", "READY_FOR_BETA_TESTING")
HERE = Path(__file__).resolve().parent


def load_signing():
    spec = importlib.util.spec_from_file_location("asc_signing", HERE / "asc_signing.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


signing = load_signing()


def show(text):
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


def value_text(value):
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    return str(value)


def parsed(status, body, context):
    if status == 204:
        return {}
    try:
        data = json.loads(body) if body else {}
    except json.JSONDecodeError:
        signing.stop_api(status, body, context)
    if status not in (200, 201, 204):
        # Tester invites can echo an address. Keep that body off the log.
        if "tester" in context:
            sys.stderr.write(f"{context} failed with HTTP {status}.\n")
            raise SystemExit(1)
        signing.stop_api(status, body or f"HTTP {status}", context)
    return data


def find_app(token):
    query = urllib.parse.urlencode({"filter[bundleId]": BUNDLE_ID, "limit": "5"})
    status, body = signing.api(token, "GET", "/v1/apps?" + query)
    data = parsed(status, body, "app lookup")
    for item in data.get("data", []):
        if item.get("attributes", {}).get("bundleId") == BUNDLE_ID:
            return item["id"]
    sys.stderr.write(f"No App Store Connect app for {BUNDLE_ID}.\n")
    raise SystemExit(1)


def find_build(token, app_id, version):
    query = urllib.parse.urlencode(
        {
            "filter[app]": app_id,
            "filter[version]": version,
            "include": "buildBetaDetail",
            "limit": "10",
            "fields[builds]": "version,processingState,usesNonExemptEncryption,uploadedDate,expired",
        }
    )
    status, body = signing.api(token, "GET", "/v1/builds?" + query)
    data = parsed(status, body, "build lookup")
    matches = [
        item for item in data.get("data", [])
        if str(item.get("attributes", {}).get("version")) == str(version)
    ]
    if not matches:
        return None
    matches.sort(key=lambda item: item.get("attributes", {}).get("uploadedDate") or "")
    build = matches[-1]
    detail = {}
    for item in data.get("included", []):
        if item.get("type") == "buildBetaDetails":
            detail = item.get("attributes") or {}
    return build, detail


def refresh_detail(token, build_id):
    status, body = signing.api(token, "GET", f"/v1/builds/{build_id}/buildBetaDetail")
    if status == 404:
        return {}
    data = parsed(status, body, "beta detail")
    return (data.get("data") or {}).get("attributes") or {}


def internal_groups(token, app_id):
    status, body = signing.api(token, "GET", f"/v1/apps/{app_id}/betaGroups?limit=50")
    data = parsed(status, body, "beta groups")
    groups = []
    for item in data.get("data", []):
        if item.get("attributes", {}).get("isInternalGroup"):
            groups.append(item)
    return groups


def ensure_internal_group(token, app_id):
    groups = internal_groups(token, app_id)
    if groups:
        return groups, False
    payload = {
        "data": {
            "type": "betaGroups",
            "attributes": {"name": "Internal", "isInternalGroup": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }
    }
    status, body = signing.api(token, "POST", "/v1/betaGroups", payload)
    data = parsed(status, body, "create internal group")
    return [data["data"]], True


def group_contains_build(token, group_id, build_id):
    """True, False, or None when this key cannot read the relationship.

    The CI key may create and delete a build's betaGroups link, and still
    reject GET /v1/builds/{id}/betaGroups. Listing builds from the group is
    the read that role allows. None means the caller should assign and use
    the write response to learn whether the build was already a member.
    """
    query = urllib.parse.urlencode({"limit": "200", "fields[builds]": "version"})
    path = f"/v1/betaGroups/{group_id}/builds?{query}"
    root = signing.API_ROOT
    for _page in range(5):
        status, body = signing.api(token, "GET", path)
        if status == 403:
            return None
        data = parsed(status, body, "group builds")
        for item in data.get("data", []):
            if item.get("id") == build_id:
                return True
        next_link = ((data.get("links") or {}).get("next")) or ""
        if next_link.startswith(root):
            path = next_link[len(root):]
            continue
        return False
    return False


def assign_build(token, group_id, build_id):
    payload = {"data": [{"type": "builds", "id": build_id}]}
    status, body = signing.api(
        token, "POST", f"/v1/betaGroups/{group_id}/relationships/builds", payload
    )
    if status in (204, 200):
        return "added"
    if status == 409:
        return "already"
    parsed(status, body, "assign build")
    return "added"


def tester_count(token, group_id):
    query = urllib.parse.urlencode({"limit": "20", "fields[betaTesters]": "state"})
    status, body = signing.api(token, "GET", f"/v1/betaGroups/{group_id}/betaTesters?{query}")
    if status == 403:
        return None
    data = parsed(status, body, "group testers")
    return len(data.get("data") or [])


def group_has_tester(token, group_id):
    count = tester_count(token, group_id)
    if count is None:
        return False
    return count > 0


def link_internal_testers(token, group_id):
    if group_has_tester(token, group_id):
        return 0
    status, body = signing.api(token, "GET", "/v1/users?limit=10")
    if status == 403:
        show("users lookup forbidden; left the internal group membership unchanged")
        return 0
    data = parsed(status, body, "users")
    linked = 0
    for user in data.get("data", []):
        email = (user.get("attributes") or {}).get("username") or ""
        if "@" not in email:
            continue
        payload = {
            "data": {
                "type": "betaTesters",
                "attributes": {"email": email},
                "relationships": {
                    "betaGroups": {"data": [{"type": "betaGroups", "id": group_id}]}
                },
            }
        }
        invite_status, invite_body = signing.api(token, "POST", "/v1/betaTesters", payload)
        if invite_status in (200, 201, 409):
            linked += 1
            continue
        if invite_status == 403:
            show("tester invite forbidden; left the internal group membership unchanged")
            return linked
        parsed(invite_status, invite_body, "tester invite")
    return linked


def set_encryption_false(token, build_id):
    payload = {
        "data": {
            "type": "builds",
            "id": build_id,
            "attributes": {"usesNonExemptEncryption": False},
        }
    }
    status, body = signing.api(token, "PATCH", f"/v1/builds/{build_id}", payload)
    parsed(status, body, "export compliance")


def report_found(version, attributes, detail, group_names):
    show(f"found build {version}")
    show("processingState=" + value_text(attributes.get("processingState")))
    show("usesNonExemptEncryption=" + value_text(attributes.get("usesNonExemptEncryption")))
    show("uploadedDate=" + value_text(attributes.get("uploadedDate")))
    show("expired=" + value_text(attributes.get("expired")))
    show("internalBuildState=" + value_text(detail.get("internalBuildState")))
    show("externalBuildState=" + value_text(detail.get("externalBuildState")))
    if group_names is None:
        show("internalGroups=unreadable")
    elif group_names:
        show("internalGroups=" + ",".join(group_names))
    else:
        show("internalGroups=none")


def membership_before_change(token, groups, build_id):
    names = []
    unreadable = False
    for group in groups:
        name = (group.get("attributes") or {}).get("name") or "internal"
        contained = group_contains_build(token, group["id"], build_id)
        count = tester_count(token, group["id"])
        count_text = "unknown" if count is None else str(count)
        if contained is None:
            unreadable = True
            show(f"internalGroup {name} containsBuild=unknown testers={count_text}")
            continue
        show(
            f"internalGroup {name} containsBuild="
            + ("true" if contained else "false")
            + f" testers={count_text}"
        )
        if contained:
            names.append(name)
    if unreadable:
        return None
    return names


def ensure_group_membership(token, groups, build_id, changes):
    for group in groups:
        name = (group.get("attributes") or {}).get("name") or "internal"
        contained = group_contains_build(token, group["id"], build_id)
        if contained is True:
            line = f"build already in internal group {name}"
            if line not in changes:
                changes.append(line)
                show(line)
            continue
        result = assign_build(token, group["id"], build_id)
        if result == "already":
            line = f"build already in internal group {name}"
        else:
            line = f"added build to internal group {name}"
        if line not in changes:
            changes.append(line)
            show(line)


def release(version, wait_seconds, require_ready):
    token = signing.jwt_from_env()
    app_id = find_app(token)
    found = None
    deadline = time.time() + min(180, wait_seconds)
    while found is None and time.time() < deadline:
        found = find_build(token, app_id, version)
        if found is None:
            time.sleep(15)
    if found is None:
        sys.stderr.write(f"Build {version} is not in App Store Connect yet.\n")
        raise SystemExit(1)
    build, detail = found
    build_id = build["id"]
    attributes = build.get("attributes") or {}
    if not detail:
        detail = refresh_detail(token, build_id)
    groups, created = ensure_internal_group(token, app_id)
    report_found(version, attributes, detail, membership_before_change(token, groups, build_id))
    if created:
        show("created internal group Internal")

    end = time.time() + wait_seconds
    changes = []
    while True:
        token = signing.jwt_from_env()
        current = find_build(token, app_id, version)
        if current is None:
            sys.stderr.write(f"Build {version} disappeared during release.\n")
            raise SystemExit(1)
        build, included = current
        attributes = build.get("attributes") or {}
        detail = included or refresh_detail(token, build_id)
        if attributes.get("usesNonExemptEncryption") is not False:
            set_encryption_false(token, build_id)
            if "set usesNonExemptEncryption=false" not in changes:
                changes.append("set usesNonExemptEncryption=false")
                show("set usesNonExemptEncryption=false")
        groups, _created = ensure_internal_group(token, app_id)
        ensure_group_membership(token, groups, build_id, changes)
        for group in groups:
            name = (group.get("attributes") or {}).get("name") or "internal"
            linked = link_internal_testers(token, group["id"])
            if linked:
                line = f"linked {linked} internal testers to {name}"
                if line not in changes:
                    changes.append(line)
                    show(line)
        processing = attributes.get("processingState")
        internal = detail.get("internalBuildState")
        if processing == "VALID" and internal in READY_INTERNAL:
            show("final processingState=" + value_text(processing))
            show("final internalBuildState=" + value_text(internal))
            if not changes:
                show("changed=none")
            return
        if time.time() >= end:
            show("final processingState=" + value_text(processing))
            show("final internalBuildState=" + value_text(internal))
            if require_ready:
                sys.stderr.write("Build is not in internal testing yet.\n")
                raise SystemExit(1)
            show("still waiting on App Store Connect processing")
            return
        time.sleep(20)


def write_key(destination):
    raw = os.environ.get("ASC_KEY_P8", "")
    text = raw.replace("\r\n", "\n").replace("\r", "\n").lstrip("\ufeff").strip()
    path = Path(destination)
    path.parent.mkdir(parents=True, exist_ok=True)
    if text.startswith("-----BEGIN PRIVATE KEY-----"):
        if not text.endswith("\n"):
            text += "\n"
        path.write_text(text)
        return
    compact = "".join(text.split())
    if not compact:
        raise SystemExit("ASC_KEY_P8 is empty.")
    import base64
    pad = "=" * ((-len(compact)) % 4)
    try:
        data = base64.b64decode(compact + pad, validate=True)
    except Exception:
        raise SystemExit("ASC_KEY_P8 is not valid base64 and is not a PEM private key.")
    if b"PRIVATE KEY" not in data:
        raise SystemExit("ASC_KEY_P8 decoded, but it does not look like a .p8 private key.")
    path.write_bytes(data)


def prepare_key():
    if os.environ.get("KEY_PATH"):
        return None
    handle = tempfile.NamedTemporaryFile(prefix="AuthKey_", suffix=".p8", delete=False)
    handle.close()
    write_key(handle.name)
    os.environ["KEY_PATH"] = handle.name
    return handle.name


def self_test():
    state = {
        "encryption": None,
        "processing": "PROCESSING",
        "internal": "MISSING_EXPORT_COMPLIANCE",
        "groups": [],
        "assigned": set(),
        "testers": set(),
        "users_listed": 0,
        "ticks": 0,
    }

    def api(token, method, path, payload=None):
        state["ticks"] += 1
        if path.startswith("/v1/apps?") or path.startswith("/v1/apps?"):
            return 200, json.dumps({
                "data": [{"type": "apps", "id": "APP", "attributes": {"bundleId": BUNDLE_ID}}]
            })
        if path.startswith("/v1/builds?"):
            if state["ticks"] > 8:
                state["processing"] = "VALID"
                state["internal"] = "IN_BETA_TESTING"
            return 200, json.dumps({
                "data": [{
                    "type": "builds",
                    "id": "BUILD",
                    "attributes": {
                        "version": "164",
                        "processingState": state["processing"],
                        "usesNonExemptEncryption": state["encryption"],
                        "uploadedDate": "2026-10-07T22:55:25Z",
                        "expired": False,
                    },
                }],
                "included": [{
                    "type": "buildBetaDetails",
                    "id": "BUILD",
                    "attributes": {"internalBuildState": state["internal"]},
                }],
            })
        if path == "/v1/apps/APP/betaGroups?limit=50":
            return 200, json.dumps({"data": state["groups"]})
        if path == "/v1/betaGroups" and method == "POST":
            state["groups"] = [{
                "type": "betaGroups",
                "id": "GROUP",
                "attributes": {"name": "Internal", "isInternalGroup": True},
            }]
            return 201, json.dumps({"data": state["groups"][0]})
        if "/builds/BUILD/betaGroups" in path:
            state["used_forbidden_read"] = True
            return 403, json.dumps({
                "errors": [{
                    "status": "403",
                    "code": "FORBIDDEN_ERROR",
                    "detail": "The relationship 'betaGroups' does not allow 'GET_RELATED'.",
                }]
            })
        if path.startswith("/v1/betaGroups/GROUP/builds"):
            if state.get("hide_group_builds"):
                return 403, json.dumps({
                    "errors": [{"status": "403", "code": "FORBIDDEN_ERROR", "detail": "GET_RELATED"}]
                })
            data = []
            if "GROUP" in state["assigned"]:
                data.append({"type": "builds", "id": "BUILD", "attributes": {"version": "164"}})
            return 200, json.dumps({"data": data})
        if path == "/v1/builds/BUILD" and method == "PATCH":
            state["encryption"] = False
            state["processing"] = "VALID"
            state["internal"] = "READY_FOR_BETA_TESTING"
            return 200, json.dumps({"data": {"type": "builds", "id": "BUILD"}})
        if path == "/v1/betaGroups/GROUP/relationships/builds" and method == "POST":
            state["assigned"].add("GROUP")
            state["internal"] = "IN_BETA_TESTING"
            return 204, ""
        if path.startswith("/v1/betaGroups/GROUP/betaTesters"):
            testers = [{"id": "T", "attributes": {"state": "ACTIVE"}}] if state["testers"] else []
            return 200, json.dumps({"data": testers})
        if path.startswith("/v1/users"):
            state["users_listed"] += 1
            return 200, json.dumps({
                "data": [{
                    "type": "users",
                    "id": "USER",
                    "attributes": {"username": "owner@example.com"},
                }]
            })
        if path == "/v1/betaTesters" and method == "POST":
            state["testers"].add("USER")
            return 201, json.dumps({"data": {"type": "betaTesters", "id": "T"}})
        if path == "/v1/builds/BUILD/buildBetaDetail":
            return 200, json.dumps({
                "data": {
                    "type": "buildBetaDetails",
                    "id": "BUILD",
                    "attributes": {"internalBuildState": state["internal"]},
                }
            })
        return 404, "{}"

    real_api = signing.api
    real_jwt = signing.jwt_from_env
    real_sleep = time.sleep
    signing.api = api
    signing.jwt_from_env = lambda: "token"
    time.sleep = lambda _seconds: None
    held = sys.stdout
    sys.stdout = captured = __import__("io").StringIO()
    try:
        release("164", wait_seconds=60, require_ready=True)
        text = captured.getvalue()
        captured.seek(0)
        captured.truncate(0)
        state["encryption"] = None
        state["processing"] = "PROCESSING"
        state["internal"] = "MISSING_EXPORT_COMPLIANCE"
        state["groups"] = [{
            "type": "betaGroups",
            "id": "GROUP",
            "attributes": {"name": "Internal", "isInternalGroup": True},
        }]
        state["assigned"] = set()
        state["testers"] = {"USER"}
        state["ticks"] = 0
        state["hide_group_builds"] = True
        state["used_forbidden_read"] = False
        release("164", wait_seconds=60, require_ready=True)
        hidden = captured.getvalue()
    finally:
        sys.stdout = held
        signing.api = real_api
        signing.jwt_from_env = real_jwt
        time.sleep = real_sleep
    required = (
        "found build 164",
        "processingState=PROCESSING",
        "usesNonExemptEncryption=null",
        "uploadedDate=2026-10-07T22:55:25Z",
        "internalBuildState=MISSING_EXPORT_COMPLIANCE",
        "internalGroups=none",
        "created internal group Internal",
        "set usesNonExemptEncryption=false",
        "added build to internal group Internal",
        "linked 1 internal testers to Internal",
        "final processingState=VALID",
        "final internalBuildState=IN_BETA_TESTING",
    )
    for line in required:
        if line not in text:
            raise SystemExit("self-test missing: " + line)
    if "owner@example.com" in text:
        raise SystemExit("self-test printed a tester address")
    if state["encryption"] is not False or "GROUP" not in state["assigned"]:
        raise SystemExit("self-test did not update compliance and the group")
    if state.get("used_forbidden_read"):
        raise SystemExit("self-test read a build's betaGroups relationship")
    for line in (
        "internalGroups=unreadable",
        "added build to internal group Internal",
        "final processingState=VALID",
        "final internalBuildState=IN_BETA_TESTING",
    ):
        if line not in hidden:
            raise SystemExit("self-test missing after unreadable groups: " + line)
    if "owner@example.com" in hidden:
        raise SystemExit("self-test printed a tester address")
    show("asc testflight: ok")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
        return
    if len(sys.argv) > 1 and sys.argv[1] == "release":
        version = os.environ.get("BUILD_NUMBER", "")
        wait_seconds = 900
        require_ready = False
        args = sys.argv[2:]
        index = 0
        while index < len(args):
            flag = args[index]
            if flag == "--require-ready":
                require_ready = True
                index += 1
                continue
            if index + 1 >= len(args):
                raise SystemExit("Missing a release argument.")
            if flag == "--build":
                version = args[index + 1]
            elif flag == "--wait-seconds":
                wait_seconds = int(args[index + 1])
            else:
                raise SystemExit("Unknown release argument.")
            index += 2
        if not version:
            raise SystemExit("Missing build number.")
        key_file = prepare_key()
        try:
            release(version, wait_seconds, require_ready)
        finally:
            if key_file:
                Path(key_file).unlink(missing_ok=True)
        return
    raise SystemExit("Usage: asc_testflight.py --self-test | release [--build N] [--wait-seconds N] [--require-ready]")


if __name__ == "__main__":
    main()
