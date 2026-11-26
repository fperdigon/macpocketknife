# Copyright 2026 Francisco Perdigon Romero and contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Deterministic verifier tests: fake disk images, mounts, signatures and lipo."""
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "verify-dmg.sh"
ENTITLEMENTS = SCRIPT.parent.parent / "Resources/MacPocketKnife.entitlements"


class VerifyDmgTests(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.tools = self.tmp / "tools"
        self.tools.mkdir()
        self.stage = self.tmp / "stage"
        self.app = self.stage / "MacPocketKnife.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Resources").mkdir()
        self.exe = self.app / "Contents/MacOS/MacPocketKnife"
        self.exe.write_text("fixture")
        self.exe.chmod(0o755)
        self.plist = self.app / "Contents/Info.plist"
        self.info = {
            "CFBundleIdentifier": "io.github.fperdigon.macpocketknife",
            "CFBundleExecutable": "MacPocketKnife",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundlePackageType": "APPL",
            "LSUIElement": True,
        }
        self.save_plist()
        (self.stage / "Applications").symlink_to("/Applications")
        self.dmg = self.tmp / "fixture.dmg"
        self.dmg.touch()
        self.log = self.tmp / "calls"
        self.env = dict(os.environ, PATH=f"{self.tools}:{os.environ['PATH']}",
                        FIXTURE=str(self.stage), CALL_LOG=str(self.log))
        self.tool("hdiutil", """#!/bin/bash
printf '%s\\n' "$*" >> "$CALL_LOG"
case "$1" in
  verify) [ "${FAIL_VERIFY:-0}" = 0 ] ;;
  attach)
    [ "${FAIL_ATTACH:-0}" = 0 ] || exit 1
    [[ "$*" == *-readonly* ]] || exit 1
    for last; do :; done
    cp -R "$FIXTURE/." "$last/" ;;
  detach) [ "${FAIL_DETACH:-0}" = 0 ] ;;
  *) exit 1 ;;
esac
""")
        self.tool("lipo", """#!/bin/bash
printf '%s\\n' "$*" >> "$CALL_LOG"
[ "$3" != "${MISSING_ARCH:-none}" ]
""")
        self.tool("codesign", """#!/bin/bash
printf '%s\\n' "$*" >> "$CALL_LOG"
for app; do :; done
case "$1" in
  --force)
    mkdir -p "$app/Contents/_CodeSignature"
    if [ "$4" = --entitlements ]; then
      cp "$5" "$app/Contents/_CodeSignature/entitlements.plist"
    else
      rm -f "$app/Contents/_CodeSignature/entitlements.plist"
    fi
    exit 0 ;;
  -dvv)
    printf '%b' "${DVV_OUTPUT-}"
    exit 0 ;;
  -d)
    [ ! -f "$app/Contents/_CodeSignature/entitlements.plist" ] ||
      cat "$app/Contents/_CodeSignature/entitlements.plist" ;;
esac
[ "${BAD_SIGNATURE:-0}" = 0 ]
""")
        self.sign_fixture(ENTITLEMENTS)

    def sign_fixture(self, entitlements=None):
        command = ["codesign", "--force", "--sign", "-"]
        if entitlements is not None:
            command.extend(["--entitlements", str(entitlements)])
        subprocess.run(command + [str(self.app)], env=self.env, check=True)

    def tool(self, name, text):
        target = self.tools / name
        target.write_text(text)
        target.chmod(0o755)

    def save_plist(self):
        self.plist.write_bytes(plistlib.dumps(self.info))

    def verify(self, expected=0, expected_error=None, **env):
        result = subprocess.run(["bash", str(SCRIPT), str(self.dmg)],
                                env=dict(self.env, **env), capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        if expected_error is not None:
            self.assertIn(expected_error, result.stderr)
        return self.log.read_text()

    def test_valid_bundle_and_readonly_mount(self):
        log = self.verify()
        self.assertIn("-readonly", log)
        self.assertIn("-verify_arch arm64", log)
        self.assertIn("-verify_arch x86_64", log)
        self.assertIn("--verify --deep --strict", log)
        self.assertIn("-d --entitlements - --xml", log)
        self.assertIn("detach", log)

    def test_missing_microphone_entitlement_unmounts(self):
        self.sign_fixture()
        self.assertIn("detach", self.verify(
            1, expected_error="missing microphone entitlement"))

    def test_bad_signature_unmounts(self):
        self.assertIn("detach", self.verify(1, BAD_SIGNATURE="1"))

    def test_missing_architecture_unmounts(self):
        for arch in ("arm64", "x86_64"):
            with self.subTest(arch=arch):
                self.assertIn("detach", self.verify(1, MISSING_ARCH=arch))

    def test_missing_executable_bit_unmounts(self):
        self.exe.chmod(0o644)
        self.assertIn("detach", self.verify(1))

    def test_not_menu_bar_app_unmounts(self):
        self.info["LSUIElement"] = False
        self.save_plist()
        self.assertIn("detach", self.verify(1))

    def test_missing_resources_unmounts(self):
        (self.app / "Contents/Resources").rmdir()
        self.assertIn("detach", self.verify(1))

    def test_missing_shortcut_unmounts(self):
        (self.stage / "Applications").unlink()
        self.assertIn("detach", self.verify(1))

    def test_wrong_bundle_identifier_unmounts(self):
        self.info["CFBundleIdentifier"] = "invalid"
        self.save_plist()
        self.assertIn("detach", self.verify(1))

    def test_multiple_apps_unmounts(self):
        (self.stage / "Other.app").mkdir()
        self.assertIn("detach", self.verify(1))

    def test_checksum_failure_does_not_attach(self):
        self.assertNotIn("attach", self.verify(1, FAIL_VERIFY="1"))

    def test_attach_failure(self):
        self.assertNotIn("detach", self.verify(1, FAIL_ATTACH="1"))

    def test_detach_failure_fails(self):
        log = self.verify(1, FAIL_DETACH="1")
        # Fake mounts are ordinary directories; clean up the retained work directory.
        mount = next(line.split(" -quiet")[0][7:] for line in log.splitlines()
                     if line.startswith("detach "))
        shutil.rmtree(pathlib.Path(mount).parent)

    def test_expected_identity_matches_leaf_authority(self):
        self.verify(DVV_OUTPUT="Identifier=x\\nAuthority=MacPocketKnife Signing\\nTeamIdentifier=not set\\n",
                    EXPECT_SIGNED_IDENTITY="MacPocketKnife Signing")

    def test_expected_identity_ignores_later_chain_entries(self):
        self.assertIn("detach", self.verify(
            1, expected_error="unexpected signing identity",
            DVV_OUTPUT="Authority=Other Leaf\\nAuthority=MacPocketKnife Signing\\n",
            EXPECT_SIGNED_IDENTITY="MacPocketKnife Signing"))

    def test_expected_identity_rejects_other_certificate(self):
        self.verify(1, expected_error="unexpected signing identity",
                    DVV_OUTPUT="Authority=Someone Else\\n",
                    EXPECT_SIGNED_IDENTITY="MacPocketKnife Signing")

    def test_expected_identity_rejects_adhoc(self):
        self.verify(1, expected_error="ad-hoc signed",
                    DVV_OUTPUT="Signature=adhoc\\n", EXPECT_SIGNED_IDENTITY="MacPocketKnife Signing")

    def test_expected_identity_rejects_missing_authority(self):
        self.verify(1, expected_error="found none", DVV_OUTPUT="Identifier=x\\n",
                    EXPECT_SIGNED_IDENTITY="MacPocketKnife Signing")

    def test_no_expected_identity_skips_authority_check(self):
        log = self.verify(DVV_OUTPUT="Signature=adhoc\\n")
        self.assertNotIn("-dvv", log)

    def test_usage(self):
        result = subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage", result.stderr)

    def test_missing_file(self):
        self.dmg.unlink()
        result = subprocess.run(["bash", str(SCRIPT), str(self.dmg)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("file not found", result.stderr)


if __name__ == "__main__":
    unittest.main()
