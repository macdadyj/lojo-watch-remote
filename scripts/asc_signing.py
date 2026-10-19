#!/usr/bin/env python3
"""Install App Store profiles for the shared iOS Distribution certificate.

Uses the App Store Connect REST API (ES256 JWT, audience appstoreconnect-v1).
The certificate already exists (id VJ5MXTN7UT). This script never creates or
revokes a certificate. It reuses an App Store profile for each app bundle id
when that profile is active and includes the shared certificate, and creates
one when it does not. It does not print private keys, API tokens, or passwords.
"""

import base64
import io
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API_ROOT = "https://api.appstoreconnect.apple.com"
PROFILE_TYPE = "IOS_APP_STORE"
CERTIFICATE_TYPE = "IOS_DISTRIBUTION"
# Shared iOS Distribution certificate. Profiles are created against this id.
CERTIFICATE_ID = "VJ5MXTN7UT"
PROFILE_NAMES = {
    "com.lojo.WatchRemote": "WatchRemote App Store",
    "com.lojo.WatchRemote.watchkitapp": "WatchRemoteWatch App Store",
}
SKIP_TARGET_TYPES = {"bundle.ui-testing", "bundle.unit-test"}
SIGNING_KEYS = (
    "CODE_SIGN_STYLE",
    "CODE_SIGN_IDENTITY",
    "DEVELOPMENT_TEAM",
    "PROVISIONING_PROFILE_SPECIFIER",
    "OTHER_CODE_SIGN_FLAGS",
)


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def b64url_decode(text):
    pad = "=" * ((-len(text)) % 4)
    return base64.urlsafe_b64decode(text + pad)


def der_to_raw(der):
    """Turn an OpenSSL ECDSA DER signature into the 64-byte JWT form."""
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("not a DER signature")
    index = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    numbers = []
    for _ in range(2):
        if index >= len(der) or der[index] != 0x02:
            raise ValueError("expected an integer in the signature")
        index += 1
        length = der[index]
        index += 1
        if length & 0x80:
            count = length & 0x7F
            length = int.from_bytes(der[index:index + count], "big")
            index += count
        value = der[index:index + length]
        index += length
        value = value.lstrip(b"\x00")
        if len(value) > 32:
            raise ValueError("signature integer is too wide")
        numbers.append(value.rjust(32, b"\x00"))
    return numbers[0] + numbers[1]


def raw_to_der(raw):
    if len(raw) != 64:
        raise ValueError("expected a 64-byte signature")

    def encode(part):
        value = part.lstrip(b"\x00") or b"\x00"
        if value[0] & 0x80:
            value = b"\x00" + value
        return b"\x02" + bytes([len(value)]) + value

    body = encode(raw[:32]) + encode(raw[32:])
    return b"\x30" + bytes([len(body)]) + body


def sign_es256(pem, message):
    with tempfile.NamedTemporaryFile() as key_file:
        key_file.write(pem if pem.endswith(b"\n") else pem + b"\n")
        key_file.flush()
        signed = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_file.name],
            input=message,
            capture_output=True,
            check=False,
        )
    if signed.returncode != 0 or not signed.stdout:
        raise SystemExit("Could not sign the App Store Connect request.")
    return der_to_raw(signed.stdout)


def make_jwt(pem, key_id, issuer, now):
    header = b64url(json.dumps(
        {"alg": "ES256", "kid": key_id, "typ": "JWT"},
        separators=(",", ":"),
    ).encode())
    payload = b64url(json.dumps(
        {
            "iss": issuer,
            "iat": now,
            "exp": now + (19 * 60),
            "aud": "appstoreconnect-v1",
        },
        separators=(",", ":"),
    ).encode())
    signing_input = f"{header}.{payload}".encode()
    signature = b64url(sign_es256(pem, signing_input))
    return f"{header}.{payload}.{signature}"


