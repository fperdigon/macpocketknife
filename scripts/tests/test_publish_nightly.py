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

"""Publishing tests with a fixed date and fake GitHub/Git commands; no network."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SHA = "a" * 40
TAG = "nightly-20260102-aaaaaaa"


class PublishNightlyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        for directory in ("scripts", "tools", "dist"):
            (self.tmp / directory).mkdir()
        for name in ("publish-nightly.sh", "release-notes.sh"):
            shutil.copy(ROOT / "scripts" / name, self.tmp / "scripts" / name)
        self.dmg = self.tmp / "dist/MacPocketKnife-0.1.0.dmg"
        self.dmg.write_bytes(b"fixture")
        pathlib.Path(str(self.dmg) + ".sha256").write_text("stale checksum")
        self.tool("date", "#!/bin/sh\necho 2026-01-02\n")
        self.tool("git", """#!/bin/sh
case "$1" in
  log) echo '- Current change (aaaaaaa)' ;;
  describe) echo v0.1.0 ;;
esac
""")
        self.tool("gh", """#!/bin/bash
printf '%s\\n' "$*" >> "$CALL_LOG"
case "$2" in
  view)
    if [ "$3" = nightly-20260102-aaaaaaa ]; then
      [ "${ALREADY_EXISTS:-0}" = 1 ]
    else
      echo '<!-- nightly-sha: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb -->'
      echo '<!-- history -->'
      echo '### Previous build'
      echo '- Previous change'
    fi ;;
  list)
    [ ! -e "$PUBLISHED" ] || echo nightly-20260102-aaaaaaa
    echo nightly-20260101-bbbbbbb
    echo nightly-20251231-ccccccc ;;
  create) touch "$PUBLISHED" ;;
  delete) exit 0 ;;
  *) exit 1 ;;
esac
""")
        self.env = dict(os.environ, PATH=f"{self.tmp / 'tools'}:{os.environ['PATH']}",
                        GITHUB_SHA=SHA, GITHUB_REF="refs/heads/main", KEEP_NIGHTLIES="2", CALL_LOG=str(self.tmp / "calls"),
                        PUBLISHED=str(self.tmp / "published"))

    def tool(self, name, content):
        target = self.tmp / "tools" / name
        target.write_text(content)
        target.chmod(0o755)

    def publish(self, expected=0, **env):
        result = subprocess.run(["bash", "scripts/publish-nightly.sh"], cwd=self.tmp,
                                env=dict(self.env, **env), capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_history_retention_and_final_asset_checksums(self):
        self.publish()
        notes = (self.tmp / "notes.md").read_text()
        self.assertIn("Unsigned (ad-hoc signed, not notarized) and unstable", notes)
        self.assertLess(notes.index("Current change"), notes.index("Previous change"))
        calls = (self.tmp / "calls").read_text()
        self.assertIn("--prerelease", calls)
        self.assertIn("delete nightly-20251231-ccccccc --yes", calls)
        self.assertNotIn("delete nightly-20260101-bbbbbbb", calls)
        sums = list((self.tmp / "dist").glob("*.sha256"))
        self.assertEqual(len(sums), 1)
        self.assertEqual(sums[0].name, "MacPocketKnife-0.1.0-nightly-2026-01-02-aaaaaaa.dmg.sha256")
        self.assertIn("MacPocketKnife-0.1.0-nightly-2026-01-02-aaaaaaa.dmg", sums[0].read_text())
        result = subprocess.run(["shasum", "-a", "256", "-c", sums[0].name],
                                cwd=self.tmp / "dist", capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_rerun_is_noop(self):
        self.publish(ALREADY_EXISTS="1")
        self.assertNotIn("create", (self.tmp / "calls").read_text())
        self.assertTrue(self.dmg.exists())

    def test_refuses_to_publish_from_other_refs(self):
        for ref in ("refs/heads/feature", "refs/tags/v1.0.0", "refs/pull/1/merge"):
            self.publish(expected=2, GITHUB_REF=ref)
        self.assertFalse((self.tmp / "calls").exists())

    def test_invalid_retention_fails_before_publishing(self):
        for value in ("0", "-1", "invalid", "08"):
            self.publish(expected=2, KEEP_NIGHTLIES=value)
        self.assertFalse((self.tmp / "calls").exists())


if __name__ == "__main__":
    unittest.main()
