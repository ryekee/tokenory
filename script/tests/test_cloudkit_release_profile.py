import copy
from datetime import datetime, timedelta, timezone
import hashlib
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))
from cloudkit_release_profile import BUNDLE, CONTAINER, TEAM, entitlements


class ReleaseCloudKitProfileTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.now(timezone.utc)
        certificate = b"synthetic-Developer-ID-certificate"
        self.fingerprints = {hashlib.sha1(certificate).hexdigest().upper()}
        self.grants = {
            "com.apple.application-identifier": TEAM + "." + BUNDLE,
            "com.apple.developer.team-identifier": TEAM,
            "com.apple.developer.icloud-container-identifiers": [CONTAINER],
            "com.apple.developer.icloud-services": "*",
            "com.apple.developer.icloud-container-environment": ["Production", "Development"],
        }
        self.profile = {
            "DeveloperCertificates": [certificate], "TeamIdentifier": [TEAM], "Platform": ["OSX"],
            "ExpirationDate": self.now + timedelta(days=1), "ProvisionsAllDevices": True,
            "ApplicationIdentifierPrefix": [TEAM], "Entitlements": self.grants,
        }

    def test_distribution_is_limited_to_production_and_one_container(self):
        fingerprint, result = entitlements(self.profile, self.fingerprints, self.now)
        self.assertIn(fingerprint, self.fingerprints)
        self.assertEqual(result["com.apple.developer.icloud-container-environment"], "Production")
        self.assertEqual(result["com.apple.developer.icloud-services"], ["CloudKit"])
        self.assertEqual(result["com.apple.developer.icloud-container-identifiers"], [CONTAINER])

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS codesign")
    def test_verify_signed_cloudkit_entitlements(self):
        _, grants = entitlements(self.profile, self.fingerprints, self.now)
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "Fixture"
            requested = Path(temporary) / "CloudKit.entitlements"
            requested.write_bytes(plistlib.dumps(grants))
            subprocess.run(["/usr/bin/clang", "-x", "c", "-", "-o", str(binary)],
                           input=b"int main(void) { return 0; }\n", check=True)
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", str(requested),
                            str(binary)], check=True, capture_output=True)
            verify = [sys.executable, str(SCRIPT_DIR / "cloudkit_release_profile.py"), "verify",
                      str(binary), str(requested)]

            matching = subprocess.run(verify, capture_output=True, text=True)
            self.assertEqual(matching.returncode, 0, matching.stderr)

            del grants["com.apple.developer.icloud-container-environment"]
            requested.write_bytes(plistlib.dumps(grants))
            mismatched = subprocess.run(verify, capture_output=True, text=True)
            self.assertNotEqual(mismatched.returncode, 0)
            self.assertIn("signed CloudKit entitlements did not match the release profile", mismatched.stderr)

    def test_reject_wrong_profile_certificate_environment_and_bundle(self):
        for key, value in [("ProvisionsAllDevices", False), ("DeveloperCertificates", [b"other key"]),
                           ("ExpirationDate", self.now - timedelta(days=1)), ("Platform", ["iOS"]),
                           ("TeamIdentifier", ["other"]), ("ProvisionedDevices", ["test"])]:
            with self.subTest(key=key):
                self.assertIsNone(entitlements({**self.profile, key: value}, self.fingerprints, self.now))
        for key, value in [("com.apple.developer.icloud-container-environment", ["Development"]),
                           ("com.apple.developer.icloud-container-identifiers", ["iCloud.someotherapp"]),
                           ("com.apple.application-identifier", TEAM + "." + BUNDLE + ".synctrial"),
                           ("com.apple.security.get-task-allow", True)]:
            with self.subTest(key=key):
                profile = copy.deepcopy(self.profile)
                profile["Entitlements"][key] = value
                self.assertIsNone(entitlements(profile, self.fingerprints, self.now))
