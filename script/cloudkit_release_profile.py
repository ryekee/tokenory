#!/usr/bin/env python3
"""Prepare the Hiko Developer ID profile and verify signed CloudKit entitlements."""

import argparse
from datetime import datetime, timezone
import hashlib
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

TEAM = "JQTFJ8P2T7"
BUNDLE = "ee.ryek.tokenory"
CONTAINER = "iCloud.ee.ryek.tokenory"


def permits(rule, value):
    values = [rule] if isinstance(rule, str) else rule or []
    return value in values or "*" in values


def entitlements(profile, certificates, now):
    rules = profile.get("Entitlements", {})
    application = rules.get("com.apple.application-identifier", "")
    certificate = next((fingerprint for data in profile.get("DeveloperCertificates", [])
                        if (fingerprint := hashlib.sha1(data).hexdigest().upper()) in certificates), None)
    expires = profile.get("ExpirationDate")
    allowed_ids = [prefix + "." + BUNDLE for prefix in profile.get("ApplicationIdentifierPrefix", [])]
    if not (certificate and TEAM in profile.get("TeamIdentifier", []) and expires and
            expires.replace(tzinfo=timezone.utc) > now and "OSX" in profile.get("Platform", []) and
            profile.get("ProvisionsAllDevices") is True and not profile.get("ProvisionedDevices") and
            not rules.get("com.apple.security.get-task-allow") and application in allowed_ids and
            rules.get("com.apple.developer.team-identifier") == TEAM and
            permits(rules.get("com.apple.developer.icloud-container-identifiers"), CONTAINER) and
            permits(rules.get("com.apple.developer.icloud-services"), "CloudKit") and
            permits(rules.get("com.apple.developer.icloud-container-environment"), "Production")):
        return None
    return certificate, {
        "com.apple.application-identifier": application,
        "com.apple.developer.team-identifier": TEAM,
        "com.apple.developer.icloud-container-identifiers": [CONTAINER],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-environment": "Production",
    }


def identities(identity):
    listing = subprocess.check_output(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"], text=True)
    return {fingerprint for fingerprint, name in re.findall(r'([0-9A-F]{40}) "([^"]+)"', listing)
            if name.startswith("Developer ID Application: ") and name.endswith("(" + TEAM + ")")
            and identity in (name, fingerprint)}


def prepare(identity, profile_path, output):
    certificates = identities(identity)
    if not certificates:
        raise SystemExit("A valid Hiko Developer ID Application signing identity is required.")
    if profile_path:
        candidates = [profile_path.expanduser()]
    else:
        directories = ["Library/Developer/Xcode/UserData/Provisioning Profiles", "Library/MobileDevice/Provisioning Profiles"]
        candidates = [path for directory in directories for path in (Path.home() / directory).glob("*.provisionprofile")]
    matches = []
    for path in candidates:
        decoded = subprocess.run(["/usr/bin/security", "cms", "-D", "-i", str(path)], capture_output=True)
        if decoded.returncode:
            if profile_path:
                raise SystemExit("Apple security could not decode the selected Developer ID profile.")
            continue
        profile = plistlib.loads(decoded.stdout)
        match = entitlements(profile, certificates, datetime.now(timezone.utc))
        if match:
            matches.append((profile["ExpirationDate"], str(path), match))
    if not matches:
        raise SystemExit("Install a current Hiko Developer ID provisioning profile for ee.ryek.tokenory with "
                         "iCloud.ee.ryek.tokenory, or set TOKENORY_DEVELOPER_ID_PROFILE to its path.")
    _, path, (fingerprint, grants) = max(matches, key=lambda item: (item[0], item[1]))
    shutil.copyfile(path, output / "embedded.provisionprofile")
    (output / "CloudKit.entitlements").write_bytes(plistlib.dumps(grants))
    print(fingerprint)


def verify(app, requested):
    signed = subprocess.check_output(["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(app)])
    if plistlib.loads(requested.read_bytes()) != plistlib.loads(signed):
        raise SystemExit("The packaged app's signed CloudKit entitlements did not match the release profile.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("--identity", required=True)
    prepare_parser.add_argument("--profile", type=Path)
    prepare_parser.add_argument("--out", type=Path, required=True)
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("app", type=Path)
    verify_parser.add_argument("requested", type=Path)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.identity, args.profile, args.out)
    else:
        verify(args.app, args.requested)
