"""Source checks run in the repository process, without app Documents access."""
from pathlib import Path
import unittest


class ModelPackageSourceTests(unittest.TestCase):
    def test_no_private_adapter_or_obsolete_qwen_download_path(self):
        root = Path(__file__).resolve().parents[3]
        for name in ("ComputerUseArtifactManifest.swift", "ComputerUseInstaller.swift"):
            source = (root / "host-mac/RemoteDesktopHost/ComputerUse" / name).read_text()
            for forbidden in ("minal7/computer-use-lora", "adapter_model.safetensors", "Qwen2.5-VL"):
                with self.subTest(source=name, forbidden=forbidden):
                    self.assertNotIn(forbidden, source)
