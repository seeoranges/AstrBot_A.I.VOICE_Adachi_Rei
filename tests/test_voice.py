"""Offline regression tests. No AstrBot startup, secrets, network, or QQ sends."""

import asyncio
import importlib.util
import json
import math
import os
from pathlib import Path
import selectors
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import AsyncMock, MagicMock, patch
import wave


ROOT = Path(__file__).resolve().parents[1]


class OfflineSelector(selectors.BaseSelector):
    """No real I/O is allowed in these fully mocked regression tests."""

    def register(self, fileobj, events, data=None):
        raise AssertionError("Unexpected real I/O in offline test")

    def unregister(self, fileobj):
        raise KeyError(fileobj)

    def select(self, timeout=None):
        time.sleep(0.01 if timeout is None else max(0, timeout))
        return []

    def get_map(self):
        return {}


class OfflineLoop(asyncio.SelectorEventLoop):
    # Windows' fallback socketpair can hang inside this execution sandbox.
    # These tests need only timers/tasks, and mock every subprocess and HTTP call.
    def __init__(self):
        super().__init__(selector=OfflineSelector())

    def _make_self_pipe(self):
        pass

    def _close_self_pipe(self):
        pass

    def _write_to_self(self):
        pass


class OfflineAsyncCase(unittest.IsolatedAsyncioTestCase):
    def _setupAsyncioRunner(self):
        self._asyncioRunner = asyncio.Runner(debug=True, loop_factory=OfflineLoop)


class Plain:
    def __init__(self, text):
        self.text = text


class Record:
    def __init__(self, **kwargs):
        self.__dict__.update(kwargs)


class MessageChain:
    def __init__(self, chain):
        self.chain = chain


class Star:
    def __init__(self, context):
        self.context = context


class TTSProvider:
    def __init__(self, provider_config, provider_settings):
        self.provider_config = provider_config
        self.provider_settings = provider_settings


def load_plugin():
    """Replace only imports; execute the real reviewed functions and classes."""
    modules = {}

    def stub(name, **attrs):
        module = types.ModuleType(name)
        module.__dict__.update(attrs)
        modules[name] = module
        return module

    logger = MagicMock()
    stub("aiohttp", ClientTimeout=MagicMock(), ClientSession=MagicMock())
    stub("astrbot", logger=logger)
    stub("astrbot.api")
    stub(
        "astrbot.api.event",
        AstrMessageEvent=object,
        filter=types.SimpleNamespace(after_message_sent=lambda **kw: lambda f: f),
    )
    stub("astrbot.api.message_components", Plain=Plain, Record=Record)
    stub("astrbot.api.star", Context=object, Star=Star)
    stub("astrbot.core")
    stub("astrbot.core.message")
    stub("astrbot.core.message.message_event_result", MessageChain=MessageChain)
    register = stub(
        "astrbot.core.provider.register",
        provider_cls_map={},
        provider_registry=[],
        register_provider_adapter=lambda *a, **kw: lambda cls: cls,
    )
    stub("astrbot.core.provider", register=register)
    stub(
        "astrbot.core.provider.entities",
        ProviderType=types.SimpleNamespace(TEXT_TO_SPEECH="text_to_speech"),
    )
    stub("astrbot.core.provider.provider", TTSProvider=TTSProvider)
    stub("astrbot.core.utils")
    stub("astrbot.core.utils.astrbot_path", get_astrbot_temp_path=tempfile.gettempdir)
    spec = importlib.util.spec_from_file_location("_adachi_offline_tests", ROOT / "main.py")
    module = importlib.util.module_from_spec(spec)
    # Dataclasses, if used, look their module up during class creation.
    modules[spec.name] = module
    with patch.dict(sys.modules, modules):
        spec.loader.exec_module(module)
    return module


voice = load_plugin()


def temporary_case_dir(test):
    # Keep test writes in the writable workspace; some Windows sandboxes expose
    # a temporary directory that can be created but not subsequently written.
    temp = tempfile.TemporaryDirectory(prefix=".voice-test-", dir=str(ROOT))
    if Path(temp.name).resolve().parent != ROOT.resolve():
        raise AssertionError("Test cleanup target escaped the review workspace")
    test.addCleanup(temp.cleanup)
    return temp