def stop_api(status, body, context):
    text = body.strip() or f"HTTP {status}"
    sys.stderr.write(text)
    if not text.endswith("\n"):
        sys.stderr.write("\n")
    sys.stderr.write(
        f"{context} failed with HTTP {status}. "
        "Stopped. No distribution certificate was created or revoked.\n"
    )
    raise SystemExit(1)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def api(token, method, path, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(API_ROOT + path, data=data, method=method)
    request.add_header("Authorization", "Bearer " + token)
    request.add_header("Accept", "application/json")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(request, timeout=60) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()
    except urllib.error.URLError:
        raise SystemExit(
            "Could not reach App Store Connect. "
            "Stopped. No distribution certificate was created or revoked."
        )


def load_pem(path):
    return Path(path).read_bytes()


def jwt_from_env():
    pem = load_pem(os.environ["KEY_PATH"])
    return make_jwt(
        pem,
        os.environ["ASC_KEY_ID"],
        os.environ["ASC_ISSUER_ID"],
        int(time.time()),
    )


def parse_data(status, body, context):
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        stop_api(status, body, context)
    if status not in (200, 201) or "data" not in parsed:
        stop_api(status, body, context)
    return parsed


def profile_name_for(bundle_id, target_name):
    if bundle_id in PROFILE_NAMES:
        return PROFILE_NAMES[bundle_id]
    leaf = target_name or bundle_id.rsplit(".", 1)[-1]
    return f"{leaf} App Store"


def signable_type(target_type):
    if target_type in SKIP_TARGET_TYPES:
        return False
    if target_type == "application":
        return True
    return "extension" in target_type


def distribution_targets(project_text):
    """App and extension bundle ids the archive must sign. Test bundles are omitted."""
    in_targets = False
    targets = []
    current_type = None
    current_bundle = None
    current_name = None

    def flush():
        nonlocal current_type, current_bundle, current_name
        if current_bundle and current_type and signable_type(current_type):
            targets.append((current_bundle, profile_name_for(current_bundle, current_name)))
        current_type = None
        current_bundle = None
        current_name = None

    for line in project_text.splitlines():
        if line.startswith("targets:"):
            in_targets = True
            continue
        if not in_targets:
            continue
        if line.startswith("schemes:"):
            flush()
            break
        if line.startswith("  ") and not line.startswith("   ") and line.rstrip().endswith(":"):
            flush()
            current_name = line.strip()[:-1]
            continue
        stripped = line.strip()
        if stripped.startswith("type:"):
            current_type = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("PRODUCT_BUNDLE_IDENTIFIER:"):
            current_bundle = stripped.split(":", 1)[1].strip()
    flush()
    return targets


def find_bundle_id(token, identifier):
    query = urllib.parse.urlencode(
        {"filter[identifier]": identifier, "limit": "5"}
    )
    status, body = api(token, "GET", "/v1/bundleIds?" + query)
    parsed = parse_data(status, body, "bundle ID lookup")
    for item in parsed["data"]:
        if item.get("attributes", {}).get("identifier") == identifier:
            return item["id"]
    sys.stderr.write(
        f"No App Store Connect bundle ID for {identifier}. "
        "Create that App ID first. No distribution certificate was created or revoked.\n"
    )
    raise SystemExit(1)


def delete_profile(token, profile_id):
    status, body = api(token, "DELETE", "/v1/profiles/" + urllib.parse.quote(profile_id))
    if status in (204, 404):
        return
    stop_api(status, body, "profile delete")


def list_named_profiles(token, name):
    query = urllib.parse.urlencode(
        {
            "filter[name]": name,
            "filter[profileType]": PROFILE_TYPE,
            "include": "bundleId,certificates",
            "limit": "20",
        }
    )
    status, body = api(token, "GET", "/v1/profiles?" + query)
    parsed = parse_data(status, body, "profile lookup")
    rows = []
    for item in parsed["data"]:
        attributes = item.get("attributes") or {}
        if attributes.get("name") != name or attributes.get("profileType") != PROFILE_TYPE:
            continue
        rows.append(item)
    return rows


def fetch_profile(token, profile_id):
    query = urllib.parse.urlencode({"include": "bundleId,certificates"})
    status, body = api(
        token,
        "GET",
        "/v1/profiles/" + urllib.parse.quote(profile_id) + "?" + query,
    )
    parsed = parse_data(status, body, "profile")
    return parsed["data"]


def profile_usable(profile, certificate_id, bundle_resource_id):
    attributes = profile.get("attributes") or {}
    if attributes.get("profileType") != PROFILE_TYPE:
        return False
    if attributes.get("profileState") != "ACTIVE":
        return False
    expiration = attributes.get("expirationDate") or ""
    if expiration and expiration < time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()):
        return False
    relationships = profile.get("relationships") or {}
    certificates = (relationships.get("certificates") or {}).get("data") or []
    if not any(item.get("id") == certificate_id for item in certificates):
        return False
    bundle = (relationships.get("bundleId") or {}).get("data") or {}
    return bundle.get("id") == bundle_resource_id


def profile_bytes(profile):
    content = (profile.get("attributes") or {}).get("profileContent")
    if not content:
        return b""
    return base64.b64decode(content)


