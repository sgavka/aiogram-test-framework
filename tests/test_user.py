"""
Tests for TestUser class.
"""

import pytest
from aiogram import Bot, Dispatcher, Router
from aiogram.filters import Command
from aiogram.types import Message

from aiogram_test_framework import TestClient
from aiogram_test_framework.factories import ChatFactory, UserFactory
from aiogram_test_framework.user import TestUser


def create_test_dispatcher(bot: Bot, dispatcher: Dispatcher) -> None:
    """Create a dispatcher with handlers for testing."""
    router = Router()

    @router.message(Command("start"))
    async def start_handler(message: Message) -> None:
        await message.answer("Welcome!")

    @router.message(Command("greet"))
    async def greet_handler(message: Message) -> None:
        name = message.from_user.first_name if message.from_user else "User"
        await message.answer(f"Hello, {name}!")

    @router.message(lambda m: m.dice is not None)
    async def dice_handler(message: Message) -> None:
        await message.answer(f"You rolled: {message.dice.value}")

    @router.message()
    async def echo_handler(message: Message) -> None:
        await message.answer(f"Echo: {message.text}")

    dispatcher.include_router(router)


@pytest.fixture
async def client() -> TestClient:
    """Provide a TestClient with handlers."""
    client = await TestClient.create(
        bot_token="123456:ABC",
        bot_id=123456,
        bot_username="test_bot",
        bot_first_name="Test Bot",
        setup_dispatcher_func=create_test_dispatcher,
    )
    yield client
    await client.close()


class TestTestUser:
    """Tests for TestUser."""

    def test_user_properties(self, client):
        """Test TestUser property accessors."""
        user = client.create_user(
            user_id=999,
            first_name="John",
            last_name="Doe",
            username="johndoe",
        )

        assert user.user_id == 999
        assert user.user.first_name == "John"
        assert user.user.last_name == "Doe"
        assert user.chat_id == 999
        assert user.chat.type == "private"

    async def test_send_message(self, client):
        """Test sending a message."""
        user = client.create_user()
        responses = await user.send_message("Hello bot")

        assert len(responses) == 1
        assert responses[0].text == "Echo: Hello bot"

    async def test_send_command(self, client):
        """Test sending a command."""
        user = client.create_user()
        responses = await user.send_command("start")

        assert len(responses) == 1
        assert responses[0].text == "Welcome!"

    async def test_send_command_with_name(self, client):
        """Test sending a command that uses the user's name."""
        user = client.create_user(first_name="Alice")
        responses = await user.send_command("greet")

        assert len(responses) == 1
        assert "Alice" in responses[0].text

    async def test_click_button(self, client):
        """Test clicking a button (callback query)."""
        from aiogram import F

        router = Router()

        @router.callback_query(F.data == "test_click")
        async def callback_handler(callback):
            await callback.answer()
            await callback.message.edit_text("Button clicked!")

        client.dispatcher.include_router(router)

        user = client.create_user()
        responses = await user.click_button("test_click")

        assert len(responses) >= 1

    async def test_get_sent_messages(self, client):
        """Test getting all messages sent to a user."""
        user = client.create_user()

        await user.send_message("First")
        await user.send_message("Second")
        await user.send_message("Third")

        messages = user.get_sent_messages()
        assert len(messages) == 3

    async def test_get_last_message(self, client):
        """Test getting the last message sent to a user."""
        user = client.create_user()

        await user.send_command("start")
        await user.send_message("Hello")

        last = user.get_last_message()
        assert last is not None
        assert "Echo:" in last.text or "Hello" in last.text

    async def test_has_received_message_containing(self, client):
        """Test checking if user received a message containing text."""
        user = client.create_user()

        await user.send_command("start")

        assert user.has_received_message_containing("Welcome") is True
        assert user.has_received_message_containing("Goodbye") is False

    async def test_multiple_users_isolation(self, client):
        """Test that messages to different users are isolated."""
        user1 = client.create_user(first_name="User1")
        user2 = client.create_user(first_name="User2")

        await user1.send_command("greet")
        await user2.send_command("greet")

        user1_messages = user1.get_sent_messages()
        user2_messages = user2.get_sent_messages()

        assert len(user1_messages) == 1
        assert len(user2_messages) == 1
        assert "User1" in user1_messages[0].text
        assert "User2" in user2_messages[0].text

    def test_change_client(self, client):
        """Test changing the client for a user."""
        user = client.create_user()
        original_client = user._client

        new_capture = type(client.capture)()
        user.change_client(client)

        assert user._client == client

    async def test_send_dice_random(self, client):
        """Test sending a dice with random value."""
        user = client.create_user()
        responses = await user.send_dice()

        assert len(responses) == 1
        assert "You rolled:" in responses[0].text

    async def test_send_dice_specific_value(self, client):
        """Test sending a dice with a specific value."""
        user = client.create_user()
        responses = await user.send_dice(value=6)

        assert len(responses) == 1
        assert "You rolled: 6" in responses[0].text

    async def test_send_dice_with_emoji(self, client):
        """Test sending a dice with different emoji."""
        user = client.create_user()
        responses = await user.send_dice(value=3, emoji="🎯")

        assert len(responses) == 1
        assert "You rolled: 3" in responses[0].text
