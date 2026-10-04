#!/usr/bin/env python3
"""Create an iOS Distribution certificate and App Store profiles.

Uses the App Store Connect REST API (ES256 JWT, audience appstoreconnect-v1).
Does not print private keys, API tokens, or certificate passwords, and does not
revoke certificates.
"""

import base64
import io
import json
import os
import plistlib
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
TARGETS = (
    ("com.lojo.WatchRemote", "WatchRemote App Store"),
    ("com.lojo.WatchRemote.watchkitapp", "WatchRemoteWatch App Store"),
)
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


def certificate_limit(body):
    lowered = body.lower()
    phrases = (
        "maximum number",
        "already have",
        "too many",
        "certificate limit",
        "exceeded the maximum",
        "reached the maximum",
    )
    return any(phrase in lowered for phrase in phrases)


def stop_api(status, body, context):
    text = body.strip() or f"HTTP {status}"
    sys.stderr.write(text)
    if not text.endswith("\n"):
        sys.stderr.write("\n")
    forbidden = status == 403 or "FORBIDDEN" in body
    if forbidden and context == "certificate":
        sys.stderr.write(
            "Certificate creation was forbidden. Stopped without retrying. "
            "Nothing was revoked. An Admin App Store Connect API key may be required.\n"
        )
    elif forbidden:
        sys.stderr.write(
            f"{context} was forbidden. Stopped without retrying. Nothing was revoked.\n"
        )
    elif context == "certificate" and certificate_limit(body):
        sys.stderr.write(
            "The account is at the iOS Distribution certificate limit. "
            "Stopped. Nothing was revoked.\n"
        )
    else:
        sys.stderr.write(
            f"{context} failed with HTTP {status}. Stopped. Nothing was revoked.\n"
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
        raise SystemExit("Could not reach App Store Connect. Stopped. Nothing was revoked.")


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
        "Create that App ID first. Nothing was revoked.\n"
    )
    raise SystemExit(1)


def delete_named_profiles(token, name):
    query = urllib.parse.urlencode(
        {
            "filter[name]": name,
            "filter[profileType]": PROFILE_TYPE,
            "limit": "20",
        }
    )
    status, body = api(token, "GET", "/v1/profiles?" + query)
    parsed = parse_data(status, body, "profile lookup")
    for item in parsed["data"]:
        attributes = item.get("attributes", {})
        if attributes.get("name") != name or attributes.get("profileType") != PROFILE_TYPE:
            continue
        delete_profile(token, item["id"])


def delete_profile(token, profile_id):
    status, body = api(token, "DELETE", "/v1/profiles/" + urllib.parse.quote(profile_id))
    if status in (204, 404):
        return
    stop_api(status, body, "profile delete")


def create_certificate(token, csr_text):
    status, body = api(
        token,
        "POST",
        "/v1/certificates",
        {
            "data": {
                "type": "certificates",
                "attributes": {
                    "certificateType": CERTIFICATE_TYPE,
                    "csrContent": csr_text,
                },
            }
        },
    )
    parsed = parse_data(status, body, "certificate")
    attributes = parsed["data"].get("attributes", {})
    content = attributes.get("certificateContent")
    if not content:
        stop_api(status, body, "certificate")
    return parsed["data"]["id"], base64.b64decode(content)


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


def bundle_in_block(text, bundle_id):
    return (
        f"PRODUCT_BUNDLE_IDENTIFIER = {bundle_id};" in text
        or f'PRODUCT_BUNDLE_IDENTIFIER = "{bundle_id}";' in text
    )


def patch_pbxproj(text, team, keychain, profiles):
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
        output.extend(rewrite_settings(block, team, keychain, matched))
    return "".join(output)


def rewrite_settings(block, team, keychain, profile_name):
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
        f'{indent}CODE_SIGN_IDENTITY = "Apple Distribution";\n',
        f"{indent}DEVELOPMENT_TEAM = {team};\n",
        f'{indent}PROVISIONING_PROFILE_SPECIFIER = "{profile_name}";\n',
        f'{indent}OTHER_CODE_SIGN_FLAGS = "{flag}";\n',
    ]
    kept.extend(settings)
    kept.append(block[-1])
    return kept


