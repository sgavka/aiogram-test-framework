"""
Pytest configuration and shared fixtures.
"""

import pytest
from aiogram import Bot, Dispatcher, Router
from aiogram.filters import Command
from aiogram.types import Message

from aiogram_test_framework import TestClient
from aiogram_test_framework.factories import (
    CallbackQueryFactory,
    MessageFactory,
    UpdateFactory,
    UserFactory,
)
from aiogram_test_framework.request_capture import RequestCapture


@pytest.fixture
def capture() -> RequestCapture:
    """Provide a fresh RequestCapture instance."""
    return RequestCapture()


@pytest.fixture(autouse=True)
def reset_factories():
    """Reset all factory counters before each test."""
    UserFactory.reset_counter()
    MessageFactory.reset_counter()
    CallbackQueryFactory.reset_counter()
    UpdateFactory.reset_counter()
    yield
    UserFactory.reset_counter()
    MessageFactory.reset_counter()
    CallbackQueryFactory.reset_counter()
    UpdateFactory.reset_counter()


def create_simple_bot_dispatcher(bot: Bot, dispatcher: Dispatcher) -> None:
    """Create a simple dispatcher with basic handlers for testing."""
    router = Router()

    @router.message(Command("start"))
    async def start_handler(message: Message) -> None:
        await message.answer("Welcome to the bot!")

    @router.message(Command("help"))
    async def help_handler(message: Message) -> None:
        await message.answer("This is the help message.")

    @router.message(Command("echo"))
    async def echo_handler(message: Message) -> None:
        text = message.text or ""
        args = text.split(maxsplit=1)[1] if " " in text else ""
        await message.answer(f"Echo: {args}")

    @router.message()
    async def default_handler(message: Message) -> None:
        await message.answer(f"You said: {message.text}")

    dispatcher.include_router(router)


@pytest.fixture
async def simple_client() -> TestClient:
    """Provide a TestClient with a simple bot setup."""
    client = await TestClient.create(
        bot_token="123456:ABC-DEF",
        bot_id=123456,
        bot_username="test_bot",
        bot_first_name="Test Bot",
        setup_dispatcher_func=create_simple_bot_dispatcher,
    )
    yield client
    await client.close()
