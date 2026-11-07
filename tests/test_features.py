import ast
import asyncio
import json
from pathlib import Path
import types
from unittest.mock import AsyncMock, MagicMock, patch
import unittest
from test_voice import voice, OfflineAsyncCase, event_for, temporary_case_dir, Plain, Record, MessageChain


class EmotionTests(unittest.TestCase):
    def test_defaults(self):
        self.assertEqual(voice._parse_emotion('{}'), dict(pitch_range=1.0,middle_pause=150,long_pause=370,sentence_pause=800))

    def test_clamps(self):
        self.assertEqual(voice._parse_emotion('{"pitch_range":100,"middle_pause":1,"long_pause":900,"sentence_pause":999.9}'),dict(pitch_range=1.3,middle_pause=100,long_pause=800,sentence_pause=999))

    def test_bad_values_default(self):
        for value in ('true','null','[]','"NaN"','"oops"'):
            with self.subTest(value=value):self.assertEqual(voice._parse_emotion('{"middle_pause":'+value+'}')['middle_pause'],150)

    def test_sentence_pause_never_shorter_than_long_pause(self):
        result=voice._parse_emotion('{"long_pause":800,"sentence_pause":400}')
        self.assertEqual(result['long_pause'],800)
        self.assertEqual(result['sentence_pause'],800)


class FeatureTests(OfflineAsyncCase):
    async def asyncSetUp(self):
        self.temp=temporary_case_dir(self)
        p=self.plugin=object.__new__(voice.AdachiAIVoice)
        p.owner='123456';p.config={'prewarm':False,'latest_only':True}
        platform=types.SimpleNamespace(meta=lambda:types.SimpleNamespace(id='test',name='aiocqhttp'))
        p.context=types.SimpleNamespace(send_message=AsyncMock(return_value=True),platform_manager=types.SimpleNamespace(platform_insts=[platform]))
        p._speech_lock=asyncio.Lock();p._stopping=False;p._sequence={};p._failures=0;p._prewarm_task=None
        patcher=patch.object(voice,'get_astrbot_temp_path',return_value=self.temp.name)
        patcher.start();self.addCleanup(patcher.stop)

    async def test_three_fast_replies_only_latest(self):
        entered=asyncio.Event();release=asyncio.Event();calls=[]
        async def synth(text):
            calls.append(text)
            if text=='one':entered.set();await release.wait()
            return text+'.mp3'
        with patch.object(voice,'synthesize',synth):
            first=asyncio.create_task(self.plugin.speak_text('test:FriendMessage:123456','one'))
            await entered.wait()
            second=asyncio.create_task(self.plugin.speak_text('test:FriendMessage:123456','two'))
            third=asyncio.create_task(self.plugin.speak_text('test:FriendMessage:123456','three'))
            await asyncio.sleep(0);release.set();results=await asyncio.gather(first,second,third)
        self.assertEqual(results,[False,False,True]);self.assertEqual(calls,['one','three'])
        self.assertEqual(self.plugin.context.send_message.await_count,1)

    async def test_owner_private_and_platform(self):
        self.assertTrue(self.plugin.can_speak_umo('test:FriendMessage:123456'))
        for umo in ('test:GroupMessage:123456','test:FriendMessage:91234567','other:FriendMessage:123456','bad'):
            self.assertFalse(self.plugin.can_speak_umo(umo))
        self.plugin.context.platform_manager.platform_insts[0].meta=lambda:types.SimpleNamespace(id='test',name='webchat')
        self.assertFalse(self.plugin.can_speak_umo('test:FriendMessage:123456'))

    async def test_superseded_failure_is_silent(self):
        entered=asyncio.Event();release=asyncio.Event()
        async def synth(text):
            if text=='old':entered.set();await release.wait();raise RuntimeError('obsolete')
            return 'latest.mp3'
        with patch.object(voice,'synthesize',synth),patch.object(self.plugin,'_record_error') as error:
            first=asyncio.create_task(self.plugin.speak_text('test:FriendMessage:123456','old'))
            await entered.wait();last=asyncio.create_task(self.plugin.speak_text('test:FriendMessage:123456','latest'))
            await asyncio.sleep(0);release.set();await asyncio.gather(first,last)
            error.assert_not_called()

    async def test_public_api_disabled_or_absent(self):
        with patch.object(voice,'_ACTIVE_PLUGIN',None):self.assertFalse(await voice.speak_text('test:FriendMessage:123456','text'))
        self.plugin.config['proactive_voice']=False
        with patch.object(voice,'_ACTIVE_PLUGIN',self.plugin):self.assertFalse(await voice.speak_text('test:FriendMessage:123456','text'))

    async def test_three_failures_one_hint_success_resets(self):
        with patch.object(voice,'synthesize',AsyncMock(side_effect=[RuntimeError('test')]*4+['ok.mp3',RuntimeError('test')])):
            for i in range(6):await self.plugin.speak_text('test:FriendMessage:123456',str(i))
        chains=[c.kwargs['message_chain'].chain for c in self.plugin.context.send_message.await_args_list]
        self.assertEqual(sum(isinstance(c[0],Plain) for c in chains),1)
        self.assertEqual(sum(isinstance(c[0],Record) for c in chains),1);self.assertEqual(self.plugin._failures,1)
        info=json.loads((Path(self.temp.name)/voice.TYPE_NAME/'last-error.json').read_text(encoding='utf-8'))
        self.assertEqual(info['consecutive_failures'],1)

    async def test_error_redaction(self):
        self.plugin._record_error(RuntimeError('owner 123456 sk-dummykey token=secret {"api_key":"quotedSecret"}'))
        text=(Path(self.temp.name)/voice.TYPE_NAME/'last-error.json').read_text(encoding='utf-8')
        for secret in ('123456','dummykey','secret','quotedSecret'):self.assertNotIn(secret,text)

    async def test_hint_off_keeps_diagnostics(self):
        self.plugin.config['failure_hint']=False
        with patch.object(voice,'synthesize',AsyncMock(side_effect=RuntimeError('test'))):
            for i in range(3):await self.plugin.speak_text('test:FriendMessage:123456',str(i))
        self.plugin.context.send_message.assert_not_awaited()
        self.assertTrue((Path(self.temp.name)/voice.TYPE_NAME/'last-error.json').exists())

    async def test_duplicate_record_and_handled_hook_skipped(self):
        event=event_for();event.get_result().chain.append(Record(file='already.mp3'))
        with patch.object(voice,'synthesize',AsyncMock()) as synth:await self.plugin.speak(event);synth.assert_not_awaited()
        event=event_for();event.get_extra=lambda *args:True
        with patch.object(voice,'synthesize',AsyncMock()) as synth:await self.plugin.speak(event);synth.assert_not_awaited()

    async def test_prewarm_async_no_model_and_cancel(self):
        self.plugin.config['prewarm']=True;entered=asyncio.Event()
        async def say(*args,**kw):entered.set();await asyncio.Future()
        bridge=types.SimpleNamespace(say=say,close=AsyncMock())
        with patch.object(voice,'BRIDGE',bridge),patch.object(voice,'_to_japanese',AsyncMock()) as model:
            await self.plugin.initialize();await entered.wait()
            self.assertFalse(self.plugin._prewarm_task.done());await self.plugin.terminate()
            self.assertTrue(self.plugin._prewarm_task.cancelled());model.assert_not_awaited()

    async def test_prewarm_disabled_is_lazy(self):
        with patch.object(voice.BRIDGE,'say',AsyncMock()) as say:await self.plugin.initialize();say.assert_not_awaited()
        self.assertIsNone(self.plugin._prewarm_task)


