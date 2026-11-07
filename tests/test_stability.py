import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("round3_watch_tests", ROOT / "tools" / "qq_watch.py")
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)


class StabilityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix=".watch-test-", dir=ROOT)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        watch.REL.clear()
        watch.REL.update(first=0.0, last=0.0, attempt=0.0, tick=0.0)

    def auto_context(self, scan=False, delay=0, returncode=0):
        mocks = [patch.object(watch, "IS_WIN", True), patch.object(watch, "is_cloud", return_value=False),
                 patch.object(watch, "requires_scan", return_value=scan), patch.object(watch, "automatic_retry_delay", return_value=delay),
                 patch.object(watch, "relogin_running", return_value=False), patch.object(watch, "log"),
                 patch.object(watch.subprocess, "run", return_value=types.SimpleNamespace(returncode=returncode))]
        values = [mock.start() for mock in mocks]
        for mock in mocks:
            self.addCleanup(mock.stop)
        return values[-2], values[-1]

    def test_root_shell_log_is_discovered(self):
        shell = self.root / "NapCat" / "NapCat.test.Shell"
        shell.mkdir(parents=True)
        path = shell / "napcat-run.log"
        path.write_text("log", encoding="utf-8")
        self.assertEqual(watch.napcat_log(self.root), path)

    def test_old_version_log_layout_still_supported(self):
        logdir = self.root / "NapCat" / "NapCat.test.Shell" / "versions" / "1" / "resources" / "app" / "napcat" / "logs"
        logdir.mkdir(parents=True)
        path = logdir / "old.log"
        path.write_text("log", encoding="utf-8")
        self.assertEqual(watch.napcat_log(self.root), path)

    def test_latest_root_log_wins(self):
        shell = self.root / "NapCat" / "NapCat.test.Shell"
        shell.mkdir(parents=True)
        first, second = shell / "napcat-run-old.log", shell / "napcat-run.log"
        first.write_text("old"); second.write_text("new")
        os.utime(first, (100, 100)); os.utime(second, (200, 200))
        self.assertEqual(watch.napcat_log(self.root), second)

    def test_expired_login_requires_scan_and_ws_start_does_not_clear(self):
        self.assertTrue(watch.scan_required_in([
            "[2026-11-05 17:00:00] 快速登录错误：登录态已失效，请重新登录。",
            "[2026-11-05 17:00:01] WebSocket反向服务已启动",
        ]))

    def test_message_body_does_not_create_scan_required(self):
        self.assertFalse(watch.scan_required_in([
            "[2026-11-05 17:00:00] 接收 <- 私聊 登录态已失效",
            "登录态已失效，请重新登录。",
        ]))

    def test_successful_login_or_received_message_clears_scan_requirement(self):
        for proof in ("QQ登录成功", "本账号数据/缓存目录", " 接收 <- 消息"):
            with self.subTest(proof=proof):
                self.assertFalse(watch.scan_required_in([
                    "[2026-11-05 17:00:00] 登录态已失效",
                    "[2026-11-05 17:00:01] " + proof,
                ]))

    def test_scan_required_skips_task_and_only_logs_once(self):
        log, run = self.auto_context(scan=True)
        with patch.object(watch.time, "time", side_effect=[1000, 1180, 1240]):
            for _ in range(3):
                watch.auto_relogin(self.root, "kicked")
        run.assert_not_called()
        log.assert_called_once()
        self.assertEqual(watch.REL["last"], 0)

    def test_task_uses_start_scheduled_task_without_msys_slash_flags(self):
        _, run = self.auto_context()
        with patch.object(watch.time, "time", side_effect=[1000, 1180]):
            watch.auto_relogin(self.root, "offline")
            watch.auto_relogin(self.root, "offline")
        command = run.call_args.args[0]
        self.assertIn("Start-ScheduledTask", command[-1])
        self.assertNotIn("/run", command)
        self.assertEqual(watch.REL["last"], 1180)

    def test_actual_restart_cooldown_blocks_task_even_after_watch_restart(self):
        _, run = self.auto_context(delay=500)
        with patch.object(watch.time, "time", side_effect=[1000, 1180]):
            watch.auto_relogin(self.root, "offline")
            watch.auto_relogin(self.root, "offline")
        run.assert_not_called()

    def test_failed_task_not_recorded_as_success(self):
        _, run = self.auto_context(returncode=1)
        with patch.object(watch.time, "time", side_effect=[1000, 1180]):
            watch.auto_relogin(self.root, "offline")
            watch.auto_relogin(self.root, "offline")
        run.assert_called_once()
        self.assertEqual(watch.REL["last"], 0)

    def test_persistent_retry_deadline_and_backwards_clock(self):
        path = self.root / "logs" / "qq-relogin-attempt.json"
        path.parent.mkdir()
        path.write_text('{"at":1000}', encoding="utf-8")
        self.assertEqual(watch.automatic_retry_delay(self.root, 1899), 1)
        self.assertEqual(watch.automatic_retry_delay(self.root, 1900), 0)
        self.assertEqual(watch.automatic_retry_delay(self.root, 900), 900)

    def test_missing_record_allows_one_attempt_but_corrupt_record_waits(self):
        self.assertEqual(watch.automatic_retry_delay(self.root, 1000), 0)
        path = self.root / "logs" / "qq-relogin-attempt.json"
        path.parent.mkdir()
        for value in ('bad', '{}', '{"at":"NaN"}', '{"at":-1}'):
            path.write_text(value, encoding="utf-8")
            self.assertEqual(watch.automatic_retry_delay(self.root, 1000), 900)

    def test_diagnostics_has_safe_booleans_only(self):
        with patch.object(watch, "napcat_log", return_value=Path("fake")), patch.object(watch, "tail", return_value=["登录态已失效"]), patch.object(watch, "qq_logged_in", return_value=None), patch.object(watch, "automatic_retry_delay", return_value=800):
            result = watch.relogin_diagnostics(self.root)
        self.assertEqual(result, {"log_found": True, "needs_scan": True, "login_info": None, "automatic_retry_wait": 800})

    def test_once_includes_diagnostics_without_task_or_notification(self):
        with patch.object(sys, "argv", ["qq_watch.py", "--dir", str(self.root), "--once", "--ignore-relogin"]), patch.object(watch, "is_cloud", return_value=False), patch.object(watch, "status_of", return_value=("offline", "test")), patch.object(watch, "relogin_diagnostics", return_value={"needs_scan": True}), patch.object(watch, "auto_relogin") as auto, patch.object(watch, "toast") as toast, patch.object(watch, "write_state") as write:
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(watch.main(), 0)
        self.assertEqual(json.loads(out.getvalue())["needs_scan"], True)
        auto.assert_not_called(); toast.assert_not_called(); write.assert_not_called()


if __name__ == "__main__":
    unittest.main()