def create_profile(token, name, bundle_resource_id, certificate_id):
    status, body = api(
        token,
        "POST",
        "/v1/profiles",
        {
            "data": {
                "type": "profiles",
                "attributes": {
                    "name": name,
                    "profileType": PROFILE_TYPE,
                },
                "relationships": {
                    "bundleId": {
                        "data": {"type": "bundleIds", "id": bundle_resource_id}
                    },
                    "certificates": {
                        "data": [{"type": "certificates", "id": certificate_id}]
                    },
                },
            }
        },
    )
    parsed = parse_data(status, body, "profile")
    content = parsed["data"].get("attributes", {}).get("profileContent")
    if not content:
        stop_api(status, body, "profile")
    return parsed["data"]["id"], base64.b64decode(content)


def install_profile(raw, profile_id, directory):
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{profile_id}.mobileprovision"
    path.write_bytes(raw)
    os.chmod(path, 0o644)
    return path


def fetch_certificate_der(token, certificate_id):
    status, body = api(token, "GET", "/v1/certificates/" + urllib.parse.quote(certificate_id))
    parsed = parse_data(status, body, "certificate lookup")
    attributes = parsed["data"].get("attributes") or {}
    if attributes.get("certificateType") not in (None, CERTIFICATE_TYPE):
        raise SystemExit(
            "The shared certificate is not an iOS Distribution certificate. "
            "Stopped. No distribution certificate was created or revoked."
        )
    content = attributes.get("certificateContent")
    if not content:
        stop_api(status, body, "certificate lookup")
    return base64.b64decode(content)


def canonical_der(data):
    """Re-encode a certificate so two copies of the same cert compare equal."""
    with tempfile.NamedTemporaryFile() as handle:
        handle.write(data)
        handle.flush()
        converted = subprocess.run(
            ["openssl", "x509", "-inform", "DER", "-in", handle.name, "-outform", "DER"],
            capture_output=True,
            check=False,
        )
    if converted.returncode == 0 and converted.stdout:
        return converted.stdout
    return None


def assert_same_certificate(local_der, remote_der):
    if local_der == remote_der:
        return
    left = canonical_der(local_der)
    right = canonical_der(remote_der)
    if left is not None and left == right:
        return
    raise SystemExit(
        "The imported distribution certificate does not match the shared "
        "App Store Connect certificate. Stopped. No distribution certificate "
        "was created or revoked."
    )


def ensure_profile(token, bundle_id, profile_name, bundle_resource_id, certificate_id):
    """Return (profile id, bytes, name, created). Never creates a certificate."""
    rows = []
    for item in list_named_profiles(token, profile_name):
        record = item
        if not profile_usable(record, certificate_id, bundle_resource_id) or not profile_bytes(record):
            record = fetch_profile(token, item["id"])
        rows.append(record)
    for record in rows:
        if profile_usable(record, certificate_id, bundle_resource_id):
            raw = profile_bytes(record)
            if not raw:
                stop_api(200, "profile has no content", "profile")
            name = (record.get("attributes") or {}).get("name") or profile_name
            return record["id"], raw, name, False
    for record in rows:
        if (record.get("attributes") or {}).get("name") == profile_name:
            delete_profile(token, record["id"])
    profile_id, raw = create_profile(token, profile_name, bundle_resource_id, certificate_id)
    return profile_id, raw, profile_name, True


def bundle_in_block(text, bundle_id):
    return (
        f"PRODUCT_BUNDLE_IDENTIFIER = {bundle_id};" in text
        or f'PRODUCT_BUNDLE_IDENTIFIER = "{bundle_id}";' in text
    )


def patch_pbxproj(text, team, keychain, profiles, identity):
    lines = text.splitlines(keepends=True)
    output = []
    index = 0
    while index < len(lines):
        if "buildSettings = {" not in lines[index]:
            output.append(lines[index])
            index += 1
            continue
        block = [lines[index]]
        index += 1
        depth = lines[index - 1].count("{") - lines[index - 1].count("}")
        while index < len(lines) and depth > 0:
            block.append(lines[index])
            depth += lines[index].count("{") - lines[index].count("}")
            index += 1
        joined = "".join(block)
        matched = None
        for bundle_id, profile_name in profiles:
            if bundle_in_block(joined, bundle_id):
                matched = profile_name
                break
        if matched is None:
            output.extend(block)
            continue
        output.extend(rewrite_settings(block, team, keychain, matched, identity))
    return "".join(output)


