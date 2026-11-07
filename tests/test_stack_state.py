import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import types
import unittest
from unittest.mock import MagicMock


ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


state = load("_test_launcher_stack", ROOT / "tools" / "stack_state.py")
real_backend = load("_test_launcher_backend", ROOT / "tools" / "backend_state.py")


def proc(pid, exe, args=None, created=100.0):
    return {"pid": pid, "exe": str(exe), "name": str(exe).replace("\\", "/").rsplit("/", 1)[-1],
            "cmd": args or "", "create": created}


class FakeBackend:
    norm = staticmethod(real_backend.norm)
    within = staticmethod(real_backend.within)
    _command_args = staticmethod(real_backend._command_args)
    _python_entry = staticmethod(real_backend._python_entry)
    _cli_process = staticmethod(real_backend._cli_process)
    _main_process = staticmethod(real_backend._main_process)

    def __init__(self, snapshot):
        self.data = snapshot
        self.sessions = {}
        self.current = 2

    def _windows_session_id(self, pid):
        return self.sessions.get(pid, self.current)

    def snapshot(self):
        return self.data

    def resolve(self, root, repair=False, snap=None):
        assert repair is False
        snap = self.data if snap is None else snap
        owned = [p for p in snap["procs"] if self._cli_process(p, root)]
        listening = snap["listen"]
        pid = listening.get(6185)
        up = pid in {p["pid"] for p in owned}
        return {"state": "up" if up else "starting" if owned else "off", "pid": pid if up else 0,
                "port": 6185, "ws_port": 6199, "online": False, "ambiguous": False, "instance": ""}


class StackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix=".stack-test-", dir=ROOT)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "start-astrbot.cmd").write_text("test", encoding="utf-8")
        self.snap = {"procs": [], "listen": {}, "est": []}
        self.backend = FakeBackend(self.snap)
        self.get_json = MagicMock(return_value={"models": [{"name": "bge-m3:latest"}]})

    def inspect(self, **kwargs):
        return state.inspect_stack(self.root, backend=self.backend, get_json=self.get_json, **kwargs)

    def watch(self, pid=103, directory=None, args=None):
        directory = self.root if directory is None else directory
        exe = self.root / "tools" / "python" / "pythonw.exe"
        return proc(pid, exe, args or f'"{exe}" -X utf8 "{self.root / "tools" / "qq_watch.py"}" --dir "{directory}"')

    def snow(self, pid=102, entry=".\\index.mjs"):
        exe = self.root / "SnowLuma" / "node.exe"
        return proc(pid, exe, f'"{exe}" "{entry}"')

    def ollama(self, pid=104):
        exe = self.root / "Ollama" / "ollama.exe"
        return proc(pid, exe, f'"{exe}" serve')

    def brain(self, pid=101):
        exe = self.root / "uv" / "bin" / "astrbot.exe"
        return proc(pid, exe, f'"{exe}" run')

    def test_foreign_listener_never_authorizes_ownership(self):
        self.snap["listen"] = {6185: 991, 6199: 992, 5099: 993, 11434: 994}
        result = self.inspect()
        self.assertEqual(result["backend"]["owned"], [])
        self.assertTrue(result["backend"]["port_conflict"])
        self.assertFalse(result["backend"]["ws_ready"])
        self.assertTrue(result["snowluma"]["port_conflict"])
        self.assertTrue(result["ollama"]["external"])

    def test_own_running_and_ready_states_are_distinct(self):
        self.snap["procs"] = [self.brain(), self.snow(), self.watch(), self.ollama()]
        result = self.inspect()
        self.assertEqual(result["backend"]["state"], "starting")
        self.assertTrue(result["snowluma"]["running"])
        self.assertFalse(result["snowluma"]["ready"])
        self.assertTrue(result["watch"]["running"])
        self.snap["listen"] = {6185: 101, 6199: 101, 5099: 102, 11434: 104}
        result = self.inspect()
        self.assertEqual(result["backend"]["state"], "up")
        self.assertTrue(result["backend"]["ws_ready"])
        self.assertTrue(result["snowluma"]["ready"])

    def test_all_owned_entries_include_creation_time(self):
        self.snap["procs"] = [self.brain(), self.snow(), self.watch(), self.ollama()]
        for component in ("backend", "snowluma", "watch", "ollama"):
            entry = self.inspect()[component]["owned"][0]
            self.assertEqual(entry["created"], 100.0)
            self.assertIsInstance(entry["pid"], int)

    def test_other_windows_session_is_never_owned(self):
        self.snap["procs"] = [self.brain(), self.snow(), self.watch(), self.ollama()]
        self.backend.sessions = {p["pid"]: 3 for p in self.snap["procs"]}
        result = self.inspect()
        for component in ("backend", "snowluma", "watch", "ollama"):
            self.assertEqual(result[component]["owned"], [])

    def test_unknown_session_fails_closed(self):
        self.snap["procs"] = [self.snow(), self.watch()]
        self.backend.current = None
        result = self.inspect()
        self.assertTrue(result["watch"]["unknown"])
        self.assertTrue(result["snowluma"]["unknown"])
        self.assertEqual(result["watch"]["owned"], [])

    def test_arbitrary_pythonw_is_not_our_watch(self):
        exe = self.root / "tools" / "python" / "pythonw.exe"
        self.snap["procs"] = [proc(103, exe, f'"{exe}" "{self.root / "other.py"}" --original "{self.root / "tools" / "qq_watch.py"}"')]
        self.assertEqual(self.inspect()["watch"]["owned"], [])

    def test_watch_other_dir_is_not_owned(self):
        self.snap["procs"] = [self.watch(directory=self.root / "sibling")]
        self.assertEqual(self.inspect()["watch"]["owned"], [])

    def test_hidden_pythonw_is_unknown_not_stop_authority(self):
        self.snap["procs"] = [proc(103, self.root / "tools" / "python" / "pythonw.exe")]
        result = self.inspect()["watch"]
        self.assertTrue(result["unknown"])
        self.assertEqual(result["owned"], [])

    def test_fresh_heartbeat_does_not_authorize_hidden_watch_stop(self):
        self.snap["procs"] = [proc(103, self.root / "tools" / "python" / "pythonw.exe")]
        (self.root / "logs").mkdir()
        (self.root / "logs" / "qq-watch.json").write_text(json.dumps({"pid": 103, "at": time.time()}))
        result = self.inspect()["watch"]
        self.assertTrue(result["running"])
        self.assertTrue(result["unknown"])
        self.assertEqual(result["owned"], [])

    def test_reused_heartbeat_pid_does_not_report_live_watch(self):
        self.snap["procs"] = [proc(103, self.root / "tools" / "python" / "pythonw.exe", created=time.time() + 10)]
        (self.root / "logs").mkdir()
        (self.root / "logs" / "qq-watch.json").write_text(json.dumps({"pid": 103, "at": time.time()}))
        self.assertFalse(self.inspect()["watch"]["running"])

    def test_node_requires_actual_index_entry(self):
        self.snap["procs"] = [self.snow(entry="other.mjs")]
        self.assertEqual(self.inspect()["snowluma"]["owned"], [])

    def test_official_qq_only_and_no_live_account_claim(self):
        official = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Tencent" / "QQNT" / "QQ.exe"
        embedded = self.root / "NapCat" / "QQ.exe"
        self.snap["procs"] = [proc(201, official), proc(202, embedded)]
        result = self.inspect()
        self.assertTrue(result["qq"]["running"])
        self.assertIsNone(result["qq"]["owner_login"])
        self.assertNotIn("owned", result["qq"])
        self.snap["procs"] = [proc(202, embedded)]
        self.assertFalse(self.inspect()["qq"]["running"])

    def test_hidden_official_qq_candidate_reports_unknown(self):
        self.snap["procs"] = [dict(pid=201, exe="", name="QQ.exe", cmd="", create=100)]
        self.assertTrue(self.inspect()["qq"]["unknown"])

    def test_daemon_and_relogin_match_file_not_substring(self):
        exe = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        bridge = self.root / "tools" / "aivoice-daemon.ps1"
        relogin = self.root / "tools" / "relogin-qq.ps1"
        self.snap["procs"] = [proc(301, exe, f'"{exe}" -NoProfile -File "{bridge}"'),
                              proc(302, exe, f'"{exe}" -File "{relogin}" -Dir "{self.root}"'),
                              proc(303, exe, f'"{exe}" -Command "Write-Output {bridge}"')]
        result = self.inspect()
        self.assertEqual([x["pid"] for x in result["voice_bridge"]["owned"]], [301])
        self.assertEqual([x["pid"] for x in result["relogin"]["owned"]], [302])

    def test_ollama_api_checks_model_and_external_service(self):
        result = self.inspect()["ollama"]
        self.assertTrue(result["api_ready"])
        self.assertTrue(result["model_available"])
        self.assertTrue(result["external"])
        self.get_json.return_value = {"models": [{"name": "other:latest"}]}
        self.assertFalse(self.inspect()["ollama"]["model_available"])
        self.get_json.return_value = {"message": "not Ollama"}
        self.assertFalse(self.inspect()["ollama"]["api_ready"])

    def test_unknown_external_clients_mark_ollama_shared(self):
        self.snap["procs"] = [self.ollama(), self.brain()]
        self.snap["listen"] = {11434: 104}
        self.snap["est"] = [(50001, 11434, 101)]
        self.assertFalse(self.inspect()["ollama"]["shared"])
        self.snap["est"].append((50002, 11434, 999))
        self.assertTrue(self.inspect()["ollama"]["shared"])

    def test_raw_command_and_sensitive_fields_not_returned(self):
        self.snap["procs"] = [self.brain()]
        self.snap["procs"][0]["cmd"] += " --token super-secret-value"
        text = json.dumps(self.inspect())
        self.assertNotIn("super-secret-value", text)
        self.assertNotIn('"exe"', text)
        self.assertNotIn('"cmd"', text)

    def stopped(self, kind="backend", pid=101, created=100.0, process=None):
        process = process or types.SimpleNamespace(create_time=lambda: 100.0, kill=MagicMock(), wait=MagicMock(), is_running=lambda: False)
        factory = MagicMock(return_value=process)
        result = state.stop_owned(self.root, kind, pid, created, backend=self.backend, snap=self.snap, process_factory=factory)
        return result, process, factory

    def test_stop_revalidates_then_waits_before_success(self):
        self.snap["procs"] = [self.brain()]
        result, process, _ = self.stopped()
        self.assertTrue(result["ok"])
        process.kill.assert_called_once()
        process.wait.assert_called_once_with(timeout=5)

    def test_stop_refuses_pid_reuse_in_snapshot(self):
        self.snap["procs"] = [self.brain()]
        result, process, _ = self.stopped(created=99.0)
        self.assertEqual(result["reason"], "pid_reused")
        process.kill.assert_not_called()

    def test_stop_refuses_pid_reuse_after_snapshot(self):
        self.snap["procs"] = [self.brain()]
        process = types.SimpleNamespace(create_time=lambda: 200.0, kill=MagicMock())
        result, _, _ = self.stopped(process=process)
        self.assertEqual(result["reason"], "pid_reused")
        process.kill.assert_not_called()

    def test_stop_never_accepts_qq_or_unknown_pid(self):
        for kind in ("qq", "backend"):
            result, process, _ = self.stopped(kind=kind)
            self.assertFalse(result["ok"])
            process.kill.assert_not_called()

    def test_stop_shared_or_external_ollama_refused(self):
        self.snap["procs"] = [self.ollama()]
        self.snap["listen"] = {11434: 999}
        result, process, _ = self.stopped(kind="ollama", pid=104)
        self.assertEqual(result["reason"], "ollama_not_exclusive")
        process.kill.assert_not_called()
        self.snap["listen"] = {11434: 104}
        self.snap["est"] = [(50000, 11434, 999)]
        self.assertEqual(self.stopped(kind="ollama", pid=104)[0]["reason"], "ollama_not_exclusive")

    def test_stop_reports_permissions_without_raw_error(self):
        self.snap["procs"] = [self.brain()]
        process = types.SimpleNamespace(create_time=lambda: 100.0, kill=MagicMock(side_effect=PermissionError("super-secret-value")))
        result, _, _ = self.stopped(process=process)
        self.assertEqual(result, {"ok": False, "reason": "access_denied"})

    def test_stop_checks_process_really_exited(self):
        self.snap["procs"] = [self.brain()]
        process = types.SimpleNamespace(create_time=lambda: 100.0, kill=MagicMock(), wait=MagicMock(), is_running=lambda: True)
        self.assertEqual(self.stopped(process=process)[0]["reason"], "not_exited")

    def test_already_exited_process_is_successful_noop(self):
        class NoSuchProcess(Exception): pass
        factory = MagicMock(side_effect=NoSuchProcess())
        result = state.stop_owned(self.root, "backend", 101, 100.0, backend=self.backend, snap=self.snap, process_factory=factory)
        self.assertEqual(result, {"ok": True, "reason": "already_stopped"})


if __name__ == "__main__":
    unittest.main()
