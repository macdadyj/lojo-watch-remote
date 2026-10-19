#!/usr/bin/env python3
"""Install App Store profiles for the shared iOS Distribution certificate.

Uses the App Store Connect REST API (ES256 JWT, audience appstoreconnect-v1).
Does not create, renew, or delete certificates. Profiles are fetched when they
are already tied to the shared certificate, and created for that certificate
only when a target has none. Does not print private keys, API tokens, or
certificate passwords.
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
from datetime import datetime, timezone
from pathlib import Path

API_ROOT = "https://api.appstoreconnect.apple.com"
PROFILE_TYPE = "IOS_APP_STORE"
CERTIFICATE_TYPE = "IOS_DISTRIBUTION"
SHARED_CERTIFICATE_ID = "VJ5MXTN7UT"
PRIMARY_BUNDLE_ID = "com.lojo.WatchRemote"
DISTRIBUTION_PRODUCT_TYPES = (
    "com.apple.product-type.application",
    "com.apple.product-type.app-extension",
    "com.apple.product-type.extensionkit-extension",
    "com.apple.product-type.watchkit2-extension",
    "com.apple.product-type.application.watchapp",
    "com.apple.product-type.application.watchapp2",
    "com.apple.product-type.application.on-demand-install-capable",
)
SIGNING_KEYS = (
    "CODE_SIGN_STYLE",
    "CODE_SIGN_IDENTITY",
    "DEVELOPMENT_TEAM",
    "PROVISIONING_PROFILE",
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
    sys.stderr.write(f"{context} failed with HTTP {status}.\n")
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
        raise SystemExit("Could not reach App Store Connect.")


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


def pem_certificates(path):
    text = Path(path).read_text()
    certificates = []
    for match in re.finditer(
        r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----",
        text,
        re.S,
    ):
        certificates.append(base64.b64decode("".join(match.group(1).split())))
    if not certificates:
        raise SystemExit("The imported distribution certificate could not be read.")
    return certificates


def signing_identity(cert_der):
    inspected = subprocess.run(
        ["openssl", "x509", "-inform", "DER", "-noout", "-subject"],
        input=cert_der,
        capture_output=True,
        check=False,
    )
    if inspected.returncode != 0:
        raise SystemExit("The shared distribution certificate could not be read.")
    subject = inspected.stdout.decode()
    if "iPhone Distribution" in subject:
        return "iPhone Distribution"
    return "Apple Distribution"


def assert_certificate_usable(attributes):
    if attributes.get("certificateType") != CERTIFICATE_TYPE:
        raise SystemExit("The shared certificate is not an iOS Distribution certificate.")
    text = attributes.get("expirationDate") or ""
    if not text:
        return
    cleaned = text.replace("Z", "+00:00")
    try:
        expires = datetime.fromisoformat(cleaned)
    except ValueError:
        return
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=timezone.utc)
    if expires <= datetime.now(timezone.utc):
        raise SystemExit("The shared iOS Distribution certificate is expired.")


def fetch_shared_certificate(token):
    status, body = api(
        token,
        "GET",
        "/v1/certificates/" + urllib.parse.quote(SHARED_CERTIFICATE_ID),
    )
    if status == 404:
        raise SystemExit(
            "The shared iOS Distribution certificate is missing from App Store Connect."
        )
    parsed = parse_data(status, body, "certificate lookup")
    attributes = parsed["data"].get("attributes") or {}
    assert_certificate_usable(attributes)
    content = attributes.get("certificateContent")
    if not content:
        stop_api(status, body, "certificate lookup")
    return base64.b64decode(content)


def matching_installed_certificate(installed_certs, remote_der):
    matches = [cert for cert in installed_certs if cert == remote_der]
    if len(matches) != 1:
        raise SystemExit(
            "The imported .p12 does not contain the shared iOS Distribution certificate."
        )
    return matches[0]


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
        f"No App Store Connect bundle ID for {identifier}. Create that App ID first.\n"
    )
    raise SystemExit(1)


def list_profiles(token):
    items = []
    query = urllib.parse.urlencode(
        {
            "filter[profileType]": PROFILE_TYPE,
            "include": "bundleId,certificates",
            "limit": "200",
        }
    )
    path = "/v1/profiles?" + query
    for _page in range(20):
        status, body = api(token, "GET", path)
        parsed = parse_data(status, body, "profile lookup")
        items.extend(parsed.get("data") or [])
        next_link = ((parsed.get("links") or {}).get("next")) or ""
        if next_link.startswith(API_ROOT):
            path = next_link[len(API_ROOT):]
            continue
        break
    return items


def profile_bundle_resource(item):
    relationship = ((item.get("relationships") or {}).get("bundleId") or {}).get("data") or {}
    return relationship.get("id")


def profile_certificate_ids(token, item):
    relationship = ((item.get("relationships") or {}).get("certificates") or {}).get("data") or []
    identifiers = [entry.get("id") for entry in relationship if entry.get("id")]
    if identifiers:
        return identifiers
    status, body = api(
        token,
        "GET",
        "/v1/profiles/" + urllib.parse.quote(item["id"]) + "/relationships/certificates",
    )
    parsed = parse_data(status, body, "profile certificates")
    return [entry.get("id") for entry in parsed.get("data") or [] if entry.get("id")]


def profile_bytes(token, item):
    content = (item.get("attributes") or {}).get("profileContent")
    if content:
        return base64.b64decode(content)
    status, body = api(token, "GET", "/v1/profiles/" + urllib.parse.quote(item["id"]))
    parsed = parse_data(status, body, "profile")
    content = (parsed["data"].get("attributes") or {}).get("profileContent")
    if not content:
        stop_api(status, body, "profile")
    return base64.b64decode(content)


def decode_profile(raw):
    with tempfile.NamedTemporaryFile() as handle:
        handle.write(raw)
        handle.flush()
        decoded = subprocess.run(
            [
                "openssl",
                "cms",
                "-inform",
                "DER",
                "-verify",
                "-noverify",
                "-in",
                handle.name,
            ],
            capture_output=True,
            check=False,
        )
    if not decoded.stdout:
        raise SystemExit("Could not read the provisioning profile.")
    try:
        return plistlib.loads(decoded.stdout)
    except Exception:
        raise SystemExit("Could not read the provisioning profile.")


def application_identifier_matches(app_id, bundle_id):
    team, separator, rest = str(app_id).partition(".")
    if not separator:
        return app_id == bundle_id
    return rest == bundle_id and team.isalnum()


def profile_matches(raw, bundle_id, cert_der):
    payload = decode_profile(raw)
    entitlements = payload.get("Entitlements") or {}
    app_id = entitlements.get("application-identifier") or ""
    if not application_identifier_matches(app_id, bundle_id):
        return False
    certificates = []
    for item in payload.get("DeveloperCertificates") or []:
        certificates.append(item if isinstance(item, bytes) else bytes(item))
    if cert_der not in certificates:
        return False
    return payload


def profile_name_for(bundle_id):
    known = {
        "com.lojo.WatchRemote": "WatchRemote App Store",
        "com.lojo.WatchRemote.watchkitapp": "WatchRemoteWatch App Store",
    }
    if bundle_id in known:
        return known[bundle_id]
    leaf = bundle_id.rsplit(".", 1)[-1]
    return f"Watch Remote {leaf} App Store"[:255]


def delete_profile(token, profile_id):
    status, body = api(token, "DELETE", "/v1/profiles/" + urllib.parse.quote(profile_id))
    if status in (204, 404):
        return
    stop_api(status, body, "profile delete")


def create_profile(token, name, bundle_resource_id):
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
                        "data": [
                            {"type": "certificates", "id": SHARED_CERTIFICATE_ID}
                        ]
                    },
                },
            }
        },
    )
    if status == 409:
        return None
    parsed = parse_data(status, body, "profile")
    content = (parsed["data"].get("attributes") or {}).get("profileContent")
    if not content:
        stop_api(status, body, "profile")
    return parsed["data"]["id"], base64.b64decode(content), parsed["data"]


def install_profile(raw, payload, directory):
    directory.mkdir(parents=True, exist_ok=True)
    filename = payload.get("UUID") or payload.get("Name") or "profile"
    path = directory / f"{filename}.mobileprovision"
    path.write_bytes(raw)
    os.chmod(path, 0o644)
    return path


def profiles_for_bundle(items, resource_id):
    matched = []
    for item in items:
        if (item.get("attributes") or {}).get("profileType") not in (None, PROFILE_TYPE):
            continue
        if profile_bundle_resource(item) == resource_id:
            matched.append(item)
    return matched


def choose_profile(items, token, cert_der, bundle_id, preferred_name):
    usable = []
    for item in items:
        attributes = item.get("attributes") or {}
        if attributes.get("profileState") not in (None, "ACTIVE"):
            continue
        if SHARED_CERTIFICATE_ID not in profile_certificate_ids(token, item):
            continue
        raw = profile_bytes(token, item)
        payload = profile_matches(raw, bundle_id, cert_der)
        if not payload:
            continue
        usable.append((item, raw, payload))
    if not usable:
        return None
    preferred = [
        entry for entry in usable
        if (entry[0].get("attributes") or {}).get("name") == preferred_name
    ]
    pool = preferred or usable

    def expiry(entry):
        return (entry[0].get("attributes") or {}).get("expirationDate") or ""

    pool.sort(key=expiry, reverse=True)
    return pool[0]


def delete_stale_named_profiles(token, items, preferred_name):
    for item in items:
        attributes = item.get("attributes") or {}
        if attributes.get("name") != preferred_name:
            continue
        if (
            attributes.get("profileState") in (None, "ACTIVE")
            and SHARED_CERTIFICATE_ID in profile_certificate_ids(token, item)
        ):
            continue
        delete_profile(token, item["id"])


def ensure_profile(token, bundle_id, resource_id, cert_der, profiles_dir):
    preferred_name = profile_name_for(bundle_id)
    items = profiles_for_bundle(list_profiles(token), resource_id)
    chosen = choose_profile(items, token, cert_der, bundle_id, preferred_name)
    if chosen is not None:
        _item, raw, payload = chosen
        print(f"Using the App Store profile for {bundle_id}.", flush=True)
        return install_record(raw, payload, bundle_id, profiles_dir)
    print(f"Creating an App Store profile for {bundle_id}.", flush=True)
    delete_stale_named_profiles(token, items, preferred_name)
    created = create_profile(token, preferred_name, resource_id)
    if created is None:
        items = profiles_for_bundle(list_profiles(token), resource_id)
        chosen = choose_profile(items, token, cert_der, bundle_id, preferred_name)
        if chosen is None:
            raise SystemExit(f"Could not install an App Store profile for {bundle_id}.")
        _item, raw, payload = chosen
        print(f"Using the App Store profile for {bundle_id}.", flush=True)
        return install_record(raw, payload, bundle_id, profiles_dir)
    _profile_id, raw, _data = created
    payload = profile_matches(raw, bundle_id, cert_der)
    if not payload:
        raise SystemExit(
            f"The App Store profile for {bundle_id} is not tied to the shared certificate."
        )
    return install_record(raw, payload, bundle_id, profiles_dir)


def install_record(raw, payload, bundle_id, profiles_dir):
    path = install_profile(raw, payload, profiles_dir)
    name = payload.get("Name") or profile_name_for(bundle_id)
    return {
        "id": payload.get("UUID") or name,
        "name": name,
        "bundleId": bundle_id,
        "path": str(path),
    }


def pbx_objects(text):
    objects = {}
    needle = " = {"
    index = 0
    while True:
        found = text.find(needle, index)
        if found < 0:
            break
        line_start = text.rfind("\n", 0, found) + 1
        header = text[line_start:found]
        body_start = found + len(needle)
        depth = 1
        cursor = body_start
        while cursor < len(text) and depth:
            char = text[cursor]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
            cursor += 1
        match = re.search(r"([A-Za-z0-9]+)\s*/\*", header)
        if match is None:
            index = body_start
            continue
        objects[match.group(1)] = text[body_start:cursor - 1]
        index = cursor
    return objects


def distribution_bundle_ids(text):
    objects = pbx_objects(text)
    bundle_ids = []
    for body in objects.values():
        if "isa = PBXNativeTarget;" not in body:
            continue
        product = re.search(r'productType = "([^"]+)";', body)
        if product is None or product.group(1) not in DISTRIBUTION_PRODUCT_TYPES:
            continue
        config_list = re.search(r"buildConfigurationList = ([A-Za-z0-9]+)", body)
        if config_list is None:
            continue
        list_body = objects.get(config_list.group(1), "")
        for config_id in re.findall(r"([A-Za-z0-9]+) /\*", list_body):
            config_body = objects.get(config_id, "")
            bundle = re.search(
                r'PRODUCT_BUNDLE_IDENTIFIER = "?([^";]+)"?;',
                config_body,
            )
            if bundle is None:
                continue
            identifier = bundle.group(1).strip()
            if identifier not in bundle_ids:
                bundle_ids.append(identifier)
    return bundle_ids


def bundle_in_block(text, bundle_id):
    return (
        f"PRODUCT_BUNDLE_IDENTIFIER = {bundle_id};" in text
        or f'PRODUCT_BUNDLE_IDENTIFIER = "{bundle_id}";' in text
    )


def patch_pbxproj(text, team, keychain, profiles, identity="Apple Distribution"):
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


def write_export_options(path, team, profiles, identity="Apple Distribution"):
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


def write_manifest(path, profiles):
    payload = {
        "certificateId": SHARED_CERTIFICATE_ID,
        "profiles": profiles,
    }
    Path(path).write_text(json.dumps(payload))
    os.chmod(path, 0o600)


def prepare(argv):
    installed = pem_certificates(argv["installed_pem"])
    token = jwt_from_env()
    remote = fetch_shared_certificate(token)
    certificate = matching_installed_certificate(installed, remote)
    identity = signing_identity(certificate)
    print("Using the shared iOS Distribution certificate.", flush=True)
    project = Path(argv["pbxproj"])
    project_text = project.read_text()
    bundle_ids = distribution_bundle_ids(project_text)
    if not bundle_ids:
        raise SystemExit("No distributable targets were found in the Xcode project.")
    profiles_dir = Path(argv["profiles_dir"]).expanduser()
    manifest_path = Path(argv["manifest"])
    installed_profiles = []
    try:
        for bundle_id in bundle_ids:
            resource_id = find_bundle_id(token, bundle_id)
            record = ensure_profile(
                token, bundle_id, resource_id, certificate, profiles_dir
            )
            installed_profiles.append(record)
            write_manifest(manifest_path, installed_profiles)
    except SystemExit:
        write_manifest(manifest_path, installed_profiles)
        raise
    pairs = [(record["bundleId"], record["name"]) for record in installed_profiles]
    patched = patch_pbxproj(project_text, argv["team"], argv["keychain"], pairs, identity)
    for bundle_id, profile_name in pairs:
        if f'PROVISIONING_PROFILE_SPECIFIER = "{profile_name}";' not in patched:
            raise SystemExit(f"Could not set manual signing for {bundle_id}.")
    if patched.count("CODE_SIGN_STYLE = Manual;") < len(pairs):
        raise SystemExit("Could not set manual signing on every distributable target.")
    if f'CODE_SIGN_IDENTITY = "{identity}";' not in patched:
        raise SystemExit("Could not set the distribution signing identity.")
    project.write_text(patched)
    write_export_options(Path(argv["export_plist"]), argv["team"], pairs, identity)
    write_manifest(manifest_path, installed_profiles)
    print(
        "Manual signing is set for " + ", ".join(bundle_ids) + ".",
        flush=True,
    )


def cleanup():
    """Remove local profile files recorded for this run.

    Shared App Store profiles and the distribution certificate stay in
    App Store Connect so the next run can reuse them.
    """
    manifest_path = Path(os.environ["SIGNING_MANIFEST"])
    if not manifest_path.is_file():
        return
    manifest = json.loads(manifest_path.read_text())
    for profile in manifest.get("profiles", []):
        path = profile.get("path")
        if path:
            Path(path).unlink(missing_ok=True)


def self_test():
    der_roundtrip()
    jwt_roundtrip()
    discovery_roundtrip()
    pbxproj_roundtrip()
    export_roundtrip()
    profile_match_roundtrip()
    forbidden_roundtrip()
    cleanup_roundtrip()
    prepare_roundtrip()
    print("asc signing ok")


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


PROJECT_FIXTURE = """
{
	objects = {
		APP /* WatchRemote */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = APPLIST /* Build configuration list for PBXNativeTarget "WatchRemote" */;
			productType = "com.apple.product-type.application";
		};
		EXT /* Widget */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = EXTLIST /* Build configuration list for PBXNativeTarget "Widget" */;
			productType = "com.apple.product-type.app-extension";
		};
		TESTS /* WatchRemoteTests */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = TESTLIST /* Build configuration list for PBXNativeTarget "WatchRemoteTests" */;
			productType = "com.apple.product-type.bundle.unit-test";
		};
		UITESTS /* WatchRemoteUITests */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = UITESTLIST /* Build configuration list for PBXNativeTarget "WatchRemoteUITests" */;
			productType = "com.apple.product-type.bundle.ui-testing";
		};
		APPLIST /* Build configuration list for PBXNativeTarget "WatchRemote" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				APPDEBUG /* Debug */,
				APPREL /* Release */,
			);
			defaultConfigurationName = Release;
		};
		EXTLIST /* Build configuration list for PBXNativeTarget "Widget" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				EXTREL /* Release */,
			);
		};
		TESTLIST /* Build configuration list for PBXNativeTarget "WatchRemoteTests" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				TESTDEBUG /* Debug */,
			);
		};
		UITESTLIST /* Build configuration list for PBXNativeTarget "WatchRemoteUITests" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				UITESTDEBUG /* Debug */,
			);
		};
		APPDEBUG /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				PRODUCT_BUNDLE_IDENTIFIER = com.lojo.WatchRemote;
			};
			name = Debug;
		};
		APPREL /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				PRODUCT_BUNDLE_IDENTIFIER = com.lojo.WatchRemote;
			};
			name = Release;
		};
		EXTREL /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				PRODUCT_BUNDLE_IDENTIFIER = com.lojo.WatchRemote.widget;
			};
			name = Release;
		};
		TESTDEBUG /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				PRODUCT_BUNDLE_IDENTIFIER = com.lojo.WatchRemote.tests;
			};
			name = Debug;
		};
		UITESTDEBUG /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				PRODUCT_BUNDLE_IDENTIFIER = com.lojo.WatchRemote.uitests;
			};
			name = Debug;
		};
	};
}
"""


def discovery_roundtrip():
    found = distribution_bundle_ids(PROJECT_FIXTURE)
    if found != ["com.lojo.WatchRemote", "com.lojo.WatchRemote.widget"]:
        raise SystemExit("distribution targets were not discovered: " + repr(found))


def pbxproj_roundtrip():
    profiles = (
        ("com.lojo.WatchRemote", "WatchRemote App Store"),
        ("com.lojo.WatchRemote.widget", "Watch Remote widget App Store"),
    )
    patched = patch_pbxproj(PROJECT_FIXTURE, "EXAMPLETEAM", "/tmp/signing.keychain-db", profiles)
    if patched.count("CODE_SIGN_STYLE = Manual;") != 3:
        raise SystemExit("pbxproj did not set manual signing on every distributable target")
    if 'PROVISIONING_PROFILE_SPECIFIER = "WatchRemote App Store";' not in patched:
        raise SystemExit("pbxproj missed the app profile name")
    if patched.count('PROVISIONING_PROFILE_SPECIFIER = "WatchRemote App Store";') != 2:
        raise SystemExit("pbxproj missed a build configuration for the app")
    if 'PROVISIONING_PROFILE_SPECIFIER = "Watch Remote widget App Store";' not in patched:
        raise SystemExit("pbxproj missed the extension profile name")
    if "com.lojo.WatchRemote.tests" not in patched or "com.lojo.WatchRemote.uitests" not in patched:
        raise SystemExit("pbxproj dropped a test bundle")
    if patched.count("CODE_SIGN_STYLE = Automatic;") != 2:
        raise SystemExit("pbxproj changed a test target")
    if "Apple Distribution" not in patched or "/tmp/signing.keychain-db" not in patched:
        raise SystemExit("pbxproj missed the distribution identity or keychain")


def export_roundtrip():
    profiles = (
        ("com.lojo.WatchRemote", "WatchRemote App Store"),
        ("com.lojo.WatchRemote.widget", "Watch Remote widget App Store"),
    )
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "ExportOptions.plist"
        write_export_options(path, "EXAMPLETEAM", profiles)
        with path.open("rb") as handle:
            payload = plistlib.load(handle)
        if payload["method"] != "app-store-connect" or payload["signingStyle"] != "manual":
            raise SystemExit("export options were not manual app-store-connect")
        if payload["signingCertificate"] != "Apple Distribution":
            raise SystemExit("export options missed Apple Distribution")
        if payload["destination"] != "upload" or payload["manageAppVersionAndBuildNumber"] is not False:
            raise SystemExit("export options did not keep the build number or upload destination")
        stored = payload["provisioningProfiles"]
        if stored.get("com.lojo.WatchRemote") != "WatchRemote App Store":
            raise SystemExit("export options missed the app profile")
        if stored.get("com.lojo.WatchRemote.widget") != "Watch Remote widget App Store":
            raise SystemExit("export options missed the extension profile")
        if len(stored) != 2:
            raise SystemExit("export options should name every distributable target")


def sign_profile(bundle_id, cert_der, name):
    payload = {
        "Name": name,
        "UUID": "UUID-" + bundle_id.replace(".", "-"),
        "Entitlements": {"application-identifier": "TEAMID1234." + bundle_id},
        "DeveloperCertificates": [cert_der],
    }
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        key = directory / "key.pem"
        cert = directory / "cert.pem"
        plist = directory / "payload.plist"
        profile = directory / "profile.mobileprovision"
        created = subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "rsa:2048",
                "-keyout", str(key), "-out", str(cert), "-days", "1",
                "-nodes", "-subj", "/CN=Test",
            ],
            capture_output=True,
            check=False,
        )
        if created.returncode != 0:
            raise SystemExit("Could not build a test profile signer.")
        with plist.open("wb") as handle:
            plistlib.dump(payload, handle)
        signed = subprocess.run(
            [
                "openssl", "cms", "-sign", "-nodetach", "-binary",
                "-signer", str(cert), "-inkey", str(key),
                "-in", str(plist), "-outform", "DER", "-out", str(profile),
            ],
            capture_output=True,
            check=False,
        )
        if signed.returncode != 0:
            raise SystemExit("Could not sign a test profile.")
        return profile.read_bytes()


def profile_match_roundtrip():
    cert_der = b"\x30\x03\x01\x01\x00"
    raw = sign_profile(PRIMARY_BUNDLE_ID, cert_der, "WatchRemote App Store")
    payload = profile_matches(raw, PRIMARY_BUNDLE_ID, cert_der)
    if not payload or payload.get("Name") != "WatchRemote App Store":
        raise SystemExit("profile did not match the shared certificate")
    other = sign_profile("com.lojo.WatchRemote.widget", b"\x30\x01\xff", "Other")
    if profile_matches(other, "com.lojo.WatchRemote.widget", cert_der):
        raise SystemExit("profile matched a different certificate")
    if profile_matches(raw, "com.lojo.WatchRemote.widget", cert_der):
        raise SystemExit("app profile matched the extension bundle id")
    if not application_identifier_matches("TEAMID1234.com.lojo.WatchRemote", PRIMARY_BUNDLE_ID):
        raise SystemExit("application identifier should match the app")
    if application_identifier_matches("TEAMID1234.com.lojo.WatchRemote.widget", PRIMARY_BUNDLE_ID):
        raise SystemExit("application identifier matched a shorter bundle id")


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
        if error.code not in (1, None):
            raise SystemExit("forbidden path did not stop")
    else:
        raise SystemExit("forbidden path did not stop")
    finally:
        sys.stderr = held
    text = captured.getvalue()
    if "FORBIDDEN_ERROR" not in text or "profile failed with HTTP 403" not in text:
        raise SystemExit("forbidden path did not keep the API response")
    if "certificate" in text.lower() and "creat" in text.lower():
        raise SystemExit("forbidden path talked about creating a certificate")


def cleanup_roundtrip():
    calls = []
    real_api = globals()["api"]

    def fake_api(token, method, path, payload=None):
        calls.append((method, path))
        raise SystemExit("cleanup called the App Store Connect API")

    with tempfile.TemporaryDirectory() as tmp:
        profile_file = Path(tmp) / "p.mobileprovision"
        profile_file.write_bytes(b"x")
        manifest = Path(tmp) / "m.json"
        write_manifest(
            manifest,
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
            stored = json.loads(manifest.read_text())
            if stored.get("certificateId") != SHARED_CERTIFICATE_ID:
                raise SystemExit("manifest lost the shared certificate id")
        finally:
            globals()["api"] = real_api
            os.environ.pop("SIGNING_MANIFEST", None)


def certificate_body(cert_der):
    return json.dumps({
        "data": {
            "type": "certificates",
            "id": SHARED_CERTIFICATE_ID,
            "attributes": {
                "certificateType": CERTIFICATE_TYPE,
                "expirationDate": "2099-01-01T00:00:00.000+00:00",
                "certificateContent": base64.b64encode(cert_der).decode(),
            },
        }
    })


def sample_certificate():
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        created = subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "rsa:2048",
                "-keyout", str(directory / "key.pem"),
                "-out", str(directory / "cert.pem"),
                "-days", "1", "-nodes",
                "-subj", "/CN=Apple Distribution: Test (TEAMID1234)",
            ],
            capture_output=True,
            check=False,
        )
        if created.returncode != 0:
            raise SystemExit("Could not build a test certificate.")
        exported = subprocess.run(
            ["openssl", "x509", "-in", str(directory / "cert.pem"), "-outform", "DER"],
            capture_output=True,
            check=False,
        )
        if exported.returncode != 0 or not exported.stdout:
            raise SystemExit("Could not export a test certificate.")
        return exported.stdout


def prepare_roundtrip():
    cert_der = sample_certificate()
    calls = []
    profiles = []

    def fake_api(token, method, path, payload=None):
        calls.append((method, path.split("?", 1)[0]))
        if method == "POST" and path.split("?", 1)[0] == "/v1/certificates":
            raise SystemExit("prepare created a certificate")
        if method == "DELETE" and "/v1/certificates/" in path:
            raise SystemExit("prepare deleted a certificate")
        if method == "GET" and path.startswith("/v1/certificates/"):
            if not path.endswith("/" + SHARED_CERTIFICATE_ID):
                raise SystemExit("prepare looked up a different certificate")
            return 200, certificate_body(cert_der)
        if method == "GET" and path.startswith("/v1/bundleIds"):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(path).query)
            identifier = query["filter[identifier]"][0]
            resource = "BID-APP" if identifier == PRIMARY_BUNDLE_ID else "BID-WIDGET"
            return 200, json.dumps({
                "data": [{
                    "type": "bundleIds",
                    "id": resource,
                    "attributes": {"identifier": identifier},
                }]
            })
        if method == "GET" and path.startswith("/v1/profiles"):
            return 200, json.dumps({"data": list(profiles)})
        if method == "POST" and path == "/v1/profiles":
            relationships = payload["data"]["relationships"]
            certificates = relationships["certificates"]["data"]
            if certificates != [{"type": "certificates", "id": SHARED_CERTIFICATE_ID}]:
                raise SystemExit("profile was not tied to the shared certificate")
            resource = relationships["bundleId"]["data"]["id"]
            bundle_id = PRIMARY_BUNDLE_ID if resource == "BID-APP" else "com.lojo.WatchRemote.widget"
            name = payload["data"]["attributes"]["name"]
            raw = sign_profile(bundle_id, cert_der, name)
            return 201, json.dumps({
                "data": {
                    "type": "profiles",
                    "id": "PROF-" + resource,
                    "attributes": {
                        "name": name,
                        "profileType": PROFILE_TYPE,
                        "profileState": "ACTIVE",
                        "profileContent": base64.b64encode(raw).decode(),
                    },
                }
            })
        if method == "DELETE" and path.startswith("/v1/profiles/"):
            return 204, ""
        return 404, "{}"

    real_api, real_jwt = globals()["api"], globals()["jwt_from_env"]
    globals()["api"] = fake_api
    globals()["jwt_from_env"] = lambda: "token"
    try:
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            pem = tmp / "installed.pem"
            pem.write_text(
                "-----BEGIN CERTIFICATE-----\n"
                + base64.b64encode(cert_der).decode()
                + "\n-----END CERTIFICATE-----\n"
            )
            project = tmp / "project.pbxproj"
            project.write_text(PROJECT_FIXTURE)
            manifest = tmp / "manifest.json"
            export_plist = tmp / "ExportOptions.plist"
            prepare({
                "installed_pem": str(pem),
                "manifest": str(manifest),
                "profiles_dir": str(tmp / "profiles"),
                "team": "EXAMPLETEAM",
                "keychain": "/tmp/watchremote-signing.keychain-db",
                "pbxproj": str(project),
                "export_plist": str(export_plist),
            })
            text = project.read_text()
            if text.count("CODE_SIGN_STYLE = Manual;") != 3:
                raise SystemExit("prepare did not sign every distributable target")
            if "CODE_SIGN_STYLE = Automatic;" not in text:
                raise SystemExit("prepare signed a test target")
            if ("POST", "/v1/certificates") in calls or any(
                method == "DELETE" and path.startswith("/v1/certificates/")
                for method, path in calls
            ):
                raise SystemExit("prepare minted or deleted a certificate")
            if calls.count(("POST", "/v1/profiles")) != 2:
                raise SystemExit("prepare did not create a profile per bundle id")
            with export_plist.open("rb") as handle:
                options = plistlib.load(handle)
            if set(options["provisioningProfiles"]) != {
                PRIMARY_BUNDLE_ID,
                "com.lojo.WatchRemote.widget",
            }:
                raise SystemExit("export options missed a target")

            calls.clear()
            profiles.append({
                "type": "profiles",
                "id": "EXISTING",
                "attributes": {
                    "name": "WatchRemote App Store",
                    "profileType": PROFILE_TYPE,
                    "profileState": "ACTIVE",
                    "expirationDate": "2099-01-01T00:00:00.000+00:00",
                    "profileContent": base64.b64encode(
                        sign_profile(PRIMARY_BUNDLE_ID, cert_der, "WatchRemote App Store")
                    ).decode(),
                },
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": "BID-APP"}},
                    "certificates": {
                        "data": [{"type": "certificates", "id": SHARED_CERTIFICATE_ID}]
                    },
                },
            })
            single = PROJECT_FIXTURE.replace(
                'productType = "com.apple.product-type.app-extension";',
                'productType = "com.apple.product-type.framework";',
            )
            project.write_text(single)
            prepare({
                "installed_pem": str(pem),
                "manifest": str(manifest),
                "profiles_dir": str(tmp / "profiles"),
                "team": "EXAMPLETEAM",
                "keychain": "/tmp/watchremote-signing.keychain-db",
                "pbxproj": str(project),
                "export_plist": str(export_plist),
            })
            if ("POST", "/v1/profiles") in calls:
                raise SystemExit("prepare created a profile that already existed")
            if any(method == "POST" and path == "/v1/certificates" for method, path in calls):
                raise SystemExit("reuse path created a certificate")

            pem.write_text(
                "-----BEGIN CERTIFICATE-----\n"
                + base64.b64encode(b"\x30\x03other").decode()
                + "\n-----END CERTIFICATE-----\n"
            )
            calls.clear()
            try:
                prepare({
                    "installed_pem": str(pem),
                    "manifest": str(manifest),
                    "profiles_dir": str(tmp / "profiles"),
                    "team": "EXAMPLETEAM",
                    "keychain": "/tmp/watchremote-signing.keychain-db",
                    "pbxproj": str(project),
                    "export_plist": str(export_plist),
                })
            except SystemExit:
                pass
            else:
                raise SystemExit("prepare accepted a p12 that is not the shared certificate")
            if any(method == "POST" for method, _path in calls):
                raise SystemExit("a certificate mismatch still created signing assets")
    finally:
        globals()["api"], globals()["jwt_from_env"] = real_api, real_jwt


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
        return
    if len(sys.argv) > 1 and sys.argv[1] == "cleanup":
        cleanup()
        return
    if len(sys.argv) > 1 and sys.argv[1] == "prepare":
        required = (
            "installed_pem",
            "manifest",
            "profiles_dir",
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
    raise SystemExit("Usage: asc_signing.py --self-test | prepare | cleanup")


if __name__ == "__main__":
    main()
