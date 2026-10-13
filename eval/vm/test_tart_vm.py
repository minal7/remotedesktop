from __future__ import annotations

import json
import os
import tempfile
import unittest
import uuid
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

try:
    from . import tart_vm
except ImportError:
    import tart_vm


class RecordingRunner:
    def __init__(self) -> None:
        self.calls: list[tuple[list[str], dict[str, object]]] = []
        self.fail: tuple[str, ...] | None = None
        self.fail_app = False
        self.response = ""
        self.state = ""

    def __call__(self, argv: list[str], **kwargs: object) -> SimpleNamespace:
        self.calls.append((argv, kwargs))
        joined = tuple(argv[:2])
        if self.fail and joined == self.fail:
            return SimpleNamespace(returncode=1, stdout="", stderr="failed")
        if self.fail_app and argv[0] == "ssh" and "--debug-agent-eval" in argv[-1]:
            return SimpleNamespace(returncode=1, stdout="", stderr="app failed")
        stdout = ""
        if argv[:3] == ["tart", "list", "--quiet"]:
            stdout = tart_vm.GOLDEN_NAME + "\n"
        elif argv[:2] == ["tart", "ip"]:
            stdout = "192.0.2.40\n"
        elif argv[0] == "ssh" and "--debug-agent-eval" in argv[-1]:
            stdout = self.response
        elif argv[0] == "ssh" and "__eval/state" in argv[-1]:
            stdout = self.state
        elif argv[0] == "ssh" and "__eval/health" in argv[-1]:
            stdout = '{"ok":true}'
        elif argv[0] == "scp":
            destination = Path(argv[-1])
            destination.mkdir(parents=True, exist_ok=True)
            (destination / "episode.jsonl").write_text("{}\n", encoding="utf-8")
            (destination / "step-000.png").write_bytes(b"png")
        return SimpleNamespace(returncode=0, stdout=stdout, stderr="")


class TartVMTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.temp_root = Path(self.temporary.name)
        self.identity = self.temp_root / "ssh-key"
        self.known_hosts = self.temp_root / "known_hosts"
        self.identity.write_text("test key material", encoding="utf-8")
        self.known_hosts.write_text("guest ssh-ed25519 AAAA-test", encoding="utf-8")
        self.identity.chmod(0o600)
        self.known_hosts.chmod(0o600)
        output_parent = tart_vm.ROOT / "build" / "eval"
        output_parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.output_temporary = tempfile.TemporaryDirectory(dir=output_parent)
        self.addCleanup(self.output_temporary.cleanup)
        self.env = {
            "EVAL_TASK_ID": "web-basic-generic-001",
            "EVAL_RUN_TOKEN": "a" * 32,
            "EVAL_TART_GOLDEN": tart_vm.GOLDEN_NAME,
            "TART_HOME": str(tart_vm.TART_ROOT),
            "REMOTE_DESKTOP_EVAL_ROOT": self.output_temporary.name,
            "EVAL_VM_SSH_IDENTITY": str(self.identity),
            "EVAL_VM_KNOWN_HOSTS": str(self.known_hosts),
            "EVAL_VM_SSH_USER": "evaluser",
            "EVAL_VM_PROJECT_ROOT": "/Users/evaluser/project",
            "EVAL_VM_REMOTE_EVAL_ROOT": "/Users/evaluser/Eval Runs",
            "EVAL_FIXTURE_FILES": str(tart_vm.FIXTURE_FILES),
        }
        self.config = tart_vm.Config.from_env(self.env)
        self.run_root = self.temp_root / "vm-runs"
        self.addCleanup(self.temporary.cleanup)

    def test_reset_dry_run_uses_owned_golden_resources_and_strict_ssh(self) -> None:
        def unexpected_run(*_args: object, **_kwargs: object) -> None:
            raise AssertionError("dry-run must not invoke Tart or SSH")

        result = tart_vm.reset(self.config, run=unexpected_run, dry_run=True)
        commands = result["commands"]
        self.assertEqual(commands[0], ["tart", "clone", tart_vm.GOLDEN_NAME, self.config.vm_name])
        self.assertEqual(commands[1], ["tart", "set", self.config.vm_name, "--cpu", "4",
                                      "--memory", "16384", "--display", "1440x900px",
                                      "--no-display-refit"])
        self.assertEqual(commands[2], ["tart", "run", "--no-graphics", "--no-audio",
                                      "--no-usb-accessories", "--no-clipboard", self.config.vm_name])
        ssh = result["ssh_options"]
        self.assertIn("StrictHostKeyChecking=yes", ssh)
        self.assertIn("HostKeyAlias=general-agent-golden", ssh)
        self.assertIn(f"UserKnownHostsFile={self.known_hosts.resolve()}", ssh)
        self.assertIn("BatchMode=yes", ssh)
        self.assertIn("PasswordAuthentication=no", ssh)
        self.assertEqual(tart_vm.ssh_base(self.config, "2001:db8::40")[-1],
                         "evaluser@[2001:db8::40]")
        with self.assertRaises(tart_vm.Blocked):
            tart_vm.ssh_base(self.config, "guest.local")

    def test_wrong_golden_and_tart_home_are_blocked(self) -> None:
        wrong = dict(self.env, EVAL_TART_GOLDEN="some-other-image")
        with self.assertRaises(tart_vm.Blocked):
            tart_vm.Config.from_env(wrong)
        wrong_home = dict(self.env, TART_HOME=str(self.temp_root / "other-tart-home"))
        with self.assertRaises(tart_vm.Blocked):
            tart_vm.Config.from_env(wrong_home)
        wrong_output = dict(self.env, REMOTE_DESKTOP_EVAL_ROOT=str(self.temp_root / "outside-project"))
        with self.assertRaises(tart_vm.Blocked):
            tart_vm.Config.from_env(wrong_output)

    def test_wrong_or_symlinked_state_is_blocked(self) -> None:
        with patch.object(tart_vm, "RUN_ROOT", self.run_root):
            tart_vm.secure_dir(self.config.state_path.parent)
            self.config.state_path.write_text(json.dumps({
                "task_id": "different-task", "token": self.config.token,
                "vm_name": self.config.vm_name,
            }), encoding="utf-8")
            self.config.state_path.chmod(0o600)
            with self.assertRaises(tart_vm.Blocked):
                tart_vm._read_state(self.config)
            self.config.state_path.unlink()
            target = self.temp_root / "elsewhere"
            target.write_text("{}", encoding="utf-8")
            self.config.state_path.symlink_to(target)
            with self.assertRaises(tart_vm.Blocked):
                tart_vm._read_state(self.config)

    def test_reset_lifecycle_starts_fixture_guest_with_no_shared_devices(self) -> None:
        runner = RecordingRunner()
        process = SimpleNamespace(pid=12345)
        with patch.object(tart_vm, "RUN_ROOT", self.run_root):
            result = tart_vm.reset(self.config, runner, launch_process=lambda *args, **kwargs: process)
            self.assertEqual(result, {"vm": self.config.vm_name, "address": "192.0.2.40"})
            commands = [call[0] for call in runner.calls]
            self.assertIn(["tart", "clone", tart_vm.GOLDEN_NAME, self.config.vm_name], commands)
            self.assertIn(["tart", "set", self.config.vm_name, "--cpu", "4", "--memory", "16384",
                           "--display", "1440x900px", "--no-display-refit"], commands)
            self.assertTrue(any(call[0] == "ssh" and "StrictHostKeyChecking=yes" in call
                                for command in commands for call in [command]))
            self.assertTrue(any("fixtures/web/server.py" in command[-1] for command in commands if command[0] == "ssh"))
            self.assertTrue(all(call[1]["env"]["TART_NO_AUTO_PRUNE"] == "1"
                                for call in runner.calls if call[0][0] == "tart"))
            self.assertTrue(any("StrictHostKeyChecking=yes" in command for command in commands if command[0] == "ssh"))
            self.assertTrue(self.config.state_path.is_file())
            self.assertEqual(json.loads(self.config.state_path.read_text())["pid"], process.pid)

    def test_reset_failure_cleans_only_its_owned_clone(self) -> None:
        runner = RecordingRunner()
        runner.fail = ("tart", "set")
        with patch.object(tart_vm, "RUN_ROOT", self.run_root):
            with self.assertRaises(tart_vm.Blocked):
                tart_vm.reset(self.config, runner, launch_process=lambda *args, **kwargs: SimpleNamespace(pid=1))
            commands = [call[0] for call in runner.calls]
            self.assertIn(["tart", "stop", self.config.vm_name], commands)
            self.assertIn(["tart", "delete", self.config.vm_name], commands)
            self.assertFalse(self.config.state_path.exists())

    def test_reset_state_write_failure_cleans_clone_created_by_this_reset(self) -> None:
        runner = RecordingRunner()
        with patch.object(tart_vm, "RUN_ROOT", self.run_root), patch.object(
                tart_vm, "_write_state", side_effect=tart_vm.Blocked("state unavailable")):
            with self.assertRaises(tart_vm.Blocked):
                tart_vm.reset(self.config, runner, launch_process=lambda *args, **kwargs: SimpleNamespace(pid=1))
            commands = [call[0] for call in runner.calls]
            self.assertIn(["tart", "stop", self.config.vm_name], commands)
            self.assertIn(["tart", "delete", self.config.vm_name], commands)

    def test_driver_exports_episode_state_and_vm_proof_from_matching_reset(self) -> None:
        runner = RecordingRunner()
        self.config = tart_vm.Config.from_env(self.env)
        guest_run = str(uuid.uuid4()).upper()
        guest_episode = (Path(self.config.remote_eval_root) / guest_run / "episodes" /
                         "123e4567-e89b-12d3-a456-426614174000" / "episode.jsonl")
        request = {"task_id": "123e4567-e89b-12d3-a456-426614174000", "prompt": "Read the visible value."}
        runner.guest_task_id = request["task_id"]
        runner.response = json.dumps({"task_id": request["task_id"], "outcome": "completed",
                                      "answer": "A visible value", "episode_path": str(guest_episode),
                                      "wall_seconds": 1.25, "real_host_app": True})
        runner.state = json.dumps({"url": "http://127.0.0.1:8765/forms.html", "updated_at": 1.0,
                                   "elements": {}, "submit_count": 0, "delete_count": 0,
                                   "share_count": 0, "secure_nonempty_count": 0})
        with patch.object(tart_vm, "RUN_ROOT", self.run_root):
            tart_vm._write_state(self.config, 123)
            result = tart_vm.drive(self.config, runner, request_text=json.dumps(request))
            episode = Path(result["episode_path"])
            self.assertTrue(episode.is_file())
            self.assertEqual(episode.relative_to(self.config.local_eval_root).parts,
                             (guest_run, "episodes", request["task_id"], "episode.jsonl"))
            self.assertEqual(result["fixture_state"]["run_token"], self.config.token)
            self.assertEqual(result["vm_execution"], {"engine": "tart", "golden": tart_vm.GOLDEN_NAME,
                              "vm_name": self.config.vm_name, "run_token": self.config.token,
                              "reset_state": "verified"})
            self.assertIn("--debug-agent-eval", next(call[0][-1] for call in runner.calls
                                                       if call[0][0] == "ssh" and "--debug-agent-eval" in call[0][-1]))
            scp = next(call[0] for call in runner.calls if call[0][0] == "scp")
            self.assertIn("StrictHostKeyChecking=yes", scp)
            self.assertIn("HostKeyAlias=general-agent-golden", scp)
            self.assertEqual(scp[-2], f"evaluser@192.0.2.40:{guest_episode.parent}")
            self.assertNotIn("'", scp[-2])
            self.assertFalse(self.config.state_path.exists())

    def test_driver_app_failure_still_removes_its_clone_and_state(self) -> None:
        runner = RecordingRunner()
        runner.fail_app = True
        request = {"task_id": "123e4567-e89b-12d3-a456-426614174000"}
        with patch.object(tart_vm, "RUN_ROOT", self.run_root):
            tart_vm._write_state(self.config, 123)
            with self.assertRaises(tart_vm.Blocked):
                tart_vm.drive(self.config, runner, request_text=json.dumps(request))
            commands = [call[0] for call in runner.calls]
            self.assertIn(["tart", "stop", self.config.vm_name], commands)
            self.assertIn(["tart", "delete", self.config.vm_name], commands)
            self.assertFalse(self.config.state_path.exists())

    def test_preflight_accepts_swift_omitted_nil_fields_and_adds_vm_proof(self) -> None:
        runner = RecordingRunner()
        runner.response = json.dumps({
            "operation": "preflight", "real_host_app": True, "outcome": "ready",
            "checks": [{"name": name, "status": "passed", "detail": "ok"}
                       for name in ("host_process", "accessibility", "screen_recording",
                                    "safari_helper", "safari_extension", "model")],
            "safari_extension_status": "enabled", "safari_ping_count": 100,
            "safari_ping_p95_ms": 1.25, "model_status": "loaded",
        })
        request = {"operation": "preflight", "probe_url": "http://127.0.0.1:8765/forms.html?__eval_run=" + self.config.token}
        with patch.object(tart_vm, "RUN_ROOT", self.run_root):
            tart_vm._write_state(self.config, 123)
            result = tart_vm.drive(self.config, runner, request_text=json.dumps(request))
        self.assertEqual(result["outcome"], "ready")
        self.assertEqual(result["vm_execution"]["run_token"], self.config.token)
        self.assertFalse(any(call[0][0] == "scp" for call in runner.calls))
        self.assertFalse(self.config.state_path.exists())

    def test_blocked_preflight_can_omit_unavailable_optional_statuses(self) -> None:
        response = {
            "operation": "preflight", "real_host_app": True, "outcome": "infra_blocked",
            "checks": [{"name": "host_process", "status": "passed", "detail": "ok"},
                       {"name": "accessibility", "status": "blocked", "detail": "denied"}],
            "blocked_reason": "Accessibility denied", "owner_action": "Grant Accessibility",
        }
        self.assertEqual(tart_vm._safe_preflight_response(response), response)


if __name__ == "__main__":
    unittest.main()
