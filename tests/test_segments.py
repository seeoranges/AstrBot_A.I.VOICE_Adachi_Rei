"""Offline contracts for segmented emotion speech; no editor, model or QQ I/O."""
import asyncio
import json
import math
from pathlib import Path
import types
import unittest
from unittest.mock import AsyncMock, MagicMock, patch

from test_voice import (
    FakeBridgeProcess, FakeTranscoder, OfflineAsyncCase, temporary_case_dir,
    voice, write_wav,
)


CONTROL_FIELDS = (
    "style", "pitch_range", "volume", "middle_pause", "long_pause", "sentence_pause",
)


def encoded(items):
    return json.dumps({"segments": items}, ensure_ascii=False)


def parsed(items):
    return voice._parse_segments(encoded(items))


def rewritten(items):
    full, segments = parsed(items)
    first = segments[0]
    controls = {key: first[key] for key in CONTROL_FIELDS}
    return full, first["speed"], first["pitch"], controls, segments


class SegmentParserTests(unittest.TestCase):
    def test_list_rows_are_single_sentences_even_when_model_returns_a_paragraph(self):
        original = '今日は、聞いているよ。ここで待っているからね！本当？'
        full, segments = parsed([{'ja': original, 'emotion': 'calm'}])
        self.assertEqual(full, original)
        self.assertEqual(len(segments), 3)
        for row in segments:
            self.assertFalse(any(c in '。｡！？!?' for c in row['text'][:-1]))
            self.assertEqual(row['emotion'], 'calm')

    def test_quotes_and_repeated_terminal_marks_do_not_create_a_modal_warning(self):
        full, segments = parsed([{'ja': '「本当！？」そうなんだ。', 'emotion': 'surprised'}])
        self.assertEqual(full, '本当？そうなんだ。')
        self.assertEqual([s['text'] for s in segments], ['本当？', 'そうなんだ。'])

    def test_many_sentences_keep_every_word_for_the_legacy_fallback(self):
        original = '今日は話を聞くよ。' * 8
        full, segments = parsed([{'ja': original, 'emotion': 'normal'}])
        self.assertEqual(full, original)
        self.assertEqual(len(segments), 8)

    def test_each_emotion_keeps_its_text_and_all_required_controls(self):
        full, segments = parsed([
            {"ja": "ねえ、聞いてよ！", "emotion": "excited"},
            {"ja": "……ちゃんと聞いてる？", "emotion": "normal"},
        ])
        self.assertEqual(full, "ねえ、聞いてよ！……ちゃんと聞いてる？")
        self.assertEqual("".join(item["text"] for item in segments), full)
        self.assertEqual([item["emotion"] for item in segments], ["excited", "normal"])
        for item in segments:
            for name in ("speed", "pitch", *CONTROL_FIELDS):
                self.assertTrue(math.isfinite(item[name]), name)
            self.assertGreaterEqual(item["style"], 0)
            self.assertLessEqual(item["style"], 1)
            self.assertGreaterEqual(item["sentence_pause"], item["long_pause"])

    def test_unknown_emotion_uses_normal_profile(self):
        _, unknown = parsed([{"ja": "そうなんだ。", "emotion": "not-a-real-emotion"}])
        _, normal = parsed([{"ja": "そうなんだ。", "emotion": "normal"}])
        self.assertEqual(unknown, normal)

    def test_model_cannot_override_the_local_profile(self):
        _, normal = parsed([{"ja": "いるよ。", "emotion": "normal"}])
        malicious = {"ja": "いるよ。", "emotion": "normal", "style": -999,
                     "speed": 999, "pitch": 999, "volume": 999,
                     "pitch_range": 999, "long_pause": 1, "sentence_pause": 0}
        try:
            _, actual = parsed([malicious])
        except (ValueError, RuntimeError, TypeError):
            return  # Rejecting unrecognized fields is also safe.
        self.assertEqual(actual, normal)

    def test_non_object_and_empty_segment_structures_fail_closed(self):
        for content in ("not-json", "[]", "null", '{}', '{"segments":null}',
                        '{"segments":{}}', '{"segments":[]}', '{"segments":[null]}',
                        '{"segments":["日語"]}'):
            with self.subTest(content=content), self.assertRaises((ValueError, RuntimeError, TypeError)):
                voice._parse_segments(content)

    def test_invalid_text_or_emotion_shape_fails_closed(self):
        for item in ({"emotion": "normal"}, {"ja": ""}, {"ja": " \t\n "},
                     {"ja": 3}, {"ja": []}, {"ja": "いるよ", "emotion": []},
                     {"ja": "いるよ", "emotion": {}}, {"ja": "いるよ", "emotion": True}):
            with self.subTest(item=item), self.assertRaises((ValueError, RuntimeError, TypeError)):
                parsed([item])

    def test_bad_later_segment_does_not_keep_a_partial_reply(self):
        with self.assertRaises((ValueError, RuntimeError, TypeError)):
            parsed([{"ja": "最初の文章。", "emotion": "normal"}, {"ja": []}])

    def test_long_segment_splits_by_utf16_without_losing_supplementary_characters(self):
        original = "𠀋" * 201 + "、" + "い" * 401 + "。"
        full, segments = parsed([{"ja": original, "emotion": "excited"}])
        self.assertEqual(full, original)
        self.assertEqual("".join(item["text"] for item in segments), original)
        self.assertGreater(len(segments), 1)
        self.assertTrue(all(0 < len(item["text"].encode("utf-16-le")) // 2 <= 400
                            for item in segments))
        self.assertTrue(all(item["emotion"] == "excited" for item in segments))

    def test_six_rows_of_400_units_are_not_truncated(self):
        original = [{"ja": chr(0x3042 + i) * 400, "emotion": "normal"} for i in range(6)]
        full, segments = parsed(original)
        self.assertEqual(full, "".join(item["ja"] for item in original))
        self.assertEqual(len(segments), 6)

    def test_4000_unit_legacy_capacity_is_retained_beyond_six_rows(self):
        original = "あ" * 3999 + "。"
        full, segments = parsed([{"ja": original, "emotion": "normal"}])
        self.assertEqual(full, original)
        self.assertEqual("".join(item["text"] for item in segments), original)
        self.assertGreater(len(segments), 6)

    def test_total_size_and_invalid_unicode_are_rejected_before_synthesis(self):
        for items in ([{"ja": "あ" * 4001}], [{"ja": "あ" * 2001}, {"ja": "い" * 2000}],
                      [{"ja": "\ud800"}]):
            with self.subTest(lengths=[len(item["ja"]) for item in items]), self.assertRaises((ValueError, RuntimeError, UnicodeError)):
                parsed(items)