def load_sender():
    path=Path(__file__).resolve().parents[1]/'integrations'/'astrbot_plugin_proactive_chat'/'core'/'services'/'sender_service.py'
    cls=next(n for n in ast.parse(path.read_text(encoding='utf-8-sig')).body if isinstance(n,ast.ClassDef) and n.name=='SenderService')
    future=ast.ImportFrom(module='__future__',names=[ast.alias(name='annotations')],level=0)
    namespace=dict(asyncio=asyncio,Plain=Plain,Record=Record,MessageChain=MessageChain,logger=MagicMock(),is_group_umo=lambda _:False,
                   EventType=types.SimpleNamespace(OnAfterMessageSentEvent=1),dispatch_event_hook=AsyncMock(),Any=object)
    exec(compile(ast.fix_missing_locations(ast.Module(body=[future,cls],type_ignores=[])),str(path),'exec'),namespace)
    return namespace['SenderService']


class ProactiveTests(OfflineAsyncCase):
    async def asyncSetUp(self):
        plugin=self.plugin=types.SimpleNamespace(config_service=types.SimpleNamespace(get_session_config=lambda _: {'tts_settings':{'enable_tts':True}}),
            session_service=types.SimpleNamespace(get_session_log_str=lambda *a:'private'),context=types.SimpleNamespace(get_using_tts_provider=MagicMock()),telemetry=None)
        self.sender=load_sender()(plugin);self.event=types.SimpleNamespace(set_extra=MagicMock())
        self.sender.build_proactive_event=MagicMock(return_value=self.event);self.sender._clear_event_result=MagicMock();self.sender.send_chain=AsyncMock(return_value=True)
        async def hooks(event,chain):return chain,True
        self.sender.run_decorating_hooks=hooks
        self.module=types.SimpleNamespace(speak_text=AsyncMock(return_value=True));self.sender._adachi_voice_module=MagicMock(return_value=self.module)

    async def test_text_before_voice_once(self):
        order=[]
        async def send(*a):order.append('text');return True
        async def voice(*a):order.append('voice');return True
        self.sender.send_chain.side_effect=send;self.module.speak_text.side_effect=voice
        self.assertTrue(await self.sender.send_proactive_message('umo','hello'));self.assertEqual(order,['text','voice'])
        self.plugin.context.get_using_tts_provider.assert_not_called();self.event.set_extra.assert_called_once_with('_adachi_voice_handled',True)

    async def test_failed_text_no_voice(self):
        self.sender.send_chain.return_value=False
        self.assertFalse(await self.sender.send_proactive_message('umo','hello'));self.module.speak_text.assert_not_awaited()

    async def test_voice_error_keeps_text_success(self):
        self.module.speak_text.side_effect=RuntimeError('test')
        self.assertTrue(await self.sender.send_proactive_message('umo','hello'))

    async def test_existing_record_no_extra_voice(self):
        self.assertTrue(await self.sender.send_proactive_message('umo','hello',initial_chain=[Plain('hello'),Record(file='voice')]))
        self.module.speak_text.assert_not_awaited()

    async def test_unmanaged_sessions_do_not_use_adachi_direct_tts(self):
        self.sender._adachi_voice_module.return_value=None
        provider=types.SimpleNamespace(provider_config={'type':'adachi_aivoice'},get_audio=AsyncMock())
        self.plugin.context.get_using_tts_provider.return_value=provider
        self.assertTrue(await self.sender.send_proactive_message('group-umo','hello'))
        provider.get_audio.assert_not_awaited()
