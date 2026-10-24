import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "source_audit", Path(__file__).resolve().parents[1] / "check_source_only.py"
)
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class SourceOnlyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        font_dir = self.root / "engine/siglus_rs/crates/siglus_scene_vm/assets/fonts"
        font_dir.mkdir(parents=True)
        (font_dir / "default.ttf").write_bytes(b"licensed-font-fixture")
        (font_dir / "OFL.txt").write_text("SIL OPEN FONT LICENSE")
        (font_dir / "SOURCE.json").write_text(json.dumps({
            "static_sha256": hashlib.sha256(b"licensed-font-fixture").hexdigest()
        }))

    def test_source_and_documented_font_are_accepted(self):
        (self.root / "main.swift").write_text("import SwiftUI\n")
        self.assertEqual(AUDIT.audit(self.root)[1], [])

    def test_game_and_private_files_are_rejected(self):
        (self.root / "SceneZH.pck").write_bytes(b"game-data-fixture")
        (self.root / ".env").write_text("LOCAL_SETTING=fixture")
        failures = AUDIT.audit(self.root)[1]
        self.assertEqual({p for p, _ in failures}, {"SceneZH.pck", ".env"})

    def test_secret_content_is_reported_without_echoing_its_value(self):
        value = "ghp_" + "z" * 40
        (self.root / "config.txt").write_text(value)
        failures = AUDIT.audit(self.root)[1]
        self.assertEqual(failures, [("config.txt", "credential pattern")])

    def test_replacing_the_verified_font_is_detected(self):
        font = self.root / "engine/siglus_rs/crates/siglus_scene_vm/assets/fonts/default.ttf"
        font.write_bytes(b"different-font")
        self.assertEqual(AUDIT.audit(self.root)[1], [
            ("default.ttf", "font differs from licensed source manifest")
        ])


if __name__ == "__main__":
    unittest.main()