def rewrite_settings(block, team, keychain, profile_name, identity):
    indent = "\t\t\t\t"
    for line in block:
        stripped = line.lstrip()
        if stripped.startswith("PRODUCT_BUNDLE_IDENTIFIER"):
            indent = line[:len(line) - len(stripped)]
            break
    kept = []
    for line in block[:-1]:
        stripped = line.strip()
        if any(stripped.startswith(key + " ") or stripped.startswith(key + "=") for key in SIGNING_KEYS):
            continue
        kept.append(line)
    flag = f"--keychain {keychain}"
    settings = [
        f"{indent}CODE_SIGN_STYLE = Manual;\n",
        f'{indent}CODE_SIGN_IDENTITY = "{identity}";\n',
        f"{indent}DEVELOPMENT_TEAM = {team};\n",
        f'{indent}PROVISIONING_PROFILE_SPECIFIER = "{profile_name}";\n',
        f'{indent}OTHER_CODE_SIGN_FLAGS = "{flag}";\n',
    ]
    kept.extend(settings)
    kept.append(block[-1])
    return kept


def write_export_options(path, team, profiles, identity):
    payload = {
        "method": "app-store-connect",
        "signingStyle": "manual",
        "signingCertificate": identity,
        "teamID": team,
        "destination": "upload",
        "uploadSymbols": True,
        "manageAppVersionAndBuildNumber": False,
        "provisioningProfiles": {bundle_id: name for bundle_id, name in profiles},
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        plistlib.dump(payload, handle)


def write_manifest(path, certificate_id, profiles):
    payload = {
        "certificateId": certificate_id,
        "profiles": profiles,
    }
    Path(path).write_text(json.dumps(payload))
    os.chmod(path, 0o600)


def prepare(argv):
    identity = argv["identity"]
    if any(char in identity for char in '"\n\\'):
        raise SystemExit("The signing identity could not be used.")
    certificate_der = Path(argv["certificate_der"]).read_bytes()
    if not certificate_der:
        raise SystemExit("The imported distribution certificate is empty.")
    manifest_path = Path(argv["manifest"])
    profiles_dir = Path(argv["profiles_dir"]).expanduser()
    project_text = Path(argv["project_yml"]).read_text()
    targets = distribution_targets(project_text)
    if not targets:
        raise SystemExit("No app targets to sign.")
    print(f"Using the shared iOS Distribution certificate {CERTIFICATE_ID}.", flush=True)
    token = jwt_from_env()
    remote_der = fetch_certificate_der(token, CERTIFICATE_ID)
    assert_same_certificate(certificate_der, remote_der)
    write_manifest(manifest_path, CERTIFICATE_ID, [])
    installed = []
    resolved = []
    try:
        for bundle_id, profile_name in targets:
            resource_id = find_bundle_id(token, bundle_id)
            profile_id, raw, actual_name, created = ensure_profile(
                token, bundle_id, profile_name, resource_id, CERTIFICATE_ID
            )
            if created:
                print(f"Created an App Store profile for {bundle_id}.", flush=True)
            else:
                print(f"Using an existing App Store profile for {bundle_id}.", flush=True)
            path = install_profile(raw, profile_id, profiles_dir)
            installed.append(
                {
                    "id": profile_id,
                    "name": actual_name,
                    "bundleId": bundle_id,
                    "path": str(path),
                    "created": created,
                }
            )
            resolved.append((bundle_id, actual_name))
            write_manifest(manifest_path, CERTIFICATE_ID, installed)
    except SystemExit:
        write_manifest(manifest_path, CERTIFICATE_ID, installed)
        raise
    project = Path(argv["pbxproj"])
    patched = patch_pbxproj(project.read_text(), argv["team"], argv["keychain"], resolved, identity)
    if patched.count("CODE_SIGN_STYLE = Manual;") < len(resolved):
        raise SystemExit(
            "Could not set manual signing on every app target. "
            "No distribution certificate was created or revoked."
        )
    if identity not in patched:
        raise SystemExit(
            "Could not set the distribution identity. "
            "No distribution certificate was created or revoked."
        )
    project.write_text(patched)
    write_export_options(Path(argv["export_plist"]), argv["team"], resolved, identity)
    write_manifest(manifest_path, CERTIFICATE_ID, installed)


def cleanup():
    """Remove local profile files recorded for this run. Does not call the API."""
    manifest_path = Path(os.environ["SIGNING_MANIFEST"])
    if not manifest_path.is_file():
        return
    manifest = json.loads(manifest_path.read_text())
    for profile in manifest.get("profiles", []):
        path = profile.get("path")
        if path:
            Path(path).unlink(missing_ok=True)


def der_roundtrip():
    raw = bytes(range(32)) + bytes(range(32, 64))
    raw = b"\x80" + raw[1:32] + b"\x7f" + raw[33:]
    der = raw_to_der(raw)
    if der_to_raw(der) != raw:
        raise SystemExit("DER signature roundtrip failed")


def jwt_roundtrip():
    with tempfile.TemporaryDirectory() as directory:
        key_path = Path(directory) / "key.pem"
        created = subprocess.run(
            [
                "openssl",
                "ecparam",
                "-name",
                "prime256v1",
                "-genkey",
                "-noout",
                "-out",
                str(key_path),
            ],
            capture_output=True,
            check=False,
        )
        if created.returncode != 0:
            raise SystemExit("Could not generate a test signing key.")
        pem = key_path.read_bytes()
        token = make_jwt(pem, "KEYID1234", "issuer-id", 1_700_000_000)
        header_text, payload_text, signature_text = token.split(".")
        header = json.loads(b64url_decode(header_text))
        payload = json.loads(b64url_decode(payload_text))
        if header.get("alg") != "ES256" or header.get("kid") != "KEYID1234":
            raise SystemExit("JWT header was not ES256")
        if payload.get("aud") != "appstoreconnect-v1" or payload.get("iss") != "issuer-id":
            raise SystemExit("JWT audience was not appstoreconnect-v1")
        if b"BEGIN PRIVATE KEY" in token.encode() or b"BEGIN EC PRIVATE KEY" in token.encode():
            raise SystemExit("JWT included the private key")
        public_path = Path(directory) / "pub.pem"
        extracted = subprocess.run(
            ["openssl", "ec", "-pubout", "-in", str(key_path), "-out", str(public_path)],
            capture_output=True,
            check=False,
        )
        if extracted.returncode != 0:
            raise SystemExit("Could not read the test public key.")
        signature = raw_to_der(b64url_decode(signature_text))
        signature_path = Path(directory) / "sig.der"
        signature_path.write_bytes(signature)
        verified = subprocess.run(
            [
                "openssl",
                "dgst",
                "-sha256",
                "-verify",
                str(public_path),
                "-signature",
                str(signature_path),
            ],
            input=f"{header_text}.{payload_text}".encode(),
            capture_output=True,
            check=False,
        )
        if verified.returncode != 0:
            raise SystemExit("JWT signature did not verify")


def pbxproj_roundtrip():
    fixture = """
\t\tbuildSettings = {
\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\tDEVELOPMENT_TEAM = EXAMPLETEAM;
\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.lojo.WatchRemote;
\t\t};
\t\tbuildSettings = {
\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.lojo.WatchRemote.tests;
\t\t};
\t\tbuildSettings = {
\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.lojo.WatchRemote.watchkitapp;
\t\t};
"""
    targets = (
        ("com.lojo.WatchRemote", "WatchRemote App Store"),
        ("com.lojo.WatchRemote.watchkitapp", "WatchRemoteWatch App Store"),
    )
    patched = patch_pbxproj(fixture, "EXAMPLETEAM", "/tmp/signing.keychain-db", targets, "Apple Distribution")
    if 'PRODUCT_BUNDLE_IDENTIFIER = com.lojo.WatchRemote;' not in patched:
        raise SystemExit("pbxproj lost the iOS bundle id")
    if patched.count("CODE_SIGN_STYLE = Manual;") != 2:
        raise SystemExit("pbxproj did not set manual signing on both apps")
    if 'PROVISIONING_PROFILE_SPECIFIER = "WatchRemote App Store";' not in patched:
        raise SystemExit("pbxproj missed the iOS profile name")
    if 'PROVISIONING_PROFILE_SPECIFIER = "WatchRemoteWatch App Store";' not in patched:
        raise SystemExit("pbxproj missed the watch profile name")
    if "com.lojo.WatchRemote.tests" not in patched or patched.count("CODE_SIGN_STYLE = Automatic;") != 1:
        raise SystemExit("pbxproj changed the test bundle")
    if "Apple Distribution" not in patched or "/tmp/signing.keychain-db" not in patched:
        raise SystemExit("pbxproj missed the distribution identity or keychain")


def export_roundtrip():
    targets = (
        ("com.lojo.WatchRemote", "WatchRemote App Store"),
        ("com.lojo.WatchRemote.watchkitapp", "WatchRemoteWatch App Store"),
    )
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "ExportOptions.plist"
        write_export_options(path, "EXAMPLETEAM", targets, "Apple Distribution")
        with path.open("rb") as handle:
            payload = plistlib.load(handle)
        if payload["method"] != "app-store-connect" or payload["signingStyle"] != "manual":
            raise SystemExit("export options were not manual app-store-connect")
        if payload["signingCertificate"] != "Apple Distribution":
            raise SystemExit("export options missed Apple Distribution")
        if payload["destination"] != "upload" or payload["manageAppVersionAndBuildNumber"] is not False:
            raise SystemExit("export options did not keep the build number or upload destination")
        profiles = payload["provisioningProfiles"]
        if profiles.get("com.lojo.WatchRemote") != "WatchRemote App Store":
            raise SystemExit("export options missed the iOS profile")
        if profiles.get("com.lojo.WatchRemote.watchkitapp") != "WatchRemoteWatch App Store":
            raise SystemExit("export options missed the watch profile")


def targets_roundtrip():
    text = Path(__file__).resolve().parents[1].joinpath("project.yml").read_text()
    found = distribution_targets(text)
    bundles = [bundle for bundle, _name in found]
    if bundles != ["com.lojo.WatchRemote", "com.lojo.WatchRemote.watchkitapp"]:
        raise SystemExit("signable targets changed: " + ", ".join(bundles))
    names = dict(found)
    if names["com.lojo.WatchRemote"] != "WatchRemote App Store":
        raise SystemExit("iOS profile name changed")
    if names["com.lojo.WatchRemote.watchkitapp"] != "WatchRemoteWatch App Store":
        raise SystemExit("watch profile name changed")
    extra = text.replace(
        "\nschemes:\n",
        "\n  Widget:\n    type: app-extension\n    settings:\n      base:\n"
        "        PRODUCT_BUNDLE_IDENTIFIER: com.lojo.WatchRemote.widget\nschemes:\n",
        1,
    )
    extra_bundles = [bundle for bundle, _name in distribution_targets(extra)]
    if "com.lojo.WatchRemote.widget" not in extra_bundles:
        raise SystemExit("an app extension was not signed")
    if any(bundle.endswith(".tests") or "uitests" in bundle for bundle in extra_bundles):
        raise SystemExit("a test bundle was signed")


def forbidden_roundtrip():
    held = sys.stderr
    captured = io.StringIO()
    sys.stderr = captured
    try:
        stop_api(
            403,
            '{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","detail":"The resource is not allowed."}]}',
            "profile",
        )
    except SystemExit as error:
        if error.code != 1:
            raise SystemExit("forbidden path did not stop")
    else:
        raise SystemExit("forbidden path did not stop")
    finally:
        sys.stderr = held
    text = captured.getvalue()
    if "FORBIDDEN_ERROR" not in text or "The resource is not allowed." not in text:
        raise SystemExit("forbidden path did not keep the API response")
    if "No distribution certificate was created or revoked" not in text:
        raise SystemExit("forbidden path did not say certificates were left alone")


def cleanup_roundtrip():
    calls = []
    real_api = globals()["api"]

    def fake_api(token, method, path, payload=None):
        calls.append((method, path))
        return 500, "cleanup must not call the API"

    with tempfile.TemporaryDirectory() as tmp:
        profile_file = Path(tmp) / "p.mobileprovision"
        profile_file.write_bytes(b"x")
        manifest = Path(tmp) / "m.json"
        write_manifest(
            manifest,
            CERTIFICATE_ID,
            [{"id": "PROF1", "name": "n", "bundleId": "b", "path": str(profile_file)}],
        )
        globals()["api"] = fake_api
        os.environ["SIGNING_MANIFEST"] = str(manifest)
        try:
            cleanup()
            if calls:
                raise SystemExit("cleanup called the API: " + repr(calls))
            if profile_file.exists():
                raise SystemExit("cleanup left the profile file behind")
        finally:
            globals()["api"] = real_api
            os.environ.pop("SIGNING_MANIFEST", None)


def profile_flow_roundtrip():
    """Reuse an active profile, replace an invalid one, and never touch certificates."""
    calls = []
    cert_der = b"shared-cert-der"

    def fake_api(token, method, path, payload=None):
        calls.append((method, path.split("?", 1)[0], payload))
        if method == "GET" and path.startswith("/v1/certificates/"):
            if path != "/v1/certificates/" + CERTIFICATE_ID:
                return 404, "wrong certificate"
            return 200, json.dumps(
                {
                    "data": {
                        "id": CERTIFICATE_ID,
                        "attributes": {
                            "certificateType": "IOS_DISTRIBUTION",
                            "certificateContent": base64.b64encode(cert_der).decode(),
                        },
                    }
                }
            )
        if method == "GET" and path.startswith("/v1/bundleIds?"):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(path).query)
            identifier = query["filter[identifier]"][0]
            return 200, json.dumps(
                {"data": [{"id": "BID-" + identifier, "attributes": {"identifier": identifier}}]}
            )
        if method == "GET" and path.startswith("/v1/profiles?"):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(path).query)
            name = query["filter[name]"][0]
            if name == "WatchRemote App Store":
                return 200, json.dumps(
                    {
                        "data": [
                            {
                                "id": "PROF-IOS",
                                "attributes": {
                                    "name": name,
                                    "profileType": "IOS_APP_STORE",
                                    "profileState": "ACTIVE",
                                    "profileContent": base64.b64encode(b"profile-ios").decode(),
                                    "expirationDate": "2099-01-01T00:00:00Z",
                                },
                                "relationships": {
                                    "bundleId": {
                                        "data": {"type": "bundleIds", "id": "BID-com.lojo.WatchRemote"}
                                    },
                                    "certificates": {
                                        "data": [{"type": "certificates", "id": CERTIFICATE_ID}]
                                    },
                                },
                            }
                        ]
                    }
                )
            return 200, json.dumps(
                {
                    "data": [
                        {
                            "id": "PROF-OLD",
                            "attributes": {
                                "name": name,
                                "profileType": "IOS_APP_STORE",
                                "profileState": "INVALID",
                                "expirationDate": "2099-01-01T00:00:00Z",
                            },
                            "relationships": {
                                "bundleId": {
                                    "data": {
                                        "type": "bundleIds",
                                        "id": "BID-com.lojo.WatchRemote.watchkitapp",
                                    }
                                },
                                "certificates": {
                                    "data": [{"type": "certificates", "id": "REVOKED"}]
                                },
                            },
                        }
                    ]
                }
            )
        if method == "GET" and path.startswith("/v1/profiles/PROF-OLD"):
            return 200, json.dumps(
                {
                    "data": {
                        "id": "PROF-OLD",
                        "attributes": {
                            "name": "WatchRemoteWatch App Store",
                            "profileType": "IOS_APP_STORE",
                            "profileState": "INVALID",
                        },
                        "relationships": {
                            "bundleId": {
                                "data": {
                                    "type": "bundleIds",
                                    "id": "BID-com.lojo.WatchRemote.watchkitapp",
                                }
                            },
                            "certificates": {"data": [{"type": "certificates", "id": "REVOKED"}]},
                        },
                    }
                }
            )
        if method == "DELETE" and path == "/v1/profiles/PROF-OLD":
            return 204, ""
        if method == "POST" and path == "/v1/profiles":
            certs = payload["data"]["relationships"]["certificates"]["data"]
            if certs != [{"type": "certificates", "id": CERTIFICATE_ID}]:
                return 400, "profile was not bound to the shared certificate"
            return 201, json.dumps(
                {
                    "data": {
                        "id": "PROF-WATCH",
                        "attributes": {
                            "profileContent": base64.b64encode(b"profile-watch").decode(),
                        },
                    }
                }
            )
        return 500, "unexpected " + method + " " + path

    real_api = globals()["api"]
    real_jwt = globals()["jwt_from_env"]
    globals()["api"] = fake_api
    try:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            project = root / "project.yml"
            project.write_text(Path(__file__).resolve().parents[1].joinpath("project.yml").read_text())
            pbx = root / "project.pbxproj"
            pbx.write_text(
                "buildSettings = {\n"
                "\tCODE_SIGN_STYLE = Automatic;\n"
                "\tPRODUCT_BUNDLE_IDENTIFIER = com.lojo.WatchRemote;\n"
                "};\n"
                "buildSettings = {\n"
                "\tCODE_SIGN_STYLE = Automatic;\n"
                "\tPRODUCT_BUNDLE_IDENTIFIER = com.lojo.WatchRemote.watchkitapp;\n"
                "};\n"
            )
            certificate = root / "cert.der"
            certificate.write_bytes(cert_der)
            os.environ["KEY_PATH"] = str(root / "missing.p8")
            globals()["jwt_from_env"] = lambda: "token"
            prepare(
                {
                    "identity": "Apple Distribution",
                    "certificate_der": str(certificate),
                    "manifest": str(root / "manifest.json"),
                    "profiles_dir": str(root / "profiles"),
                    "project_yml": str(project),
                    "team": "EXAMPLETEAM",
                    "keychain": "/tmp/signing.keychain-db",
                    "pbxproj": str(pbx),
                    "export_plist": str(root / "ExportOptions.plist"),
                }
            )
            methods = [(method, path) for method, path, _payload in calls]
            if ("POST", "/v1/certificates") in methods or any(
                method == "DELETE" and path.startswith("/v1/certificates") for method, path in methods
            ):
                raise SystemExit("profile flow created or revoked a certificate")
            if ("POST", "/v1/profiles") not in methods:
                raise SystemExit("profile flow did not create the missing watch profile")
            if methods.count(("POST", "/v1/profiles")) != 1:
                raise SystemExit("profile flow created more than the missing profile")
            if ("DELETE", "/v1/profiles/PROF-OLD") not in methods:
                raise SystemExit("profile flow left the invalid watch profile in place")
            if ("DELETE", "/v1/profiles/PROF-IOS") in methods:
                raise SystemExit("profile flow deleted the reusable iOS profile")
            patched = pbx.read_text()
            if patched.count("CODE_SIGN_STYLE = Manual;") != 2:
                raise SystemExit("profile flow did not set manual signing")
            ios_profile = root / "profiles" / "PROF-IOS.mobileprovision"
            watch_profile = root / "profiles" / "PROF-WATCH.mobileprovision"
            if ios_profile.read_bytes() != b"profile-ios" or watch_profile.read_bytes() != b"profile-watch":
                raise SystemExit("profile flow installed the wrong profile bytes")
            calls.clear()
            try:
                assert_same_certificate(b"other", fetch_certificate_der("token", CERTIFICATE_ID))
            except SystemExit as error:
                if "does not match" not in str(error):
                    raise
            else:
                raise SystemExit("a mismatched certificate was accepted")
            if any(method == "POST" for method, _path, _payload in calls):
                raise SystemExit("a mismatched certificate still created a profile")
    finally:
        globals()["api"] = real_api
        globals()["jwt_from_env"] = real_jwt
        os.environ.pop("KEY_PATH", None)


