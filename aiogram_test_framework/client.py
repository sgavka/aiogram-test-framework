"""
Test client for simulating user interactions with the bot.
"""

from typing import Callable, Optional, Any

from aiogram import Dispatcher, Bot
from aiogram.types import User, Message, Chat

from aiogram_test_framework.user import TestUser
from aiogram_test_framework.mock_bot import MockBot
from aiogram_test_framework.request_capture import RequestCapture
from aiogram_test_framework.setup import create_test_dispatcher
from aiogram_test_framework.types import CapturedRequest
from aiogram_test_framework.factories import (
    ChatFactory, UserFactory,
    MessageFactory,
    CallbackQueryFactory,
    UpdateFactory,
)


class TestClient:
    """
    High-level test client for interacting with an Aiogram bot.

    This client manages the dispatcher, mock bot, and provides methods
    for simulating user interactions and checking bot responses.

    The optional setup_dispatcher_func callback receives both the bot and
    dispatcher, and should configure the dispatcher (register handlers,
    middlewares, etc.):

        def setup_dispatcher(bot: Bot, dispatcher: Dispatcher) -> None:
            setup_middlewares(dispatcher=dispatcher)
            setup_handlers(dispatcher=dispatcher)

    Usage:
        client = await TestClient.create(
            bot_token="123456:ABC-DEF",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
            setup_dispatcher_func=setup_dispatcher,
        )
        user = client.create_user()
        await user.send_command("start")
        assert user.has_received_message_containing("Welcome")
        await client.close()

    Or with context manager:
        async with TestClient.create(
            bot_token="123456:ABC-DEF",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
            setup_dispatcher_func=setup_dispatcher,
        ) as client:
            user = client.create_user()
            await user.send_command("start")
            assert user.has_received_message_containing("Welcome")
    """

    def __init__(
        self,
        dispatcher: Dispatcher,
        bot: MockBot,
        capture: RequestCapture,
    ) -> None:
        self._dispatcher = dispatcher
        self._bot = bot
        self._capture = capture

    @classmethod
    async def create(
        cls,
        bot_token: str,
        bot_id: int,
        bot_username: str,
        bot_first_name: str,
        dispatcher: Optional[Dispatcher] = None,
        setup_dispatcher_func: Optional[Callable[[Bot, Dispatcher], None]] = None,
    ) -> "TestClient":
        """
        Create a new TestClient with the dispatcher set up.

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
            Configured TestClient instance
        """
        capture = RequestCapture()
        bot = MockBot(
            capture=capture,
            token=bot_token,
            bot_id=bot_id,
            bot_username=bot_username,
            bot_first_name=bot_first_name,
        )

        if dispatcher is None:
            dispatcher = create_test_dispatcher()

        if setup_dispatcher_func is not None:
            setup_dispatcher_func(bot, dispatcher)

        return cls(
            dispatcher=dispatcher,
            bot=bot,
            capture=capture,
        )

    @property
    def dispatcher(self) -> Dispatcher:
        """Get the dispatcher."""
        return self._dispatcher

    @property
    def bot(self) -> MockBot:
        """Get the mock bot."""
        return self._bot

    @property
    def capture(self) -> RequestCapture:
        """Get the request capture instance."""
        return self._capture

    def create_user(
        self,
        user_id: Optional[int] = None,
        first_name: str = "Test",
        last_name: Optional[str] = "User",
        username: Optional[str] = None,
        language_code: str = "en",
    ) -> TestUser:
        """
        Create a new test user.

        Args:
            user_id: User ID (auto-generated if not provided)
            first_name: User's first name
            last_name: User's last name
            username: User's username
            language_code: User's language code

        Returns:
            TestUser instance for interacting with the bot
        """
        user = UserFactory.create(
            user_id=user_id,
            first_name=first_name,
            last_name=last_name,
            username=username,
            language_code=language_code,
        )

        test_user = TestUser(
            client=self,
            user=user,
            chat=ChatFactory.create_private_from_user(user),
        )
        return test_user

    async def send_message(
        self,
        text: str,
        from_user: User,
        chat: Optional[Chat] = None,
    ) -> list[CapturedRequest]:
        """
        Send a message to the bot and return captured responses.

        Args:
            text: Message text
            from_user: The user sending the message
            chat: The chat where the message is sent

        Returns:
            List of captured requests made by the bot
        """
        initial_count = len(self._capture)

        update = UpdateFactory.from_text(
            text=text,
            from_user=from_user,
            chat=chat,
        )

        await self._dispatcher.feed_update(bot=self._bot, update=update)

        return self._capture.all_requests[initial_count:]

    async def send_command(
        self,
        command: str,
        from_user: User,
        args: Optional[str] = None,
        chat: Optional[Chat] = None,
    ) -> list[CapturedRequest]:
        """
        Send a command to the bot.

        Args:
            command: Command name without slash
            from_user: The user sending the command
            args: Command arguments
            chat: The chat where the command is sent

        Returns:
            List of captured requests made by the bot
        """
        initial_count = len(self._capture)

        update = UpdateFactory.from_command(
            command=command,
            from_user=from_user,
            args=args,
            chat=chat,
        )

        await self._dispatcher.feed_update(bot=self._bot, update=update)

        return self._capture.all_requests[initial_count:]

    async def send_callback(
        self,
        data: str,
        from_user: User,
        message: Optional[Message] = None,
    ) -> list[CapturedRequest]:
        """
        Send a callback query (button click) to the bot.

        Args:
            data: Callback data
            from_user: The user clicking the button
            message: The message containing the button

        Returns:
            List of captured requests made by the bot
        """
        initial_count = len(self._capture)

        update = UpdateFactory.from_callback(
            data=data,
            from_user=from_user,
            message=message,
        )

        await self._dispatcher.feed_update(bot=self._bot, update=update)

        return self._capture.all_requests[initial_count:]

    def reset(self) -> None:
        """Reset the client state (clear captured requests and counters)."""
        self._capture.clear()
        self._bot.reset_message_counter()
        UserFactory.reset_counter()
        MessageFactory.reset_counter()
        CallbackQueryFactory.reset_counter()
        UpdateFactory.reset_counter()

    async def close(self) -> None:
        """Close the client and clean up resources."""
        await self._dispatcher.emit_shutdown()

    async def __aenter__(self) -> "TestClient":
        """Async context manager entry."""
        await self._dispatcher.emit_startup()
        return self

    async def __aexit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        """Async context manager exit."""
        await self.close()