def write_wav(path):
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(24000)
        wav.writeframes(b"\0\0" * 240)


class FakeWriter:
    def __init__(self, process):
        self.process = process
        self.closed = False

    def write(self, data):
        self.process.requests.append(json.loads(data.decode("utf-8")))

    async def drain(self):
        pass

    def close(self):
        self.closed = True
        if not self.process.ignore_close:
            self.process.returncode = 0
            self.process.done.set()
            self.process.blocked.set()

    async def wait_closed(self):
        pass


class FakeBridgeProcess:
    """JSON lines bridge whose reply, timeout and shutdown are deterministic."""

    def __init__(self, mode="ok", ignore_close=False):
        self.mode = mode
        self.ignore_close = ignore_close
        self.returncode = None
        self.requests = []
        self.started = asyncio.Event()
        self.done = asyncio.Event()
        self.blocked = asyncio.Event()
        self.killed = False
        self.stdin = FakeWriter(self)
        self.stdout = types.SimpleNamespace(readline=self.readline)

    async def readline(self):
        self.started.set()
        if self.mode == "hang":
            await self.blocked.wait()
            if self.returncode is not None:
                return b""
        if self.mode == "eof":
            return b""
        if self.mode == "bad_json":
            return b"not json\n"
        req = self.requests[-1]
        write_wav(req["out"])
        response = {
            "id": req.get("id"),
            "ok": True,
            "out": req["out"],
            "bytes": os.path.getsize(req["out"]),
        }
        if self.mode == "wrong_id":
            response["id"] = "another-request"
        if self.mode == "wrong_path":
            response["out"] = req["out"] + ".other"
        return (json.dumps(response, ensure_ascii=False) + "\n").encode("utf-8")

    async def wait(self):
        await self.done.wait()
        return self.returncode

    def kill(self):
        self.killed = True
        self.returncode = -9
        self.done.set()
        self.blocked.set()

    def terminate(self):
        self.kill()


class FakeTranscoder:
    def __init__(self, out, mode="ok"):
        self.out = Path(out)
        self.mode = mode
        self.returncode = None
        self.started = asyncio.Event()
        self.done = asyncio.Event()
        self.killed = False

    async def communicate(self):
        self.started.set()
        if self.mode == "hang" and not self.killed:
            await self.done.wait()
        if self.killed:
            return b"", b"terminated"
        self.out.write_bytes(b"fake mp3" if self.mode == "ok" else b"")
        self.returncode = 0 if self.mode == "ok" else 1
        self.done.set()
        return b"", b"encode failed" if self.mode != "ok" else b""

    def kill(self):
        self.killed = True
        self.returncode = -9
        self.done.set()

    def terminate(self):
        self.kill()

    async def wait(self):
        await self.done.wait()
        return self.returncode


