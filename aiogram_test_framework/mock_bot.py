"""
Mock Bot implementation that captures all API requests.
"""

from datetime import datetime
from typing import Any, Optional

from aiogram import Bot
from aiogram.client.session.base import BaseSession
from aiogram.methods import TelegramMethod
from aiogram.methods.base import TelegramType
from aiogram.types import Chat, Message, User

from aiogram_test_framework.request_capture import RequestCapture
from aiogram_test_framework.types import CapturedRequest, RequestType


class MockSession(BaseSession):
    """
    Mock session that intercepts all API calls and stores them in RequestCapture.
    """

    def __init__(self, capture: RequestCapture, bot_user: User) -> None:
        super().__init__()
        self._capture = capture
        self._message_id_counter = 1
        self._bot_user: User = bot_user
        self._next_dice_values: list[int] = []

    def _get_next_message_id(self) -> int:
        """Get the next message ID for responses."""
        msg_id = self._message_id_counter
        self._message_id_counter += 1
        return msg_id

    def set_next_dice_value(self, value: int) -> None:
        """
        Set the value for the next dice roll.

        The value will be used for the next sendDice call and then removed.
        Multiple values can be queued by calling this method multiple times.

        Args:
            value: Dice value (1-6 for standard dice)
        """
        self._next_dice_values.append(value)

    def _get_next_dice_value(self, emoji: str) -> int:
        """Get the next dice value, or random based on emoji type."""
        import random

        if self._next_dice_values:
            return self._next_dice_values.pop(0)

        # Random value based on emoji type
        # 🎲 (dice), 🎯 (darts), 🎳 (bowling): 1-6
        # 🏀 (basketball), ⚽ (football/soccer): 1-5
        # 🎰 (slot machine): 1-64
        if emoji in ("🏀", "⚽"):
            return random.randint(1, 5)
        elif emoji == "🎰":
            return random.randint(1, 64)
        else:  # 🎲, 🎯, 🎳 and others
            return random.randint(1, 6)

    def _method_to_request_type(self, method_name: str) -> RequestType:
        """Convert method name to RequestType enum."""
        try:
            return RequestType(method_name)
        except ValueError:
            return RequestType.OTHER

    async def make_request(
            self,
            bot: Bot,
            method: TelegramMethod[TelegramType],
            timeout: Optional[int] = None,
    ) -> TelegramType:
        """Intercept API request and generate mock response."""
        method_name = method.__api_method__
        params = method.model_dump(exclude_none=True)

        request_type = self._method_to_request_type(method_name)

        response = self._generate_response(
            bot=bot,
            method_name=method_name,
            params=params,
        )

        captured = CapturedRequest(
            request_type=request_type,
            params=params,
            timestamp=datetime.now(),
            response=response,
        )
        self._capture.add(captured)

        return response

    def _generate_response(
            self,
            bot: Bot,
            method_name: str,
            params: dict[str, Any],
    ) -> Any:
        """Generate a mock response for the given method."""
        if method_name == "getMe":
            return self._bot_user

        if method_name in ("sendMessage", "editMessageText"):
            chat_id = params.get("chat_id", 0)
            return Message(
                message_id=self._get_next_message_id(),
                date=datetime.now(),
                chat=Chat(id=chat_id, type="private"),
                text=params.get("text", ""),
                from_user=self._bot_user,
            )

        if method_name == "deleteMessage":
            return True

        if method_name == "answerCallbackQuery":
            return True

        if method_name == "sendDice":
            chat_id = params.get("chat_id", 0)
            emoji = params.get("emoji", "🎲")
            from aiogram.types import Dice
            return Message(
                message_id=self._get_next_message_id(),
                date=datetime.now(),
                chat=Chat(id=chat_id, type="private"),
                dice=Dice(emoji=emoji, value=self._get_next_dice_value(emoji)),
                from_user=self._bot_user,
            )

        if method_name == "sendPhoto":
            chat_id = params.get("chat_id", 0)
            from aiogram.types import PhotoSize
            return Message(
                message_id=self._get_next_message_id(),
                date=datetime.now(),
                chat=Chat(id=chat_id, type="private"),
                photo=[PhotoSize(file_id="test", file_unique_id="test", width=100, height=100)],
                caption=params.get("caption"),
                from_user=self._bot_user,
            )

        if method_name == "getChatMember":
            from aiogram.types import ChatMemberMember
            return ChatMemberMember(
                user=User(
                    id=params.get("user_id", 1),
                    is_bot=False,
                    first_name="TestUser",
                ),
            )

        if method_name == "getChat":
            return Chat(
                id=params.get("chat_id", 0),
                type="private",
            )

        return True

    async def stream_content(
            self,
            url: str,
            headers: Optional[dict[str, Any]] = None,
            timeout: int = 30,
            chunk_size: int = 65536,
            raise_for_status: bool = True,
    ):
        """
        Stream content from URL (mock implementation).

        For testing purposes, this yields empty chunks.
        """
        yield b""

    async def close(self) -> None:
        """Close the session (no-op for mock)."""
        pass


class MockBot(Bot):
    """
    A mock Bot that captures all API requests for testing.

    Usage:
        capture = RequestCapture()
        bot = MockBot(
            capture=capture,
            token="123456:ABC-DEF",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        # Use bot in tests...
        await bot.send_message(chat_id=123, text="Hello")

        # Check captured requests
        messages = capture.get_sent_messages()
        assert len(messages) == 1
    """

    def __init__(
            self,
            capture: RequestCapture,
            token: str,
            bot_id: int,
            bot_username: str,
            bot_first_name: str,
    ) -> None:
        self._capture = capture

        self._bot_user = User(
            id=bot_id,
            is_bot=True,
            first_name=bot_first_name,
            username=bot_username,
        )
        self._mock_session = MockSession(self._capture, self._bot_user)

        super().__init__(token=token, session=self._mock_session)

    @property
    def capture(self) -> RequestCapture:
        """Get the request capture instance."""
        return self._capture

    @property
    def bot_user(self) -> User:
        """Get the mock bot user."""
        return self._bot_user

    def reset_capture(self) -> None:
        """Clear all captured requests."""
        self._capture.clear()

    def reset_message_counter(self) -> None:
        """Reset the message ID counter."""
        self._mock_session._message_id_counter = 1

    def set_next_dice_value(self, value: int) -> None:
        """
        Set the value for the next dice roll.

        The value will be used for the next sendDice call and then removed.
        Multiple values can be queued by calling this method multiple times.

        Args:
            value: Dice value (1-6 for standard dice, different ranges for
                   other emoji types like bowling, darts, etc.)
        """
        self._mock_session.set_next_dice_value(value)