class SegmentSynthesisTests(OfflineAsyncCase):
    async def asyncSetUp(self):
        self.temp = temporary_case_dir(self)
        self.counter = 0
        self.enabled = True
        self.wave_paths = []
        self.transcoders = []
        self.plan = rewritten([
            {"ja": "すごい！", "emotion": "excited"},
            {"ja": "本当なの？", "emotion": "normal"},
        ])
        self.bridge = types.SimpleNamespace(
            say_segments=AsyncMock(side_effect=self.make_audio),
            say=AsyncMock(side_effect=self.make_audio), last_mode="list",
        )
        self.rewrite = AsyncMock(side_effect=lambda text: self.plan)
        self.spawn = AsyncMock(side_effect=self.transcode)
        active = types.SimpleNamespace(setting=lambda name, default: self.enabled if name == "emotion_segments" else default)
        self.patches = [
            patch.object(voice, "get_astrbot_temp_path", return_value=self.temp.name),
            patch.object(voice, "BRIDGE", self.bridge),
            patch.object(voice, "_to_japanese", self.rewrite),
            patch.object(voice, "_ACTIVE_PLUGIN", active),
            patch.object(voice.asyncio, "create_subprocess_exec", self.spawn),
        ]
        for patcher in self.patches:
            patcher.start()
            self.addCleanup(patcher.stop)
        voice._JP_CACHE.clear()
        voice._MP3_CACHE.clear()

    async def make_audio(self, *args, **kwargs):
        self.counter += 1
        path = Path(self.temp.name) / f"part-{self.counter}.wav"
        write_wav(path)
        self.wave_paths.append(path)
        return str(path)

    async def transcode(self, *args, **kwargs):
        proc = FakeTranscoder(args[-1])
        self.transcoders.append(proc)
        return proc

    async def test_multiple_emotions_use_one_bridge_export_and_one_transcode(self):
        result = await voice.synthesize("同一条中文")
        self.bridge.say_segments.assert_awaited_once()
        self.bridge.say.assert_not_awaited()
        call = self.bridge.say_segments.await_args
        self.assertEqual(call.args[0], self.plan[4])
        self.assertEqual(call.kwargs["text"], self.plan[0])
        self.assertEqual(self.spawn.await_count, 1)
        args = self.spawn.await_args.args
        self.assertEqual(args.count("-i"), 1)
        self.assertNotIn("-filter_complex", args)
        self.assertTrue(Path(result).is_file())
        self.assertTrue(all(not path.exists() for path in self.wave_paths))

    async def test_more_than_six_rows_use_complete_ordered_legacy_fallback(self):
        self.plan = rewritten([{"ja": "あ" * 3999 + "。", "emotion": "normal"}])
        result = await voice.synthesize("长回复")
        self.bridge.say_segments.assert_not_awaited()
        calls = [call.args[0] for call in self.bridge.say.await_args_list]
        self.assertEqual("".join(calls), self.plan[0])
        self.assertTrue(all(len(text.encode("utf-16-le")) // 2 <= 400 for text in calls))
        self.assertTrue(Path(result).is_file())

    async def test_disabled_segment_setting_keeps_legacy_path(self):
        self.enabled = False
        await voice.synthesize("关闭情绪分段")
        self.bridge.say_segments.assert_not_awaited()
        self.assertEqual("".join(call.args[0] for call in self.bridge.say.await_args_list), self.plan[0])

    async def test_list_failure_falls_back_once_without_losing_the_reply(self):
        self.bridge.say_segments.side_effect = RuntimeError("list unavailable")
        result = await voice.synthesize("列表失败")
        self.bridge.say_segments.assert_awaited_once()
        self.assertEqual("".join(call.args[0] for call in self.bridge.say.await_args_list), self.plan[0])
        self.assertTrue(Path(result).is_file())

    async def test_bridge_internal_fallback_is_not_cached_as_successful_list_audio(self):
        self.bridge.last_mode = "single_fallback"
        first = await voice.synthesize("桥内部降级")
        second = await voice.synthesize("桥内部降级")
        self.assertNotEqual(first, second)
        self.assertEqual(self.bridge.say_segments.await_count, 2)
        self.bridge.say.assert_not_awaited()

    async def test_safe_fallback_does_not_hide_list_recovery_on_the_next_reply(self):
        attempts = 0

        async def recovering(*args, **kwargs):
            nonlocal attempts
            attempts += 1
            if attempts == 1:
                raise voice.BridgeError("offline list failure", "list_unavailable")
            return await self.make_audio(*args, **kwargs)

        self.bridge.say_segments.side_effect = recovering
        degraded = await voice.synthesize("列表稍后恢复")
        recovered = await voice.synthesize("列表稍后恢复")
        cached = await voice.synthesize("列表稍后恢复")
        self.assertNotEqual(degraded, recovered)
        self.assertEqual(recovered, cached)
        self.assertEqual(self.bridge.say_segments.await_count, 2)
        self.assertEqual(self.bridge.say.await_count, 1)

    async def test_nonrecoverable_bridge_error_never_attempts_legacy_export(self):
        self.bridge.say_segments.side_effect = voice.BridgeError("preset collision", "preset_name_collision")
        with self.assertRaises(voice.BridgeError):
            await voice.synthesize("预设发生冲突")
        self.bridge.say.assert_not_awaited()
        self.spawn.assert_not_awaited()

    async def test_list_cancellation_never_starts_fallback_or_transcoder(self):
        self.bridge.say_segments.side_effect = asyncio.CancelledError()
        with self.assertRaises(asyncio.CancelledError):
            await voice.synthesize("取消")
        self.bridge.say.assert_not_awaited()
        self.spawn.assert_not_awaited()

    async def test_transcode_failure_cleans_list_wav_and_partial_mp3(self):
        async def failing(*args, **kwargs):
            proc = FakeTranscoder(args[-1], "fail")
            self.transcoders.append(proc)
            return proc
        self.spawn.side_effect = failing
        with self.assertRaises(RuntimeError):
            await voice.synthesize("转码失败")
        self.assertTrue(all(not path.exists() for path in self.wave_paths))
        self.assertTrue(all(not proc.out.exists() for proc in self.transcoders))
        self.bridge.say.assert_not_awaited()

    async def test_identical_plan_reuses_audio_but_changed_emotion_does_not(self):
        first = await voice.synthesize("相同中文")
        cached = await voice.synthesize("相同中文")
        self.assertEqual(first, cached)
        self.assertEqual(self.bridge.say_segments.await_count, 1)
        self.plan = rewritten([
            {"ja": "すごい！", "emotion": "normal"},
            {"ja": "本当なの？", "emotion": "normal"},
        ])
        changed = await voice.synthesize("相同中文")
        self.assertNotEqual(first, changed)
        self.assertEqual(self.bridge.say_segments.await_count, 2)

    async def test_changed_actual_parameters_cannot_hit_previous_audio(self):
        first = await voice.synthesize("相同中文")
        changed = [dict(item) for item in self.plan[4]]
        changed[1]["style"] = max(0, changed[1]["style"] - 0.05)
        self.plan = (*self.plan[:4], changed)
        second = await voice.synthesize("相同中文")
        self.assertNotEqual(first, second)
        self.assertEqual(self.bridge.say_segments.await_count, 2)

    async def test_schema_and_profile_versions_invalidate_audio(self):
        await voice.synthesize("相同中文")
        for name in ("SCHEMA_VERSION", "PROFILE_VERSION"):
            with self.subTest(version=name), patch.object(voice, name, str(getattr(voice, name)) + "-changed"):
                await voice.synthesize("相同中文")
        self.assertEqual(self.bridge.say_segments.await_count, 3)

    async def test_setting_change_cannot_reuse_cached_list_audio(self):
        first = await voice.synthesize("相同中文")
        self.enabled = False
        second = await voice.synthesize("相同中文")
        self.assertNotEqual(first, second)
        self.assertGreater(self.bridge.say.await_count, 0)


class JsonResponse:
    status = 200

    def __init__(self, content):
        self.content = content

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        return False

    async def json(self):
        return {"choices": [{"message": {"content": self.content}}]}


class RewriteCompatibilityTests(OfflineAsyncCase):
    async def asyncSetUp(self):
        voice._JP_CACHE.clear()
        self.enabled = True
        self.session = types.SimpleNamespace(closed=False, post=MagicMock())
        active = types.SimpleNamespace(setting=lambda name, default: self.enabled if name == "emotion_segments" else default)
        for patcher in (
            patch.object(voice, "_HTTP_SESSION", self.session),
            patch.object(voice, "_read", return_value="offline-test-key"),
            patch.object(voice, "_ACTIVE_PLUGIN", active),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)

    async def test_legacy_model_json_keeps_four_value_contract(self):
        self.session.post.return_value = JsonResponse('{"ja":"いるよ。","speed":1.0,"pitch":1.0}')
        result = await voice._to_japanese("旧格式")
        self.assertEqual(len(result), 4)
        self.assertEqual(result[:3], ("いるよ。", 1.0, 1.0))

    async def test_segment_model_json_returns_full_text_and_normalized_segments(self):
        self.session.post.return_value = JsonResponse(encoded([
            {"ja": "すごい！", "emotion": "excited"},
            {"ja": "そうなの？", "emotion": "normal"},
        ]))
        result = await voice._to_japanese("新格式")
        self.assertEqual(len(result), 5)
        self.assertEqual(result[0], "すごい！そうなの？")
        self.assertEqual("".join(item["text"] for item in result[4]), result[0])
        self.assertNotIn("speed", result[3])
        self.assertNotIn("pitch", result[3])

    async def test_rewrite_cache_tracks_profile_version_and_feature_setting(self):
        self.session.post.return_value = JsonResponse(encoded([{"ja": "いるよ。", "emotion": "normal"}]))
        await voice._to_japanese("同じ中文")
        await voice._to_japanese("同じ中文")
        self.assertEqual(self.session.post.call_count, 1)
        with patch.object(voice, "PROFILE_VERSION", str(voice.PROFILE_VERSION) + "-changed"):
            await voice._to_japanese("同じ中文")
        self.assertEqual(self.session.post.call_count, 2)
        self.enabled = False
        self.session.post.return_value = JsonResponse('{"ja":"いるよ。"}')
        result = await voice._to_japanese("同じ中文")
        self.assertEqual(len(result), 4)
        self.assertEqual(self.session.post.call_count, 3)


class ModeBridgeProcess(FakeBridgeProcess):
    async def readline(self):
        response = json.loads(await super().readline())
        response["mode"] = "list"
        return (json.dumps(response, ensure_ascii=False) + "\n").encode("utf-8")


class SegmentBridgeTests(OfflineAsyncCase):
    async def asyncSetUp(self):
        self.temp = temporary_case_dir(self)
        self.bridge = voice.VoiceBridge()
        self.addAsyncCleanup(self.bridge.close)
        patcher = patch.object(voice, "get_astrbot_temp_path", return_value=self.temp.name)
        patcher.start()
        self.addCleanup(patcher.stop)

    async def test_segments_share_existing_correlated_single_connection_protocol(self):
        full, segments = parsed([{"ja": "そうなの？", "emotion": "normal"}])
        proc = ModeBridgeProcess()
        spawn = AsyncMock(return_value=proc)
        with patch.object(voice.asyncio, "create_subprocess_exec", spawn):
            first = await self.bridge.say_segments(segments, text=full)
            second = await self.bridge.say_segments(segments, text=full)
        self.assertEqual(spawn.await_count, 1)
        self.assertNotEqual(first, second)
        self.assertEqual(proc.requests[0]["segments"], segments)
        self.assertNotEqual(proc.requests[0]["id"], proc.requests[1]["id"])
        self.assertEqual(self.bridge.last_mode, "list")
        self.assertTrue(Path(first).is_file())
        self.assertTrue(Path(second).is_file())

    async def test_bad_list_response_closes_connection_and_removes_own_output(self):
        full, segments = parsed([{"ja": "いるよ。", "emotion": "normal"}])
        proc = FakeBridgeProcess("wrong_id")
        with patch.object(voice.asyncio, "create_subprocess_exec", AsyncMock(return_value=proc)):
            with self.assertRaises((RuntimeError, ValueError)):
                await self.bridge.say_segments(segments, text=full)
        self.assertIsNone(self.bridge.proc)
        self.assertIsNotNone(proc.returncode)
        self.assertFalse(Path(proc.requests[0]["out"]).exists())


if __name__ == "__main__":
    unittest.main()