class BridgeTests(OfflineAsyncCase):
    async def asyncSetUp(self):
        self.temp = temporary_case_dir(self)
        self.path_patch = patch.object(voice, "get_astrbot_temp_path", return_value=self.temp.name)
        self.path_patch.start()
        self.addCleanup(self.path_patch.stop)
        self.bridge = voice.VoiceBridge()
        self.addAsyncCleanup(self.bridge.close)

    async def test_success_correlates_requests_and_uses_unique_paths(self):
        proc = FakeBridgeProcess()
        with patch.object(voice.asyncio, "create_subprocess_exec", AsyncMock(return_value=proc)):
            first, second = await asyncio.gather(
                self.bridge.say("いるよ"), self.bridge.say("おやすみ")
            )
        self.assertNotEqual(first, second)
        self.assertEqual(len(proc.requests), 2)
        self.assertTrue(proc.requests[0].get("id"))
        self.assertNotEqual(proc.requests[0]["id"], proc.requests[1]["id"])
        self.assertTrue(Path(first).is_file())
        self.assertTrue(Path(second).is_file())

    async def test_protocol_errors_reset_bridge(self):
        for mode in ("wrong_id", "wrong_path", "bad_json", "eof"):
            with self.subTest(mode=mode):
                proc = FakeBridgeProcess(mode)
                with patch.object(voice.asyncio, "create_subprocess_exec", AsyncMock(return_value=proc)):
                    with self.assertRaises((RuntimeError, ValueError)):
                        await self.bridge.say("いるよ")
                self.assertIsNone(self.bridge.proc)
                self.assertIsNotNone(proc.returncode)

    async def test_timeout_resets_and_next_request_starts_fresh(self):
        stale = FakeBridgeProcess("hang")
        healthy = FakeBridgeProcess()
        spawn = AsyncMock(side_effect=[stale, healthy])
        with patch.object(voice, "BRIDGE_TIMEOUT", 0.02), patch.object(
            voice.asyncio, "create_subprocess_exec", spawn
        ):
            with self.assertRaises((TimeoutError, RuntimeError)):
                await self.bridge.say("前の台詞")
            self.assertIsNone(self.bridge.proc)
            path = await self.bridge.say("次の台詞")
        self.assertEqual(spawn.await_count, 2)
        self.assertTrue(Path(path).is_file())
        self.assertIsNotNone(stale.returncode)

    async def test_cancelled_read_resets_bridge(self):
        proc = FakeBridgeProcess("hang")
        with patch.object(voice.asyncio, "create_subprocess_exec", AsyncMock(return_value=proc)):
            task = asyncio.create_task(self.bridge.say("いるよ"))
            await asyncio.wait_for(proc.started.wait(), 1)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        self.assertIsNone(self.bridge.proc)
        self.assertIsNotNone(proc.returncode)

    async def test_close_forces_unresponsive_process_to_exit(self):
        proc = FakeBridgeProcess(ignore_close=True)
        self.bridge.proc = proc
        await asyncio.wait_for(self.bridge.close(), timeout=7)
        self.assertIsNone(self.bridge.proc)
        self.assertTrue(proc.killed)

    async def test_close_during_start_does_not_leave_late_process_alive(self):
        proc = FakeBridgeProcess()
        starting = asyncio.Event()
        release_start = asyncio.Event()

        async def spawn(*args, **kwargs):
            starting.set()
            await release_start.wait()
            return proc

        with patch.object(voice.asyncio, "create_subprocess_exec", spawn):
            task = asyncio.create_task(self.bridge.say("いるよ"))
            await asyncio.wait_for(starting.wait(), 1)
            await self.bridge.close()
            release_start.set()
            with self.assertRaises(RuntimeError):
                await task
        self.assertIsNone(self.bridge.proc)
        self.assertIsNotNone(proc.returncode)

    async def test_close_interrupts_active_read_and_rejects_new_work(self):
        proc = FakeBridgeProcess("hang")
        with patch.object(voice.asyncio, "create_subprocess_exec", AsyncMock(return_value=proc)):
            task = asyncio.create_task(self.bridge.say("いるよ"))
            await asyncio.wait_for(proc.started.wait(), 1)
            await self.bridge.close()
            with self.assertRaises(RuntimeError):
                await asyncio.wait_for(task, 1)
            with self.assertRaises(RuntimeError):
                await self.bridge.say("次の台詞")
        self.assertIsNone(self.bridge.proc)


