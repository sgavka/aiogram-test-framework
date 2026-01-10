"""
Test user for simulating Telegram user interactions with the bot.
"""

from typing import TYPE_CHECKING, Optional

from aiogram.types import Chat, Message, User

from aiogram_test_framework.types import CapturedRequest

if TYPE_CHECKING:
    from aiogram_test_framework.client import TestClient


class TestUser:
    """
    Represents a simulated Telegram user that can interact with the bot.

    This class provides a high-level API for sending messages, commands,
    and callbacks to the bot, then checking the bot's responses.
    """

    def __init__(
        self,
        client: "TestClient",
        user: User,
        chat: Chat,
    ) -> None:
        self._client = client
        self._user = user
        self._chat = chat

    @property
    def user(self) -> User:
        """Get the underlying Telegram User object."""
        return self._user

    @property
    def user_id(self) -> int:
        """Get the user ID."""
        return self._user.id

    @property
    def chat(self) -> Chat:
        """Get the chat for this user."""
        return self._chat

    @property
    def chat_id(self) -> int:
        """Get the chat ID."""
        return self._chat.id

    def change_client(self, client: "TestClient") -> None:
        """Change the client for this user."""
        self._client = client

    async def send_message(self, text: str) -> list[CapturedRequest]:
        """
        Send a text message to the bot and return captured responses.

        Args:
            text: The message text to send

        Returns:
            List of captured requests (responses) from the bot
        """
        return await self._client.send_message(
            text=text,
            from_user=self._user,
            chat=self._chat,
        )

    async def send_command(
        self,
        command: str,
        args: Optional[str] = None,
    ) -> list[CapturedRequest]:
        """
        Send a command to the bot (e.g., /start, /help).

        Args:
            command: Command name without slash (e.g., "start")
            args: Optional command arguments

        Returns:
            List of captured requests (responses) from the bot
        """
        return await self._client.send_command(
            command=command,
            args=args,
            from_user=self._user,
            chat=self._chat,
        )

    async def click_button(
        self,
        callback_data: str,
        message: Optional[Message] = None,
    ) -> list[CapturedRequest]:
        """
        Simulate clicking an inline keyboard button.

        Args:
            callback_data: The callback data of the button
            message: The message containing the button (optional)

        Returns:
            List of captured requests (responses) from the bot
        """
        return await self._client.send_callback(
            data=callback_data,
            from_user=self._user,
            message=message,
        )

    def get_sent_messages(self) -> list[CapturedRequest]:
        """Get all messages sent by the bot to this user's chat."""
        return self._client.capture.get_sent_messages(chat_id=self.chat_id)

    def get_last_message(self) -> Optional[CapturedRequest]:
        """Get the last message sent by the bot to this user's chat."""
        return self._client.capture.get_last_message(chat_id=self.chat_id)

    def has_received_message_containing(self, text: str) -> bool:
        """Check if the user received a message containing the given text."""
        return self._client.capture.has_message_containing(
            text=text,
            chat_id=self.chat_id,
        )
