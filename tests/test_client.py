"""
Tests for TestClient class.
"""

import pytest
from aiogram import Bot, Dispatcher, Router
from aiogram.filters import Command
from aiogram.types import Message

from aiogram_test_framework import TestClient
from aiogram_test_framework.factories import (
    CallbackQueryFactory,
    ChatFactory,
    MessageFactory,
    UpdateFactory,
    UserFactory,
)
from aiogram_test_framework.mock_bot import MockBot
from aiogram_test_framework.request_capture import RequestCapture


def create_simple_dispatcher(bot: Bot, dispatcher: Dispatcher) -> None:
    """Create a simple dispatcher with basic handlers."""
    router = Router()

    @router.message(Command("start"))
    async def start_handler(message: Message) -> None:
        await message.answer("Welcome!")

    @router.message()
    async def echo_handler(message: Message) -> None:
        await message.answer(f"You said: {message.text}")

    dispatcher.include_router(router)


class TestTestClientCreation:
    """Tests for TestClient creation."""

    async def test_create_with_defaults(self):
        """Test creating a TestClient with default settings."""
        client = await TestClient.create(
            bot_token="123456:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        assert isinstance(client.bot, MockBot)
        assert isinstance(client.dispatcher, Dispatcher)
        assert isinstance(client.capture, RequestCapture)
        assert client.bot.bot_user.id == 123456
        assert client.bot.bot_user.username == "test_bot"

        await client.close()

    async def test_create_with_setup_func(self):
        """Test creating a TestClient with setup function."""
        setup_called = []

        def setup_func(bot: Bot, dispatcher: Dispatcher) -> None:
            setup_called.append(True)

        client = await TestClient.create(
            bot_token="123456:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
            setup_dispatcher_func=setup_func,
        )

        assert len(setup_called) == 1
        await client.close()

    async def test_create_with_custom_dispatcher(self):
        """Test creating a TestClient with a pre-created dispatcher."""
        from aiogram.fsm.storage.memory import MemoryStorage

        custom_dispatcher = Dispatcher(storage=MemoryStorage())
        client = await TestClient.create(
            bot_token="123456:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
            dispatcher=custom_dispatcher,
        )

        assert client.dispatcher is custom_dispatcher
        await client.close()


class TestTestClientProperties:
    """Tests for TestClient properties."""

    async def test_dispatcher_property(self):
        """Test dispatcher property."""
        client = await TestClient.create(
            bot_token="123456:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        assert isinstance(client.dispatcher, Dispatcher)
        await client.close()

    async def test_bot_property(self):
        """Test bot property."""
        client = await TestClient.create(
            bot_token="123456:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        assert isinstance(client.bot, MockBot)
        await client.close()

    async def test_capture_property(self):
        """Test capture property."""
        client = await TestClient.create(
            bot_token="123456:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        assert isinstance(client.capture, RequestCapture)
        await client.close()


class TestTestClientUserCreation:
    """Tests for TestClient user creation."""

    async def test_create_user_defaults(self):
        """Test creating a user with defaults."""
        client = await TestClient.create(
            bot_token="123456:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        user = client.create_user()

        assert user.user.first_name == "Test"
        assert user.user.last_name == "User"
        assert user.chat.type == "private"
        assert user.user_id == user.chat_id

        await client.close()

    async def test_create_user_custom(self):
        """Test creating a user with custom values."""
        client = await TestClient.create(
            bot_token="123456:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        user = client.create_user(
            user_id=999,
            first_name="John",
            last_name="Doe",
            username="johndoe",
            language_code="uk",
        )

        assert user.user_id == 999
        assert user.user.first_name == "John"
        assert user.user.last_name == "Doe"
        assert user.user.username == "johndoe"
        assert user.user.language_code == "uk"

        await client.close()


class TestTestClientMessaging:
    """Tests for TestClient messaging."""

    async def test_send_message(self):
        """Test sending a message."""
        client = await TestClient.create(
            bot_token="123456:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
            setup_dispatcher_func=create_simple_dispatcher,
        )

        user = UserFactory.create()
        responses = await client.send_message(text="Hello", from_user=user)

        assert len(responses) == 1
        assert "You said: Hello" in responses[0].text

        await client.close()

    async def test_send_command(self):
        """Test sending a command."""
        client = await TestClient.create(
            bot_token="123456:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
            setup_dispatcher_func=create_simple_dispatcher,
        )

        user = UserFactory.create()
        responses = await client.send_command(command="start", from_user=user)

        assert len(responses) == 1
        assert responses[0].text == "Welcome!"

        await client.close()

    async def test_send_command_with_args(self):
        """Test sending a command with arguments."""
        def setup_with_args(bot: Bot, dispatcher: Dispatcher) -> None:
            router = Router()

            @router.message(Command("echo"))
            async def echo_cmd(message: Message) -> None:
                text = message.text or ""
                args = text.split(maxsplit=1)[1] if " " in text else "nothing"
                await message.answer(f"Args: {args}")

            dispatcher.include_router(router)

        client = await TestClient.create(
            bot_token="123456:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
            setup_dispatcher_func=setup_with_args,
        )

        user = UserFactory.create()
        responses = await client.send_command(
            command="echo",
            from_user=user,
            args="hello world",
        )

        assert len(responses) == 1
        assert "hello world" in responses[0].text

        await client.close()

    async def test_send_callback(self):
        """Test sending a callback query."""
        from aiogram import F

        def setup_callback(bot: Bot, dispatcher: Dispatcher) -> None:
            router = Router()

            @router.callback_query(F.data == "test")
            async def callback_handler(callback):
                await callback.answer("Received!")

            dispatcher.include_router(router)

        client = await TestClient.create(
            bot_token="123456:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
            setup_dispatcher_func=setup_callback,
        )

        user = UserFactory.create()
        responses = await client.send_callback(data="test", from_user=user)

        assert len(responses) >= 1

        await client.close()


class TestTestClientDice:
    """Tests for TestClient dice functionality."""

    async def test_set_next_dice_value(self):
        """Test setting next dice value."""
        client = await TestClient.create(
            bot_token="123456:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        client.set_next_dice_value(6)
        result = await client.bot.send_dice(chat_id=100)

        assert result.dice.value == 6

        await client.close()

    async def test_set_next_dice_value_queue(self):
        """Test queuing multiple dice values."""
        client = await TestClient.create(
            bot_token="123456:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        client.set_next_dice_value(2)
        client.set_next_dice_value(4)

        result1 = await client.bot.send_dice(chat_id=100)
        result2 = await client.bot.send_dice(chat_id=100)
        result3 = await client.bot.send_dice(chat_id=100)  # Random

        assert result1.dice.value == 2
        assert result2.dice.value == 4
        assert 1 <= result3.dice.value <= 6  # Falls back to random

        await client.close()


class TestTestClientReset:
    """Tests for TestClient reset functionality."""

    async def test_reset_clears_capture(self):
        """Test that reset clears captured requests."""
        client = await TestClient.create(
            bot_token="123456:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
            setup_dispatcher_func=create_simple_dispatcher,
        )

        user = UserFactory.create()
        await client.send_message(text="Hello", from_user=user)

        assert len(client.capture) > 0

        client.reset()

        assert len(client.capture) == 0

        await client.close()

    async def test_reset_resets_counters(self):
        """Test that reset resets factory counters."""
        client = await TestClient.create(
            bot_token="123456:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        UserFactory.create()
        UserFactory.create()

        initial_counter = UserFactory._user_id_counter

        client.reset()

        assert UserFactory._user_id_counter == 100000

        await client.close()


class TestTestClientContextManager:
    """Tests for TestClient context manager."""

    async def test_async_context_manager(self):
        """Test using TestClient as async context manager."""
        async with await TestClient.create(
            bot_token="123456:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
            setup_dispatcher_func=create_simple_dispatcher,
        ) as client:
            user = client.create_user()
            responses = await user.send_command("start")
            assert responses[0].text == "Welcome!"

    async def test_context_manager_cleanup(self):
        """Test that context manager properly cleans up."""
        shutdown_called = []

        async def on_shutdown():
            shutdown_called.append(True)

        client = await TestClient.create(
            bot_token="123456:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        client.dispatcher.shutdown.register(on_shutdown)

        async with client:
            pass

        assert len(shutdown_called) == 1
