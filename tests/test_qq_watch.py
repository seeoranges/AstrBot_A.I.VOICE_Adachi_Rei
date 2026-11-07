"""Offline watchdog regressions: no credentials, HTTP, tasks, or notifications."""
import ctypes
import importlib.util
import json
from pathlib import Path
import socket
import struct
import tempfile
import types
import unittest
from unittest.mock import MagicMock, patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ops_qq_watch", ROOT / "tools" / "qq_watch.py")
watch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(watch)


def event(text, second=0):
    return f"11-05 12:00:{second:02d} [info] {text}"


class LogTests(unittest.TestCase):
    def test_scan_is_not_a_successful_login(self):
        self.assertTrue(watch.kicked_in([event("登录态已失效"), event("二维码已被扫描", 1)]))

    def test_received_message_proves_alive_even_if_it_quotes_kick(self):
        self.assertFalse(watch.kicked_in([event("登录态已失效"), event(" 接收 <- 私聊 下线通知", 1)]))

    def test_multiline_chat_does_not_create_kick(self):
        self.assertFalse(watch.kicked_in([event(" 接收 <- 私聊"), "下线通知", event(" 发送 -> 回复", 1)]))

    def test_sending_after_kick_does_not_clear_it(self):
        self.assertTrue(watch.kicked_in([event("登录态已失效"), event(" 发送 -> 尝试发送", 1)]))

    def test_ansi_log_prefix_and_new_login(self):
        self.assertFalse(watch.kicked_in([event("\x1b[31m登录态已失效\x1b[0m"), event("本账号数据/缓存目录", 1)]))

    def test_partial_tail_first_line_is_discarded(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            path = Path(folder) / "napcat.log"
            path.write_bytes(b"prefix " + b"x" * 200 + b"KickedOffLine\n" + event("normal").encode())
            lines = watch.tail(path, 70)
            self.assertEqual(lines, [event("normal")])


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.config = patch.object(watch, "napcat_http", return_value=("http://127.0.0.1:1234", "test-token"))
        self.config.start()
        self.addCleanup(self.config.stop)
        self.opener = MagicMock()
        self.factory = patch.object(watch.urllib.request, "build_opener", return_value=self.opener)
        self.factory.start()
        self.addCleanup(self.factory.stop)

    def reply(self, value):
        self.opener.open.return_value.__enter__.return_value.read.return_value = json.dumps(value, indent=2).encode()
        return watch.qq_logged_in("unused")

    def test_pretty_printed_json_login_and_response_closed(self):
        self.assertTrue(self.reply({"retcode": 0, "data": {"user_id": "12345"}}))
        self.opener.open.return_value.__exit__.assert_called_once()

    def test_explicit_zero_user_is_offline(self):
        self.assertFalse(self.reply({"retcode": 0, "data": {"user_id": 0}}))

    def test_failed_query_or_malformed_data_is_unknown(self):
        for value in ([1], {"retcode": 1}, {"retcode": False, "data": {"user_id": 1}},
                      {"retcode": 0, "data": "user_id"}, {"retcode": 0, "data": {"user_id": 1.2}},
                      {"retcode": 0, "data": {"user_id": True}}):
            with self.subTest(value=value):
                self.assertIsNone(self.reply(value))

    def test_http_401_is_unknown_not_qq_kick(self):
        import urllib.error
        self.opener.open.side_effect = urllib.error.HTTPError("http://localhost", 401, "Unauthorized", {}, None)
        self.assertIsNone(watch.qq_logged_in("unused"))

    def test_remote_config_never_receives_local_token(self):
        with patch.object(watch, "napcat_http", return_value=("http://example.com", "test-token")):
            self.assertIsNone(watch.qq_logged_in("unused"))
        self.opener.open.assert_not_called()


class MutexTests(unittest.TestCase):
    def mutex(self, result, handle=2**40):
        kernel = MagicMock()
        kernel.OpenMutexW.return_value = handle
        kernel.WaitForSingleObject.return_value = result
        return kernel

    def test_64bit_handle_and_owned_mutex(self):
        kernel = self.mutex(258)
        with patch.object(watch, "IS_WIN", True), patch.object(ctypes, "WinDLL", return_value=kernel):
            self.assertTrue(watch.relogin_running(ROOT))
        self.assertIs(kernel.OpenMutexW.restype, ctypes.c_void_p)
        kernel.CloseHandle.assert_called_once_with(2**40)
        kernel.ReleaseMutex.assert_not_called()

    def test_existing_unowned_and_abandoned_mutex_are_released(self):
        for result in (0, 128):
            kernel = self.mutex(result)
            with patch.object(watch, "IS_WIN", True), patch.object(ctypes, "WinDLL", return_value=kernel):
                self.assertFalse(watch.relogin_running(ROOT))
            kernel.ReleaseMutex.assert_called_once_with(2**40)

    def test_access_denied_is_busy_and_missing_is_not(self):
        for error, busy in ((5, True), (2, False)):
            kernel = self.mutex(0, handle=0)
            with patch.object(watch, "IS_WIN", True), patch.object(ctypes, "WinDLL", return_value=kernel), patch.object(ctypes, "get_last_error", return_value=error):
                self.assertEqual(watch.relogin_running(ROOT), busy)


class LocalTests(unittest.TestCase):
    def setUp(self):
        watch.FAST.clear()

    def test_fast_clock_backwards_forces_full_check(self):
        watch.FAST.update(at=1000, port=6199, srv={1}, cli={2})
        with patch.object(watch, "IS_WIN", True), patch.object(watch, "tcp_rows") as rows:
            self.assertFalse(watch.fast_online(999))
        rows.assert_not_called()

    def test_remote_same_port_not_accepted_as_local_websocket(self):
        loopback = struct.unpack("=I", socket.inet_aton("127.0.0.1"))[0]
        remote = struct.unpack("=I", socket.inet_aton("203.0.113.1"))[0]
        port = socket.htons(6199)
        raw = struct.pack("I", 2) + struct.pack("6I", 5, loopback, 1, loopback, port, 12) + struct.pack("6I", 5, loopback, 1, remote, port, 13)

        def table(buffer, size, *unused):
            if buffer is None:
                size._obj.value = len(raw)
                return 122
            ctypes.memmove(buffer, raw, len(raw))
            return 0

        with patch.object(ctypes.windll.iphlpapi, "GetExtendedTcpTable", side_effect=table):
            rows = watch.tcp_rows()
        self.assertEqual([row[3] for row in rows], [12])

    def test_ambiguous_backend_is_unknown(self):
        backend = types.SimpleNamespace(resolve=MagicMock(return_value={"ambiguous": True}))
        with patch.dict("sys.modules", backend_state=backend), patch.object(watch, "fast_online", return_value=False):
            self.assertEqual(watch.local_status("unused")[0], "unknown")

    def test_relogin_can_check_real_state_without_reporting_own_lock(self):
        with patch.object(watch, "fast_online", return_value=True), patch.object(watch, "relogin_running", return_value=True), patch.object(watch, "protocol", return_value="snowluma"):
            self.assertEqual(watch.local_status("unused")[0], "busy")
            self.assertEqual(watch.local_status("unused", ignore_relogin=True)[0], "online")


class ReloginTests(unittest.TestCase):
    def setUp(self):
        watch.REL.update(first=0.0, last=0.0, attempt=0.0, tick=0.0)
        for name, kwargs in (("IS_WIN", {"new": True}), ("is_cloud", {"return_value": False}),
                             ("relogin_running", {"return_value": False}), ("log", {})):
            patcher = patch.object(watch, name, **kwargs)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.process = patch.object(watch.subprocess, "run", return_value=types.SimpleNamespace(returncode=0)).start()
        self.addCleanup(patch.stopall)

    def tick(self, now, status="offline"):
        with patch.object(watch.time, "time", return_value=now):
            watch.auto_relogin("unused", status)

    def test_only_after_continuous_grace_and_success_cooldown(self):
        self.tick(1000)
        self.tick(1120)
        self.process.assert_not_called()
        self.tick(1180)
        self.assertEqual(watch.REL["last"], 1180)
        self.tick(1240)
        self.assertEqual(self.process.call_count, 1)

    def test_failed_task_does_not_claim_success_or_consume_15min_cooldown(self):
        self.process.return_value.returncode = 1
        self.tick(1000)
        self.tick(1180)
        self.assertEqual(watch.REL["last"], 0)
        self.assertNotIn("已经自动按", watch.log.call_args.args[1])
        self.process.return_value.returncode = 0
        self.tick(1240)
        self.assertEqual(watch.REL["last"], 1240)

    def test_cloud_never_runs_local_relogin_task(self):
        with patch.object(watch, "is_cloud", return_value=True):
            self.tick(1000)
            self.tick(1180)
        self.process.assert_not_called()

    def test_resume_restarts_grace(self):
        self.tick(1000)
        self.tick(2000)
        self.assertEqual(watch.REL["first"], 2000)
        self.process.assert_not_called()

    def test_busy_breaks_continuity(self):
        self.tick(1000)
        self.tick(1120, "busy")
        self.tick(1180)
        self.process.assert_not_called()
        self.assertEqual(watch.REL["first"], 1180)


class WatchTests(unittest.TestCase):
    def test_offline_grace_and_three_reminder_schedule(self):
        state = watch.Watch(60)
        self.assertIsNone(state.tick("offline", 1000))
        self.assertEqual(state.tick("offline", 1180), "offline")
        self.assertIsNone(state.tick("offline", 1240))
        # Tick regularly so these gaps represent reminders, not sleep/resume.
        for now in range(1300, 2980, 60):
            self.assertIsNone(state.tick("offline", now))
        self.assertEqual(state.tick("offline", 2980), "offline")
        state.tick("online", 3040)
        self.assertEqual(state.sent, 0)

    def test_two_confirmed_kicks_and_scan_does_not_count(self):
        state = watch.Watch(60)
        self.assertIsNone(state.tick("kicked", 1000))
        self.assertEqual(state.tick("kicked", 1060), "kicked")

    def test_backward_clock_restarts_grace(self):
        state = watch.Watch(60)
        state.tick("offline", 1000)
        self.assertIsNone(state.tick("offline", 900))
        self.assertEqual(state.since, 900)


class RunStateTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(dir=ROOT)
        self.addCleanup(self.folder.cleanup)
        self.directory = Path(self.folder.name)
        (self.directory / "logs").mkdir()
        watch.REL.update(first=0.0, last=0.0, attempt=0.0, tick=0.0)
        self.patches = [patch.object(watch, "take_lock", return_value=object()),
                        patch.object(watch, "is_cloud", return_value=False),
                        patch.object(watch.os, "chdir"), patch.object(watch, "log"),
                        patch.object(watch.time, "time", return_value=1180),
                        patch.object(watch.time, "sleep", side_effect=KeyboardInterrupt)]
        for patcher in self.patches:
            patcher.start()
            self.addCleanup(patcher.stop)

    def run_once(self):
        with self.assertRaises(KeyboardInterrupt):
            watch.run(self.directory)

    def test_restart_preserves_successful_relogin_cooldown(self):
        (self.directory / "logs" / "qq-watch.json").write_text('{"relogin_last": 1100}', encoding="utf-8")
        with patch.object(watch, "status_of", return_value=("offline", "test")), patch.object(watch, "auto_relogin"), patch.object(watch, "write_state") as write:
            self.run_once()
        self.assertEqual(watch.REL["last"], 1100)
        self.assertEqual(write.call_args.kwargs["relogin_last"], 1100)

    def test_switch_off_resets_continuity_but_keeps_success_cooldown(self):
        (self.directory / "private").mkdir()
        (self.directory / "private" / "qq-watch-off.txt").touch()
        watch.REL.update(first=1000, last=1100)
        with patch.object(watch, "status_of") as status, patch.object(watch, "auto_relogin") as relogin, patch.object(watch, "write_state") as write:
            self.run_once()
        status.assert_not_called()
        relogin.assert_not_called()
        self.assertEqual(watch.REL["first"], 0)
        self.assertEqual(write.call_args.kwargs["relogin_last"], 1100)

    def test_probe_exception_clears_continuity_and_overwrites_stale_online(self):
        watch.REL["first"] = 1000
        with patch.object(watch, "status_of", side_effect=OSError("test")), patch.object(watch, "write_state") as write:
            self.run_once()
        self.assertEqual(watch.REL["first"], 0)
        self.assertEqual(write.call_args.kwargs["state"], "unknown")

    def test_failed_atomic_state_replace_does_not_leave_temp(self):
        with patch.object(watch.os, "replace", side_effect=PermissionError("test")):
            watch.write_state(self.directory, state="online")
        self.assertEqual(list((self.directory / "logs").glob("*.tmp")), [])


if __name__ == "__main__":
    unittest.main()