def no_certificate_minting():
    root = Path(__file__).resolve().parents[1]
    files = [
        root / "scripts/asc_signing.py",
        root / "scripts/archive-upload.sh",
        root / "scripts/import-dist-cert.sh",
        root / ".github/workflows/ios.yml",
        root / ".github/workflows/testflight-beta.yml",
    ]
    banned = (
        "allow" + "ProvisioningUpdates",
        "openssl " + "genrsa",
        "Watch Remote " + "Distribution",
        "fast" + "lane",
        "csr" + "Content",
        "CERTIFICATE " + "REQUEST",
    )
    for path in files:
        text = path.read_text()
        for phrase in banned:
            if phrase in text:
                raise SystemExit(f"{path.name} still contains {phrase}")
    signing = (root / "scripts/asc_signing.py").read_text()
    if re.search(r'api\(\s*token,\s*"POST",\s*"/v1/certificates"', signing):
        raise SystemExit("signing still posts certificates")
    if re.search(r'api\(\s*token,\s*"DELETE",\s*"/v1/certificates', signing):
        raise SystemExit("signing still deletes certificates")
    workflow = (root / ".github/workflows/ios.yml").read_text()
    if "DIST_CERT_P12" not in workflow or "DIST_CERT_PASSWORD" not in workflow:
        raise SystemExit("workflow does not import the shared certificate")
    if "import-dist-cert.sh --cleanup" not in workflow or "if: always()" not in workflow:
        raise SystemExit("workflow does not delete the keychain with if: always()")
    archive = (root / "scripts/archive-upload.sh").read_text()
    if "authenticationKeyPath" not in archive:
        raise SystemExit("upload no longer authenticates to App Store Connect")


def self_test():
    der_roundtrip()
    jwt_roundtrip()
    pbxproj_roundtrip()
    export_roundtrip()
    targets_roundtrip()
    forbidden_roundtrip()
    cleanup_roundtrip()
    profile_flow_roundtrip()
    no_certificate_minting()
    print("asc signing ok")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
        return
    if len(sys.argv) > 1 and sys.argv[1] == "cleanup":
        cleanup()
        return
    if len(sys.argv) > 1 and sys.argv[1] == "prepare":
        required = (
            "certificate_der",
            "manifest",
            "profiles_dir",
            "project_yml",
            "team",
            "keychain",
            "pbxproj",
            "export_plist",
            "identity",
        )
        values = {}
        args = sys.argv[2:]
        index = 0
        while index < len(args):
            name = args[index][2:].replace("-", "_")
            if index + 1 >= len(args):
                raise SystemExit("Missing a signing argument.")
            values[name] = args[index + 1]
            index += 2
        missing = [name for name in required if name not in values]
        if missing:
            raise SystemExit("Missing signing arguments.")
        prepare(values)
        return
    raise SystemExit("Usage: asc_signing.py --self-test | prepare | cleanup")


if __name__ == "__main__":
    main()
