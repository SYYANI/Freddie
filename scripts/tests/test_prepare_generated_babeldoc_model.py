"""Offline regression tests for the model preparation used by CI and scripts/build."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "prepare-generated-babeldoc-model"
MODEL = "doclayout_yolo_docstructbench_imgsz1024.mlmodel"
ASSET = "doclayout-yolo-docstructbench-imgsz1024"


class PrepareGeneratedModelTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="readpaper-model-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tools = self.root / "tools"
        self.models = self.root / "Vendor/Models"
        self.tools.mkdir()
        self.models.mkdir(parents=True)
        self.manifest = self.models / "manifest.json"
        self.original = {
            "schemaVersion": 2,
            "assets": [{"id": ASSET, "size": 3, "sha256": "old-source-hash",
                        "compiled": {"files": [{"path": "coremldata.bin", "sha256": "pinned"}]}}],
        }
        self.manifest.write_text(json.dumps(self.original))
        self.builder = self.tools / "build_coreml_models.sh"
        self.builder.write_text('''#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
models_root="$root/Vendor/Models"
model_size=3
model_sha256=old-source-hash
output="$models_root/generated-model"
report=unused
verify_file() { return 1; }
compile_runtime_model() {
  python3 "$root/tools/compile_layout_model.py" --root "$root" --models-root "$models_root"
}
printf new > "$output"
verify_file "$output" "$model_sha256" "$model_size" || {
  print -u2 "Generated Core ML model does not match the trusted release artifact"
  print -u2 "Report: $report"
  exit 1
}
mv "$output" "$models_root/''' + MODEL + '''"
compile_runtime_model
''')
        self.builder.chmod(0o755)
        # Model compilation must see the new source hash, keep the compiled pins,
        # and must never use --update-manifest to silently re-bless compiled output.
        (self.tools / "compile_layout_model.py").write_text('''import hashlib, json, pathlib, sys
root = pathlib.Path(__file__).resolve().parents[1]
models = root / "Vendor/Models"
asset = json.loads((models / "manifest.json").read_text())["assets"][0]
assert "--update-manifest" not in sys.argv
assert asset["sha256"] == hashlib.sha256((models / "''' + MODEL + '''").read_bytes()).hexdigest()
assert asset["compiled"]["files"][0]["sha256"] == "pinned"
if (root / "reject-compiled").exists():
    sys.exit("compiled model does not match the pinned files")
(root / "compiled").touch()
''')
        (self.tools / "verify_model_vendor.py").write_text('''import pathlib, sys
root = pathlib.Path(__file__).resolve().parents[1]
sys.exit(0 if (root / "compiled").exists() else 1)
''')

    def prepare(self):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.root)],
                              capture_output=True, text=True)

    def test_updates_source_before_compiling_and_preserves_compiled_pins(self):
        self.manifest.chmod(0o444)
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = self.original
        expected["assets"][0]["sha256"] = hashlib.sha256(b"new").hexdigest()
        self.assertEqual(json.loads(self.manifest.read_text()), expected)
        self.assertTrue((self.root / "compiled").exists())
        self.assertFalse(list(self.tools.glob(".readpaper-coreml-*")))
        self.assertFalse(list(self.models.glob(".readpaper-model-manifest-*")))

    def test_verified_model_is_reused_without_rebuilding(self):
        (self.root / "compiled").touch()
        self.builder.unlink()
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.manifest.read_text()), self.original)

    def test_rejects_unexpected_generated_size(self):
        self.builder.write_text(self.builder.read_text().replace("printf new", "printf longer"))
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected size", result.stderr)
        self.assertEqual(json.loads(self.manifest.read_text()), self.original)
        self.assertFalse((self.root / "compiled").exists())
        self.assertFalse(list(self.tools.glob(".readpaper-coreml-*")))

    def test_rejects_changed_upstream_compilation_step(self):
        self.builder.write_text(self.builder.read_text().replace("--models-root", "--new-option"))
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("compilation step changed", result.stderr)
        self.assertFalse((self.models / MODEL).exists())

    def test_compiled_hash_failure_is_not_swallowed(self):
        (self.root / "reject-compiled").touch()
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("compiled model does not match the pinned files", result.stderr)
        self.assertFalse((self.root / "compiled").exists())


if __name__ == "__main__":
    unittest.main()
