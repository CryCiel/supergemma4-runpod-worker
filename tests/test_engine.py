"""RunPod worker regression tests (mocked llama-server; no GPU needed)."""

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))

from engine import LlamaCPPEngine, LlamaCPPOpenAIEngine  # noqa: E402
from utils import JobInput  # noqa: E402


class WorkerEngineTests(unittest.IsolatedAsyncioTestCase):
    async def _flat_job(self, payload):
        fake_client = SimpleNamespace(models=SimpleNamespace(
            list=AsyncMock(return_value=SimpleNamespace(
                data=[SimpleNamespace(id='test-model')]
            ))
        ))

        async def capture(_self, request):
            yield {'route': request.openai_route, 'input': request.openai_input}

        with patch('engine.client', fake_client), patch.object(
            LlamaCPPOpenAIEngine, 'generate', capture
        ):
            return [item async for item in LlamaCPPEngine().generate(
                JobInput(payload)
            )]

    async def test_flat_chat_options(self):
        items = await self._flat_job({
            'messages': [{'role': 'user', 'content': '안녕'}],
            'max_tokens': 12288,
            'temperature': 0.8,
            'top_p': 0.9,
            'stop': ['END'],
            'stream': True,
            'unsupported': 'must be dropped',
        })
        self.assertEqual(items[0]['route'], '/v1/chat/completions')
        body = items[0]['input']
        self.assertEqual(body['model'], 'test-model')
        self.assertEqual(body['max_tokens'], 12288)
        self.assertEqual(body['temperature'], 0.8)
        self.assertEqual(body['top_p'], 0.9)
        self.assertEqual(body['stop'], ['END'])
        self.assertTrue(body['stream'])
        self.assertNotIn('unsupported', body)

    async def test_flat_prompt(self):
        items = await self._flat_job({'prompt': 'Next scene', 'max_tokens': 4096})
        self.assertEqual(items[0]['route'], '/v1/completions')
        self.assertEqual(items[0]['input']['prompt'], 'Next scene')
        self.assertEqual(items[0]['input']['max_tokens'], 4096)

    async def test_async_nonstream(self):
        response = SimpleNamespace(to_dict=lambda: {'choices': [1]})
        create = AsyncMock(return_value=response)
        fake_client = SimpleNamespace(chat=SimpleNamespace(
            completions=SimpleNamespace(create=create)))
        payload = {'model': 'test-model', 'messages': [], 'stream': False}
        with patch('engine.client', fake_client):
            items = [item async for item in LlamaCPPOpenAIEngine().generate(
                JobInput({'openai_route': '/v1/chat/completions',
                          'openai_input': payload})
            )]
        self.assertEqual(items, [{'choices': [1]}])
        create.assert_awaited_once_with(**payload)

    async def test_async_stream(self):
        async def chunks():
            yield SimpleNamespace(to_dict=lambda: {'chunk': 1})
            yield SimpleNamespace(to_dict=lambda: {'chunk': 2})

        fake_client = SimpleNamespace(chat=SimpleNamespace(
            completions=SimpleNamespace(create=AsyncMock(return_value=chunks()))))
        payload = {'model': 'test-model', 'messages': [], 'stream': True}
        with patch('engine.client', fake_client):
            items = [item async for item in LlamaCPPOpenAIEngine().generate(
                JobInput({'openai_route': '/v1/chat/completions',
                          'openai_input': payload})
            )]
        self.assertEqual(len(items), 3)
        self.assertTrue(items[0].startswith('data: {"chunk":1}'))
        self.assertTrue(items[1].startswith('data: {"chunk":2}'))
        self.assertEqual(items[-1], 'data: [DONE]')


if __name__ == '__main__':
    unittest.main()
