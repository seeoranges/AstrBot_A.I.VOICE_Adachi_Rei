import asyncio
import types
from unittest.mock import AsyncMock, patch

from test_voice import OfflineAsyncCase, load_plugin, voice


class ReloadTests(OfflineAsyncCase):
    def plugin(self, providers, reload):
        plugin = object.__new__(voice.AdachiAIVoice)
        plugin.owner = "dummy-owner"
        plugin.config = {"prewarm": False}
        plugin.context = types.SimpleNamespace(provider_manager=types.SimpleNamespace(
            tts_provider_insts=list(providers),
            inst_map={p.provider_config["id"]: p for p in providers},
            reload=reload,
        ))
        return plugin

    async def test_old_module_instance_rebuilt_after_reload(self):
        old_module = load_plugin()
        config = {"id": voice.TYPE_NAME, "type": voice.TYPE_NAME, "enable": True}
        old = old_module.AdachiTTSProvider(config, {})
        await old_module.BRIDGE.close()
        plugin = self.plugin([old], AsyncMock())
        manager = plugin.context.provider_manager

        async def reload(config):
            fresh = voice.AdachiTTSProvider(config, {})
            manager.inst_map[config["id"]] = fresh
            manager.tts_provider_insts[:] = [fresh]

        manager.reload.side_effect = reload
        await plugin.initialize()
        current = manager.inst_map[voice.TYPE_NAME]
        self.assertIs(type(current), voice.AdachiTTSProvider)
        self.assertIsNot(current, old)
        with patch.object(voice, "synthesize", AsyncMock(return_value="current.mp3")) as synth:
            self.assertEqual(await current.get_audio("你好"), "current.mp3")
            synth.assert_awaited_once_with("你好")
        manager.reload.assert_awaited_once_with(config)

    async def test_current_class_and_other_provider_untouched(self):
        current = voice.AdachiTTSProvider({"id": voice.TYPE_NAME, "type": voice.TYPE_NAME}, {})
        other = types.SimpleNamespace(provider_config={"id": "other", "type": "other"})
        plugin = self.plugin([current, other], AsyncMock())
        await plugin.initialize()
        plugin.context.provider_manager.reload.assert_not_awaited()

    async def test_disabled_instance_not_enabled_by_refresh(self):
        disabled = types.SimpleNamespace(provider_config={"id": voice.TYPE_NAME, "type": voice.TYPE_NAME, "enable": False})
        plugin = self.plugin([disabled], AsyncMock())
        await plugin.initialize()
        plugin.context.provider_manager.reload.assert_not_awaited()

    async def test_reload_failure_is_reported_and_text_hook_still_loads(self):
        old = types.SimpleNamespace(provider_config={"id": voice.TYPE_NAME, "type": voice.TYPE_NAME})
        plugin = self.plugin([old], AsyncMock(side_effect=RuntimeError("test reload failure")))
        with patch.object(voice.logger, "warning") as warning:
            await plugin.initialize()
        warning.assert_called_once()
        self.assertIn("刷新 TTS", warning.call_args.args[0])

    async def test_silent_provider_load_failure_is_detected(self):
        old = types.SimpleNamespace(provider_config={"id": voice.TYPE_NAME, "type": voice.TYPE_NAME})
        plugin = self.plugin([old], AsyncMock())
        with self.assertRaises(RuntimeError):
            await plugin._refresh_provider()

    async def test_missing_provider_manager_is_allowed(self):
        plugin = object.__new__(voice.AdachiAIVoice)
        plugin.owner = "dummy-owner"
        plugin.context = types.SimpleNamespace()
        plugin.config = {"prewarm": False}
        await plugin.initialize()
