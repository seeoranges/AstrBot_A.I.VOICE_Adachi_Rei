"""Offline process/network fixtures; never read the live installation's private files."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("review_backend_state", ROOT / "tools" / "backend_state.py")
backend = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backend)


class ProcessError(Exception):
    pass


def process(pid, *, user="desktop\\owner", exe="", cmd=None, denied=(), created=100):
    methods = {"username": user, "exe": exe, "cmdline": cmd or [], "name": "python.exe", "create_time": created}
    result = types.SimpleNamespace(pid=pid)
    for field, value in methods.items():
        setattr(result, field, Mock(side_effect=ProcessError() if field in denied else None, return_value=value))
    return result


def connection(status, local_port, pid, remote_port=0, remote_ip="127.0.0.1"):
    return types.SimpleNamespace(
        status=status, pid=pid,
        laddr=types.SimpleNamespace(port=local_port, ip="127.0.0.1"),
        raddr=types.SimpleNamespace(port=remote_port, ip=remote_ip) if remote_port else None,
    )


class SnapshotTests(unittest.TestCase):
    def collect(self, processes, connections=(), sessions=None, net_error=False, fallback=None):
        fake = types.SimpleNamespace(
            Error=ProcessError, Process=Mock(return_value=process(os.getpid())),
            process_iter=Mock(return_value=processes),
            net_connections=Mock(side_effect=ProcessError() if net_error else None, return_value=connections),
        )
        sessions = sessions or {}
        def session(pid):
            return sessions.get(pid, 1)
        with patch.object(backend, "psutil", fake), patch.object(backend, "_windows_session_id", session), \
             patch.object(backend.subprocess, "run", return_value=types.SimpleNamespace(stdout=json.dumps(fallback or {}).encode())):
            return backend.snapshot()

    def test_denied_cmdline_does_not_discard_known_exe(self):
        output = self.collect([process(10, exe=r"C:\app\QQ.exe", denied={"cmdline", "create_time"})])
        self.assertEqual(output["procs"][0]["exe"], r"C:\app\QQ.exe")
        self.assertEqual(output["procs"][0]["cmd"], "")
        self.assertEqual(output["procs"][0]["create"], 0)

    def test_denied_username_allowed_only_for_same_session_with_exe(self):
        rows = [process(10, exe=r"C:\app\QQ.exe", denied={"username"}),
                process(11, exe=r"C:\app\QQ.exe", denied={"username"}),
                process(12, exe=r"C:\app\QQ.exe", denied={"username"}),
                process(13, denied={"username"})]
        output = self.collect(rows, sessions={10: 1, 11: 2, 12: None, 13: 1})
        self.assertEqual([p["pid"] for p in output["procs"]], [10])

    def test_known_other_user_and_other_session_excluded(self):
        output = self.collect([process(10, user="desktop\\other"), process(11)], sessions={11: 2})
        self.assertEqual(output["procs"], [])

    def test_conflicting_ipv4_ipv6_listeners_are_ambiguous(self):
        output = self.collect([], [connection("LISTEN", 6185, 10), connection("LISTEN", 6185, 20)])
        self.assertIsNone(output["listen"][6185])

    def test_established_connections_must_target_loopback(self):
        output = self.collect([], [connection("ESTABLISHED", 1000, 10, 6199),
                                   connection("ESTABLISHED", 1001, 10, 6199, "::ffff:127.0.0.1"),
                                   connection("ESTABLISHED", 1002, 10, 6199, "198.51.100.1")])
        self.assertEqual(output["est"], [(1000, 6199, 10), (1001, 6199, 10)])

    def test_cim_fallback_preserves_readable_fields_and_exclusions(self):
        fallback = {"procs": [{"pid": 10, "exe": "", "cmd": "recovered", "name": "QQ.exe", "create": 80},
                               {"pid": 11, "exe": r"C:\other\QQ.exe"}],
                    "tcp": [{"State": "Listen", "LocalPort": 6185, "OwningProcess": 10},
                            {"State": "Established", "LocalPort": 1000, "RemotePort": 6199,
                             "RemoteAddress": "203.0.113.1", "OwningProcess": 10}]}
        output = self.collect([process(10, exe=r"C:\app\QQ.exe", denied={"cmdline"}),
                               process(11, user="desktop\\other")], net_error=True, fallback=fallback)
        self.assertEqual(len(output["procs"]), 1)
        self.assertEqual(output["procs"][0]["exe"], r"C:\app\QQ.exe")
        self.assertEqual(output["procs"][0]["cmd"], "recovered")
        self.assertEqual(output["listen"], {6185: 10})
        self.assertEqual(output["est"], [])


class ResolveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=ROOT / "tests")
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        (self.directory / "private").mkdir()
        (self.directory / "astrbot" / "data").mkdir(parents=True)
        (self.directory / "start-astrbot.cmd").touch()
        self.backend_file = self.directory / "private" / "backend.txt"
        self.backend_file.write_text("url: http://127.0.0.1:6185\n", encoding="utf-8")
        self.config = self.directory / "astrbot" / "data" / "cmd_config.json"
        self.config.write_text(json.dumps({"platform": [{"type": "aiocqhttp", "id": "大肥鱼", "ws_reverse_port": 6199}]}), encoding="utf-8")
        self.exe = str(self.directory / "uv" / "tools" / "astrbot" / "Scripts" / "python.exe")
        self.entry = str(self.directory / "uv" / "tools" / "astrbot" / "Scripts" / "astrbot.exe")

    def row(self, pid=10, cmd=None, exe=None):
        return {"pid": pid, "name": "python.exe", "exe": exe or self.exe,
                "cmd": cmd if cmd is not None else f'"{self.exe}" "{self.entry}" run', "create": 1}

    def resolve(self, procs=(), listen=None, est=(), check_page=lambda _: False):
        return backend.resolve(self.directory, repair=False,
                               snap={"procs": procs, "listen": listen or {}, "est": est}, check_page=check_page)

    def test_unrelated_listener_does_not_make_cli_up(self):
        output = self.resolve([self.row()], {6185: 999})
        self.assertNotEqual(output["state"], "up")
        self.assertEqual(output["pid"], 0)

    def test_console_entry_point_is_up(self):
        output = self.resolve([self.row()], {6185: 10})
        self.assertEqual(output["state"], "up")
        self.assertEqual(output["pid"], 10)

    def test_direct_executable_module_and_instance_main_are_supported(self):
        for row in (self.row(exe=self.entry, cmd=f'"{self.entry}" run'),
                    self.row(cmd=f'"{self.exe}" -m astrbot run'),
                    self.row(cmd=f'"{self.exe}" "{self.directory / "astrbot" / "main.py"}"')):
            with self.subTest(cmd=row["cmd"]):
                self.assertEqual(self.resolve([row], {6185: 10})["state"], "up")

    def test_maintenance_script_with_astrbot_in_path_is_not_brain(self):
        row = self.row(cmd=f'"{self.exe}" "{self.directory / "tools" / "qq_watch.py"}" --dir "{self.directory}"')
        self.assertEqual(self.resolve([row], {6185: 10})["state"], "off")

    def test_runtime_entry_mentioned_as_script_argument_is_not_brain(self):
        row = self.row(cmd=f'"{self.exe}" helper.py --original "{self.entry}"')
        self.assertEqual(self.resolve([row], {6185: 10})["state"], "off")

    def test_python_utf8_option_before_main_is_supported(self):
        row = self.row(cmd=f'"{self.exe}" -X utf8 "{self.directory / "astrbot" / "main.py"}"')
        self.assertEqual(self.resolve([row], {6185: 10})["state"], "up")

    def test_hidden_python_command_requires_dashboard_confirmation(self):
        row = self.row(cmd="")
        self.assertEqual(self.resolve([row], {6185: 10})["state"], "off")
        self.assertEqual(self.resolve([row], {6185: 10}, check_page=lambda port: port == 6185)["state"], "up")

    def test_online_requires_this_brain_and_this_client(self):
        client = self.row(pid=20, exe=str(self.directory / "NapCat" / "shell" / "QQ.exe"), cmd="")
        rows = [self.row(), client]
        self.assertTrue(self.resolve(rows, {6185: 10, 6199: 10}, [(2000, 6199, 20)])["online"])
        self.assertFalse(self.resolve(rows, {6185: 10, 6199: 999}, [(2000, 6199, 20)])["online"])
        self.assertFalse(self.resolve(rows, {6185: 10, 6199: 10}, [(2000, 6199, 999)])["online"])

    def test_multiple_qq_platform_ports_mark_ambiguous(self):
        self.config.write_text(json.dumps({"platform": [
            {"type": "aiocqhttp", "id": "one", "ws_reverse_port": 6199},
            {"type": "aiocqhttp", "id": "two", "ws_reverse_port": 6200}]}), encoding="utf-8")
        output = self.resolve([self.row()], {6185: 10, 6199: 10})
        self.assertEqual(output["ws_port"], 0)
        self.assertTrue(output["ambiguous"])
        self.assertFalse(output["online"])

    def test_empty_backend_url_uses_default(self):
        self.backend_file.write_text("url: \nusername: fake-user\npassword: fake-password\n", encoding="utf-8")
        output = self.resolve([self.row()], {6185: 10})
        self.assertEqual(output["port"], 6185)
        self.assertEqual(output["url"], "http://127.0.0.1:6185")
        self.assertEqual(output["state"], "up")

    def test_empty_url_does_not_consume_or_repair_next_credential_line(self):
        content = "url: \r\nusername: fake-user\r\npassword: fake-password\r\n"
        self.backend_file.write_bytes(content.encode())
        self.assertEqual(backend.kv(self.backend_file)["url"], "")
        self.assertEqual(backend.kv(self.backend_file)["username"], "fake-user")
        self.assertFalse(backend.repair_url(self.backend_file, "http://127.0.0.1:6285"))
        self.assertEqual(self.backend_file.read_bytes(), content.encode())

    def test_launcher_main_must_be_execution_entry(self):
        (self.directory / "start-astrbot.cmd").unlink()
        launcher_root = self.directory / "launcher"
        instance = launcher_root / "instances" / "only"
        data = instance / "core" / "data"
        data.mkdir(parents=True)
        (data / "cmd_config.json").write_text(self.config.read_text(encoding="utf-8"), encoding="utf-8")
        main = instance / "core" / "main.py"
        for command, expected in ((f'"{self.exe}" -X utf8 "{main}"', "up"),
                                  (f'"{self.exe}" helper.py --original "{main}"', "off")):
            with self.subTest(command=command):
                output = backend.resolve(self.directory, repair=False, launcher_roots=[launcher_root],
                                         snap={"procs": [self.row(cmd=command)], "listen": {6185: 10}, "est": []})
                self.assertEqual(output["state"], expected)

    def test_no_qq_platform_keeps_legacy_default_port(self):
        self.assertEqual(backend.ws_port({}), 6199)
        self.assertEqual(backend.ws_port({"platform": None}), 6199)

    def test_url_repair_preserves_other_bytes(self):
        initial = b"\xef\xbb\xbfurl: http://127.0.0.1:6185\r\nusername: fake-user\r\npassword: fake-password\r\n"
        self.backend_file.write_bytes(initial)
        self.assertTrue(backend.repair_url(self.backend_file, "http://127.0.0.1:6285"))
        self.assertEqual(self.backend_file.read_bytes(), initial.replace(b":6185", b":6285"))
        self.assertEqual(next(self.backend_file.parent.glob("backend.txt.before-port-*.bak")).read_bytes(), initial)


if __name__ == "__main__":
    unittest.main()
