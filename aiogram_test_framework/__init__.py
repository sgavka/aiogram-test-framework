"""
Aiogram Test Framework

A testing framework for Aiogram 3.x Telegram bots that allows:
- Mocking the Telegram Bot API
- Capturing all outgoing bot requests
- Simulating user interactions
- Testing handlers with full middleware chain
"""

from aiogram_test_framework.types import (
    CapturedRequest,
    RequestType,
)
from aiogram_test_framework.request_capture import RequestCapture
from aiogram_test_framework.mock_bot import MockBot
from aiogram_test_framework.factories import (
    UserFactory,
    ChatFactory,
    MessageFactory,
    CallbackQueryFactory,
    UpdateFactory,
    KeyboardFactory,
)
from aiogram_test_framework.client import TestClient
from aiogram_test_framework.user import TestUser
from aiogram_test_framework.base import AsyncBotTestMixin
from aiogram_test_framework.setup import create_test_dispatcher

__version__ = "0.1.0"

__all__ = [
    # Types
    "CapturedRequest",
    "RequestType",
    # Core
    "RequestCapture",
    "MockBot",
    # Factories
    "UserFactory",
    "ChatFactory",
    "MessageFactory",
    "CallbackQueryFactory",
    "UpdateFactory",
    "KeyboardFactory",
    # Client
    "TestClient",
    "TestUser",
    # Base
    "AsyncBotTestMixin",
    # Setup
    "create_test_dispatcher",
]