class RewriteTests(unittest.TestCase):
    def test_valid_json_and_default_parameters(self):
        self.assertEqual(voice._parse_rewrite('{"ja":"いるよ"}'), ("いるよ", 1.0, 1.0))

    def test_numeric_parameters_are_bounded(self):
        ja, speed, pitch = voice._parse_rewrite('{"ja":"いるよ","speed":20,"pitch":-5}')
        self.assertEqual(ja, "いるよ")
        self.assertGreaterEqual(speed, 0.85)
        self.assertLessEqual(speed, 1.3)
        self.assertGreaterEqual(pitch, 0.9)
        self.assertLessEqual(pitch, 1.15)

    def test_invalid_response_shapes_are_rejected(self):
        for content in ('[]', 'null', '"いるよ"', '{"ja":{}}', '{"ja":42}', '{"ja":"  "}', 'not json'):
            with self.subTest(content=content):
                with self.assertRaises((RuntimeError, ValueError, TypeError)):
                    voice._parse_rewrite(content)

    def test_nonfinite_and_invalid_parameters_never_escape_to_bridge(self):
        for value in ('"NaN"', '"Infinity"', '[]', '{}', 'true', '"oops"'):
            with self.subTest(value=value):
                try:
                    _, speed, pitch = voice._parse_rewrite(
                        '{"ja":"いるよ","speed":' + value + ',"pitch":' + value + '}'
                    )
                except (RuntimeError, ValueError, TypeError):
                    continue
                self.assertTrue(math.isfinite(speed))
                self.assertTrue(math.isfinite(pitch))
                self.assertGreaterEqual(speed, 0.85)
                self.assertLessEqual(speed, 1.3)
                self.assertGreaterEqual(pitch, 0.9)
                self.assertLessEqual(pitch, 1.15)

    def test_long_valid_rewrite_is_retained_in_full(self):
        text = "あ" * 450 + "。" + "い" * 450 + "。"
        self.assertEqual(voice._parse_rewrite(json.dumps({"ja": text})), (text, 1.0, 1.0))

    def test_abnormal_rewrite_size_and_unpaired_surrogate_are_rejected(self):
        for text in ("あ" * (voice.MAX_REWRITE_UNITS + 1), "\ud800"):
            with self.subTest(length=len(text)), self.assertRaises(RuntimeError):
                voice._parse_rewrite(json.dumps({"ja": text}))

    def test_split_prefers_sentence_boundary_and_preserves_every_character(self):
        text = "あ" * 350 + "。" + "い" * 100
        chunks = voice._split_japanese(text)
        self.assertEqual(chunks, ["あ" * 350 + "。", "い" * 100])
        self.assertEqual("".join(chunks), text)

    def test_split_uses_utf16_units_for_supplementary_japanese(self):
        text = "𠀋" * 201 + "、 " + "い" * 400 + "。"
        chunks = voice._split_japanese(text)
        self.assertEqual("".join(chunks), text)
        self.assertGreater(len(chunks), 1)
        self.assertTrue(all(0 < len(chunk.encode("utf-16-le")) // 2 <= 400 for chunk in chunks))
        self.assertEqual(len(chunks[0]), 200)

    def test_short_rewrite_keeps_single_input_unchanged(self):
        text = "いるよ。 ちゃんと聞いてるよ。"
        self.assertEqual(voice._split_japanese(text), [text])

    def test_split_falls_back_to_reading_pause_without_empty_chunks(self):
        text = "あ" * 300 + "、" + "い" * 200
        chunks = voice._split_japanese(text)
        self.assertEqual(chunks[0], "あ" * 300 + "、")
        self.assertEqual("".join(chunks), text)
        self.assertTrue(all(chunks))


def event_for(text="你好", sender="123456", private=True, platform="aiocqhttp"):
    result = types.SimpleNamespace(chain=[Plain(text)], is_llm_result=lambda: True)
    return types.SimpleNamespace(
        unified_msg_origin=f"test:{'FriendMessage' if private else 'GroupMessage'}:{sender}",
        is_private_chat=lambda: private,
        get_sender_id=lambda: sender,
        get_platform_name=lambda: platform,
        get_result=lambda: result,
    )


class EventTests(OfflineAsyncCase):
    def plugin(self):
        # Avoid __init__ reading the private owner file.
        plugin = object.__new__(voice.AdachiAIVoice)
        plugin.owner = "123456"
        plugin.context = types.SimpleNamespace(send_message=AsyncMock(return_value=True))
        plugin._speech_lock = asyncio.Lock()
        plugin._stopping = False
        plugin.config = {"prewarm": False, "latest_only": False}
        return plugin

    async def test_owner_match_requires_exact_qq_private_and_platform(self):
        plugin = self.plugin()
        self.assertTrue(plugin._is_owner_friend(event_for()))
        self.assertFalse(plugin._is_owner_friend(event_for(sender="91234567")))
        self.assertFalse(plugin._is_owner_friend(event_for(private=False)))
        self.assertFalse(plugin._is_owner_friend(event_for(platform="webchat")))
        plugin.owner = ""
        self.assertFalse(plugin._is_owner_friend(event_for()))

    async def test_consecutive_replies_both_send_in_order(self):
        plugin = self.plugin()
        first_started = asyncio.Event()
        release_first = asyncio.Event()
        calls = []

        async def synthesize(text):
            calls.append(text)
            if text == "第一条":
                first_started.set()
                await release_first.wait()
            return text + ".mp3"

        with patch.object(voice, "synthesize", synthesize):
            first = asyncio.create_task(plugin.speak(event_for("第一条")))
            await asyncio.wait_for(first_started.wait(), 1)
            second = asyncio.create_task(plugin.speak(event_for("第二条")))
            await asyncio.sleep(0)
            self.assertEqual(calls, ["第一条"])
            release_first.set()
            await asyncio.gather(first, second)
        self.assertEqual(calls, ["第一条", "第二条"])
        self.assertEqual(plugin.context.send_message.await_count, 2)
        sent_texts = [c.kwargs["message_chain"].chain[0].text for c in plugin.context.send_message.await_args_list]
        self.assertEqual(sent_texts, ["第一条", "第二条"])

    async def test_failed_voice_does_not_block_next_reply(self):
        plugin = self.plugin()
        synth = AsyncMock(side_effect=[RuntimeError("offline"), "second.mp3"])
        with patch.object(voice, "synthesize", synth):
            await plugin.speak(event_for("第一条"))
            await plugin.speak(event_for("第二条"))
        self.assertEqual(synth.await_count, 2)
        self.assertEqual(plugin.context.send_message.await_count, 1)


class TranscodeTests(OfflineAsyncCase):
    async def asyncSetUp(self):
        self.temp = temporary_case_dir(self)
        self.wav = Path(self.temp.name) / "test.wav"
        write_wav(self.wav)
        self.mp3 = self.wav.with_suffix(".mp3")
        voice._MP3_CACHE.clear()
        self.bridge = types.SimpleNamespace(say=AsyncMock(return_value=str(self.wav)))
        self.patches = [
            patch.object(voice, "get_astrbot_temp_path", return_value=self.temp.name),
            patch.object(voice, "BRIDGE", self.bridge),
            patch.object(voice, "_to_japanese", AsyncMock(return_value=("いるよ", 1.0, 1.0))),
        ]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)

    async def test_success_removes_wav_and_retains_usable_mp3(self):
        proc = FakeTranscoder(self.mp3)
        with patch.object(voice.asyncio, "create_subprocess_exec", AsyncMock(return_value=proc)):
            path = await voice.synthesize("你好")
        self.assertEqual(Path(path), self.mp3)
        self.assertFalse(self.wav.exists())
        self.assertGreater(self.mp3.stat().st_size, 0)

    async def test_failure_removes_wav_and_partial_mp3(self):
        proc = FakeTranscoder(self.mp3, "fail")
        with patch.object(voice.asyncio, "create_subprocess_exec", AsyncMock(return_value=proc)):
            with self.assertRaises(RuntimeError):
                await voice.synthesize("你好")
        self.assertFalse(self.wav.exists())
        self.assertFalse(self.mp3.exists())

    async def test_failed_process_start_still_removes_wav(self):
        with patch.object(
            voice.asyncio, "create_subprocess_exec", AsyncMock(side_effect=OSError("missing ffmpeg"))
        ):
            with self.assertRaises((OSError, RuntimeError)):
                await voice.synthesize("你好")
        self.assertFalse(self.wav.exists())
        self.assertFalse(self.mp3.exists())

    async def test_timeout_kills_transcoder_and_removes_files(self):
        proc = FakeTranscoder(self.mp3, "hang")
        with patch.object(voice, "TRANSCODE_TIMEOUT", 0.02), patch.object(
            voice.asyncio, "create_subprocess_exec", AsyncMock(return_value=proc)
        ):
            with self.assertRaises((TimeoutError, RuntimeError)):
                await voice.synthesize("你好")
        self.assertTrue(proc.killed)
        self.assertFalse(self.wav.exists())
        self.assertFalse(self.mp3.exists())

    async def test_cancel_kills_transcoder_and_removes_files(self):
        proc = FakeTranscoder(self.mp3, "hang")
        with patch.object(voice.asyncio, "create_subprocess_exec", AsyncMock(return_value=proc)):
            task = asyncio.create_task(voice.synthesize("你好"))
            await asyncio.wait_for(proc.started.wait(), 1)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        self.assertTrue(proc.killed)
        self.assertFalse(self.wav.exists())
        self.assertFalse(self.mp3.exists())

    def long_inputs(self):
        text = "あ" * 350 + "。" + "い" * 350 + "。" + "う" * 100
        chunks = voice._split_japanese(text)
        paths = [self.wav] + [self.wav.with_name(f"part_{index}.wav") for index in range(1, len(chunks))]
        for path in paths:
            write_wav(path)
        return text, chunks, paths

    async def test_long_rewrite_synthesizes_ordered_parts_to_one_mp3(self):
        text, chunks, paths = self.long_inputs()
        self.bridge.say.side_effect = [str(path) for path in paths]
        proc = FakeTranscoder(self.mp3)
        spawn = AsyncMock(return_value=proc)
        with patch.object(voice, "_to_japanese", AsyncMock(return_value=(text, 1.0, 1.0))), patch.object(
            voice.asyncio, "create_subprocess_exec", spawn
        ):
            result = await voice.synthesize("长回复")
        self.assertEqual(result, str(self.mp3))
        self.assertEqual([call.args[0] for call in self.bridge.say.await_args_list], chunks)
        args = spawn.await_args.args
        self.assertEqual([args[index + 1] for index, arg in enumerate(args) if arg == "-i"], [str(path) for path in paths])
        self.assertIn(f"concat=n={len(paths)}:v=0:a=1[out]", args[args.index("-filter_complex") + 1])
        self.assertTrue(all(not path.exists() for path in paths))
        self.assertGreater(self.mp3.stat().st_size, 0)

    async def test_failure_midway_through_parts_removes_completed_wavs(self):
        text = "あ" * 401
        self.bridge.say.side_effect = [str(self.wav), RuntimeError("second part failed")]
        spawn = AsyncMock()
        with patch.object(voice, "_to_japanese", AsyncMock(return_value=(text, 1.0, 1.0))), patch.object(
            voice.asyncio, "create_subprocess_exec", spawn
        ):
            with self.assertRaises(RuntimeError):
                await voice.synthesize("长回复")
        self.assertFalse(self.wav.exists())
        self.assertFalse(self.mp3.exists())
        spawn.assert_not_awaited()

    async def test_cancel_midway_through_parts_removes_completed_wavs(self):
        started = asyncio.Event()
        calls = 0

        async def say(*args):
            nonlocal calls
            calls += 1
            if calls == 1:
                return str(self.wav)
            started.set()
            await asyncio.Future()

        with patch.object(voice, "_to_japanese", AsyncMock(return_value=("あ" * 401, 1.0, 1.0))), patch.object(
            self.bridge, "say", say
        ):
            task = asyncio.create_task(voice.synthesize("长回复"))
            await asyncio.wait_for(started.wait(), 1)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        self.assertFalse(self.wav.exists())
        self.assertFalse(self.mp3.exists())

    async def test_long_transcode_failure_removes_every_part(self):
        text, _, paths = self.long_inputs()
        self.bridge.say.side_effect = [str(path) for path in paths]
        proc = FakeTranscoder(self.mp3, "fail")
        with patch.object(voice, "_to_japanese", AsyncMock(return_value=(text, 1.0, 1.0))), patch.object(
            voice.asyncio, "create_subprocess_exec", AsyncMock(return_value=proc)
        ):
            with self.assertRaises(RuntimeError):
                await voice.synthesize("长回复")
        self.assertTrue(all(not path.exists() for path in paths))
        self.assertFalse(self.mp3.exists())

    async def test_long_transcode_timeout_removes_every_part(self):
        text, _, paths = self.long_inputs()
        self.bridge.say.side_effect = [str(path) for path in paths]
        proc = FakeTranscoder(self.mp3, "hang")
        with patch.object(voice, "_to_japanese", AsyncMock(return_value=(text, 1.0, 1.0))), patch.object(
            voice, "TRANSCODE_TIMEOUT", 0.02
        ), patch.object(voice.asyncio, "create_subprocess_exec", AsyncMock(return_value=proc)):
            with self.assertRaises(TimeoutError):
                await voice.synthesize("长回复")
        self.assertTrue(proc.killed)
        self.assertTrue(all(not path.exists() for path in paths))
        self.assertFalse(self.mp3.exists())


if __name__ == "__main__":
    unittest.main()