def write_export_options(path, team, profiles):
    payload = {
        "method": "app-store-connect",
        "signingStyle": "manual",
        "signingCertificate": "Apple Distribution",
        "teamID": team,
        "destination": "upload",
        "uploadSymbols": True,
        "manageAppVersionAndBuildNumber": False,
        "provisioningProfiles": {bundle_id: name for bundle_id, name in profiles},
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        plistlib.dump(payload, handle)


def write_manifest(path, certificate_id, certificate_path, profiles):
    payload = {
        "certificateId": certificate_id,
        "certificatePath": str(certificate_path),
        "profiles": profiles,
    }
    Path(path).write_text(json.dumps(payload))
    os.chmod(path, 0o600)


def prepare(argv):
    certificate_out = Path(argv["certificate_out"])
    manifest_path = Path(argv["manifest"])
    profiles_dir = Path(argv["profiles_dir"]).expanduser()
    csr_text = Path(argv["csr"]).read_text()
    if "-----BEGIN CERTIFICATE REQUEST-----" not in csr_text:
        raise SystemExit("The distribution CSR was not produced.")
    print("Creating a new iOS Distribution certificate.", flush=True)
    token = jwt_from_env()
    certificate_id, certificate_der = create_certificate(token, csr_text)
    certificate_out.write_bytes(certificate_der)
    os.chmod(certificate_out, 0o600)
    print("Created a new iOS Distribution certificate. Existing certificates were not revoked.", flush=True)
    installed = []
    try:
        for bundle_id, profile_name in TARGETS:
            print(f"Installing an App Store profile for {bundle_id}.", flush=True)
            resource_id = find_bundle_id(token, bundle_id)
            delete_named_profiles(token, profile_name)
            profile_id, raw = create_profile(token, profile_name, resource_id, certificate_id)
            path = install_profile(raw, profile_id, profiles_dir)
            installed.append(
                {
                    "id": profile_id,
                    "name": profile_name,
                    "bundleId": bundle_id,
                    "path": str(path),
                }
            )
            write_manifest(manifest_path, certificate_id, certificate_out, installed)
    except SystemExit:
        write_manifest(manifest_path, certificate_id, certificate_out, installed)
        raise
    project = Path(argv["pbxproj"])
    patched = patch_pbxproj(project.read_text(), argv["team"], argv["keychain"], TARGETS)
    if patched.count('CODE_SIGN_STYLE = Manual;') < 2:
        raise SystemExit("Could not set manual signing on both app targets. Nothing was revoked.")
    if "Apple Distribution" not in patched:
        raise SystemExit("Could not set the Apple Distribution identity. Nothing was revoked.")
    project.write_text(patched)
    write_export_options(Path(argv["export_plist"]), argv["team"], TARGETS)
    write_manifest(manifest_path, certificate_id, certificate_out, installed)


def delete_profiles():
    manifest_path = Path(os.environ["SIGNING_MANIFEST"])
    if not manifest_path.is_file():
        return
    manifest = json.loads(manifest_path.read_text())
    token = jwt_from_env()
    for profile in manifest.get("profiles", []):
        profile_id = profile.get("id")
        if profile_id:
            status, body = api(token, "DELETE", "/v1/profiles/" + urllib.parse.quote(profile_id))
            if status not in (204, 404):
                text = body.strip() or f"HTTP {status}"
                sys.stderr.write(text + "\n")
                sys.stderr.write(
                    "Could not delete an App Store profile. Nothing was revoked.\n"
                )
        path = profile.get("path")
        if path:
            Path(path).unlink(missing_ok=True)


def self_test():
    der_roundtrip()
    jwt_roundtrip()
    pbxproj_roundtrip()
    export_roundtrip()
    forbidden_roundtrip()
    print("asc signing ok")


def der_roundtrip():
    raw = bytes(range(32)) + bytes(range(32, 64))
    # Make the high bit set so the DER form needs a leading zero.
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
    patched = patch_pbxproj(fixture, "EXAMPLETEAM", "/tmp/signing.keychain-db", TARGETS)
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
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "ExportOptions.plist"
        write_export_options(path, "EXAMPLETEAM", TARGETS)
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


def forbidden_roundtrip():
    held = sys.stderr
    captured = io.StringIO()
    sys.stderr = captured
    try:
        stop_api(
            403,
            '{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","detail":"The resource is not allowed."}]}',
            "certificate",
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
    if "Nothing was revoked" not in text or "Admin" not in text:
        raise SystemExit("forbidden path did not say to stop")
    limit = io.StringIO()
    sys.stderr = limit
    try:
        stop_api(
            409,
            "You have already reached the maximum number of certificates of this type.",
            "certificate",
        )
    except SystemExit:
        pass
    finally:
        sys.stderr = held
    if "Nothing was revoked" not in limit.getvalue() or "certificate limit" not in limit.getvalue():
        raise SystemExit("certificate limit was not reported clearly")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
        return
    if len(sys.argv) > 1 and sys.argv[1] == "delete-profiles":
        delete_profiles()
        return
    if len(sys.argv) > 1 and sys.argv[1] == "prepare":
        required = (
            "certificate_out",
            "manifest",
            "profiles_dir",
            "csr",
            "team",
            "keychain",
            "pbxproj",
            "export_plist",
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
    raise SystemExit("Usage: asc_signing.py --self-test | prepare | delete-profiles")


if __name__ == "__main__":
    main()
