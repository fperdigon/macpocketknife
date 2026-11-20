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

"""Bundle metadata tests with fake compilation, Git and signing."""
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SHA = "a" * 40


class BuildMetadataTests(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        for directory in ("scripts", "Resources", "tools", "bin"):
            (self.tmp / directory).mkdir()
        for file in ("scripts/make-app-bundle.sh", "Resources/Info.plist", "Resources/AppIcon.icns",
                     "Resources/MenuBarIcon.png", "Resources/MenuBarIcon@2x.png",
                     "Resources/MacPocketKnife.entitlements", "VERSION"):
            shutil.copy(ROOT / file, self.tmp / file)
        (self.tmp / "bin/MacPocketKnife").write_text("fixture")
        self.tool("swift", '#!/bin/sh\ncase "$*" in *--show-bin-path*) echo "$FAKE_BIN" ;; esac\n')
        self.tool("codesign", "#!/bin/sh\nexit 0\n")
        self.tool("git", '#!/bin/sh\n[ -n "${FAKE_SHA:-}" ] || exit 1\nprintf "%s\\n" "$FAKE_SHA"\n')
        self.env = dict(os.environ, PATH=f"{self.tmp / 'tools'}:{os.environ['PATH']}",
                        FAKE_BIN=str(self.tmp / "bin"))
        for key in ("GITHUB_SHA", "BUILD_CHANNEL", "FAKE_SHA"):
            self.env.pop(key, None)

    def tool(self, name, content):
        target = self.tmp / "tools" / name
        target.write_text(content)
        target.chmod(0o755)

    def build(self, expected=0, **env):
        result = subprocess.run(["sh", str(self.tmp / "scripts/make-app-bundle.sh")],
                                env=dict(self.env, **env), capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        if expected == 0:
            return plistlib.loads((self.tmp / "build/MacPocketKnife.app/Contents/Info.plist").read_bytes())
        return None

    def test_channels_and_environment_sha(self):
        for channel in ("stable", "nightly", "dev"):
            with self.subTest(channel=channel):
                info = self.build(BUILD_CHANNEL=channel, GITHUB_SHA=SHA, FAKE_SHA="b" * 40)
                self.assertEqual(info["CAMBuildChannel"], channel)
                self.assertEqual(info["CAMGitSHA"], SHA)
                self.assertEqual(info["CFBundleShortVersionString"], (ROOT / "VERSION").read_text().strip())

    def test_git_fallback(self):
        info = self.build(FAKE_SHA=SHA)
        self.assertEqual(info["CAMGitSHA"], SHA)
        self.assertEqual(info["CAMBuildChannel"], "dev")

    def test_outside_checkout(self):
        self.assertEqual(self.build()["CAMGitSHA"], "unknown")

    def test_invalid_sha_fails(self):
        self.build(expected=1, GITHUB_SHA="invalid")

    def test_invalid_channel_fails(self):
        self.build(expected=1, BUILD_CHANNEL="invalid")


if __name__ == "__main__":
    unittest.main()
