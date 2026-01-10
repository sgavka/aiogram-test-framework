"""
Base test case class for bot testing.

Provides a mixin that works with:
- pytest (with pytest-asyncio)
- unittest.TestCase
- django.test.TestCase
"""

from typing import Callable, Optional

from aiogram import Dispatcher

from aiogram_test_framework.client import TestClient
from aiogram_test_framework.factories import (
    CallbackQueryFactory,
    MessageFactory,
    UpdateFactory,
    UserFactory,
)


class AsyncBotTestMixin:
    """
    Mixin providing async bot testing utilities.

    This mixin can be combined with any test base class (unittest.TestCase,
    django.test.TransactionTestCase, or plain pytest classes) to provide bot
    testing functionality.

    All test utilities are accessed through the TestClient instance.

    The setup_dispatcher callback should configure the dispatcher with handlers
    and middlewares:

        def setup_dispatcher(bot: Bot, dispatcher: Dispatcher) -> None:
            setup_middlewares(dispatcher=dispatcher)
            setup_handlers(dispatcher=dispatcher)

    Usage with pytest:
        import pytest
        from aiogram import Bot, Dispatcher
        from aiogram_test_framework import AsyncBotTestMixin
        from telegram_bot.bot import setup_handlers, setup_middlewares

        def setup_dispatcher(bot: Bot, dispatcher: Dispatcher) -> None:
            setup_middlewares(dispatcher=dispatcher)
            setup_handlers(dispatcher=dispatcher)

        class TestMyHandler(AsyncBotTestMixin):
            @pytest.fixture(autouse=True)
            async def setup(self):
                self.aiogram_client = await self.setup_client(setup_dispatcher)
                yield
                await self.aiogram_client.close()
                self.reset_factories()

            async def test_start_command(self):
                user = self.aiogram_client.create_user()
                await user.send_command("start")
                assert user.has_received_message_containing("Welcome")

    Usage with unittest:
        import asyncio
        import unittest
        from aiogram import Bot, Dispatcher
        from aiogram_test_framework import AsyncBotTestMixin
        from telegram_bot.bot import setup_handlers, setup_middlewares

        def setup_dispatcher(bot: Bot, dispatcher: Dispatcher) -> None:
            setup_middlewares(dispatcher=dispatcher)
            setup_handlers(dispatcher=dispatcher)

        class TestMyHandler(unittest.TestCase, AsyncBotTestMixin):
            def setUp(self):
                self.loop = asyncio.new_event_loop()
                asyncio.set_event_loop(self.loop)
                self.aiogram_client = self.loop.run_until_complete(
                    self.setup_client(setup_dispatcher)
                )

            def tearDown(self):
                if hasattr(self, 'aiogram_client') and self.aiogram_client:
                    self.loop.run_until_complete(self.aiogram_client.close())
                self.reset_factories()
                self.loop.close()

            def test_start_command(self):
                async def run_test():
                    user = self.aiogram_client.create_user()
                    await user.send_command("start")
                    assert user.has_received_message_containing("Welcome")

                self.loop.run_until_complete(run_test())

    Usage with Django:
        from aiogram import Bot, Dispatcher
        from asgiref.sync import async_to_sync
        from django.test import TransactionTestCase
        from aiogram_test_framework import AsyncBotTestMixin
        from telegram_bot.bot import setup_handlers, setup_middlewares

        def setup_dispatcher(bot: Bot, dispatcher: Dispatcher) -> None:
            setup_middlewares(dispatcher=dispatcher)
            setup_handlers(dispatcher=dispatcher)

        class TestMyHandler(TransactionTestCase, AsyncBotTestMixin):
            def setUp(self) -> None:
                async_to_sync(self._async_setup)()

            def tearDown(self) -> None:
                async_to_sync(self._async_teardown)()

            async def _async_setup(self) -> None:
                self.aiogram_client = await self.setup_client(setup_dispatcher)

            async def _async_teardown(self) -> None:
                await self.aiogram_client.close()
                self.reset_factories()

            async def test_start_command(self):
                user = self.aiogram_client.create_user()
                await user.send_command("start")
                assert user.has_received_message_containing("Welcome")
    """

    async def setup_client(
            self,
            bot_token: str = "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11",
            bot_id: int = 123456,
            bot_username: str = "test_bot",
            bot_first_name: str = "Test Bot",
            dispatcher: Optional[Dispatcher] = None,
            setup_dispatcher_func: Optional[Callable] = None,
    ) -> TestClient:
        """
        Set up the test client with the dispatcher.

        Args:
            bot_token: Mock bot token
            bot_id: Mock bot ID
            bot_username: Mock bot username
            bot_first_name: Mock bot first name (display name)
            dispatcher: Optional pre-created Dispatcher. If None, a new one
                is created using create_test_dispatcher().
            setup_dispatcher_func: Optional function that configures the dispatcher.
                Should accept a Bot and Dispatcher instance and configure it
                (register handlers, middlewares, etc.). If None, dispatcher is
                used as-is without additional configuration.

        Returns:
            TestClient instance
        """
        client = await TestClient.create(
            bot_token=bot_token,
            bot_id=bot_id,
            bot_username=bot_username,
            bot_first_name=bot_first_name,
            dispatcher=dispatcher,
            setup_dispatcher_func=setup_dispatcher_func,
        )
        await client.dispatcher.emit_startup()
        return client

    def reset_factories(self) -> None:
        """Reset all factory counters."""
        UserFactory.reset_counter()
        MessageFactory.reset_counter()
        CallbackQueryFactory.reset_counter()
        UpdateFactory.reset_counter()
