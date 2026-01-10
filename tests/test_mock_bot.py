"""
Tests for MockBot and MockSession.
"""

import pytest
from aiogram import Bot
from aiogram.methods import (
    AnswerCallbackQuery,
    DeleteMessage,
    EditMessageText,
    GetChat,
    GetChatMember,
    GetMe,
    SendDice,
    SendMessage,
    SendPhoto,
)
from aiogram.types import Chat, Dice, Message, User

from aiogram_test_framework.mock_bot import MockBot, MockSession
from aiogram_test_framework.request_capture import RequestCapture
from aiogram_test_framework.types import RequestType


class TestMockSession:
    """Tests for MockSession."""

    @pytest.fixture
    def bot_user(self):
        """Provide a bot user."""
        return User(
            id=123456,
            is_bot=True,
            first_name="Test Bot",
            username="test_bot",
        )

    @pytest.fixture
    def session(self, capture, bot_user):
        """Provide a MockSession instance."""
        return MockSession(capture=capture, bot_user=bot_user)

    async def test_make_request_sends_message(self, session, capture, bot_user):
        """Test that make_request captures sendMessage requests."""
        bot = MockBot(
            capture=capture,
            token="123:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        method = SendMessage(chat_id=100, text="Hello world")
        response = await session.make_request(bot, method)

        assert isinstance(response, Message)
        assert response.text == "Hello world"
        assert response.chat.id == 100
        assert response.from_user == bot_user
        assert len(capture) == 1
        assert capture.all_requests[0].request_type == RequestType.SEND_MESSAGE

    async def test_make_request_edit_message(self, session, capture, bot_user):
        """Test that make_request handles editMessageText."""
        bot = MockBot(
            capture=capture,
            token="123:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        method = EditMessageText(chat_id=100, message_id=1, text="Edited")
        response = await session.make_request(bot, method)

        assert isinstance(response, Message)
        assert response.text == "Edited"
        assert len(capture) == 1
        assert capture.all_requests[0].request_type == RequestType.EDIT_MESSAGE_TEXT

    async def test_make_request_delete_message(self, session, capture, bot_user):
        """Test that make_request handles deleteMessage."""
        bot = MockBot(
            capture=capture,
            token="123:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        method = DeleteMessage(chat_id=100, message_id=1)
        response = await session.make_request(bot, method)

        assert response is True
        assert len(capture) == 1
        assert capture.all_requests[0].request_type == RequestType.DELETE_MESSAGE

    async def test_make_request_answer_callback(self, session, capture, bot_user):
        """Test that make_request handles answerCallbackQuery."""
        bot = MockBot(
            capture=capture,
            token="123:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        method = AnswerCallbackQuery(callback_query_id="123")
        response = await session.make_request(bot, method)

        assert response is True
        assert len(capture) == 1
        assert capture.all_requests[0].request_type == RequestType.ANSWER_CALLBACK_QUERY

    async def test_make_request_get_me(self, session, capture, bot_user):
        """Test that make_request handles getMe."""
        bot = MockBot(
            capture=capture,
            token="123:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        method = GetMe()
        response = await session.make_request(bot, method)

        assert response == bot_user

    async def test_make_request_send_dice(self, session, capture, bot_user):
        """Test that make_request handles sendDice."""
        bot = MockBot(
            capture=capture,
            token="123:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        method = SendDice(chat_id=100)
        response = await session.make_request(bot, method)

        assert isinstance(response, Message)
        assert response.dice is not None
        assert isinstance(response.dice, Dice)

    async def test_make_request_get_chat(self, session, capture, bot_user):
        """Test that make_request handles getChat."""
        bot = MockBot(
            capture=capture,
            token="123:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        method = GetChat(chat_id=100)
        response = await session.make_request(bot, method)

        assert isinstance(response, Chat)
        assert response.id == 100

    async def test_make_request_get_chat_member(self, session, capture, bot_user):
        """Test that make_request handles getChatMember."""
        bot = MockBot(
            capture=capture,
            token="123:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        method = GetChatMember(chat_id=100, user_id=999)
        response = await session.make_request(bot, method)

        assert response.user.id == 999

    async def test_message_id_counter(self, session, capture, bot_user):
        """Test that message IDs increment correctly."""
        bot = MockBot(
            capture=capture,
            token="123:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        method1 = SendMessage(chat_id=100, text="First")
        method2 = SendMessage(chat_id=100, text="Second")
        method3 = SendMessage(chat_id=100, text="Third")

        response1 = await session.make_request(bot, method1)
        response2 = await session.make_request(bot, method2)
        response3 = await session.make_request(bot, method3)

        assert response1.message_id == 1
        assert response2.message_id == 2
        assert response3.message_id == 3

    async def test_stream_content(self, session, capture, bot_user):
        """Test stream_content yields empty bytes."""
        async for chunk in session.stream_content("http://example.com"):
            assert chunk == b""

    async def test_close(self, session, capture, bot_user):
        """Test close is a no-op."""
        await session.close()

    async def test_unknown_method_returns_true(self, session, capture, bot_user):
        """Test that unknown methods return True."""
        from aiogram.methods import SetMyCommands
        from aiogram.types import BotCommand

        bot = MockBot(
            capture=capture,
            token="123:ABC",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        method = SetMyCommands(commands=[BotCommand(command="test", description="Test")])
        response = await session.make_request(bot, method)

        assert response is True


class TestMockBot:
    """Tests for MockBot."""

    def test_init(self, capture):
        """Test MockBot initialization."""
        bot = MockBot(
            capture=capture,
            token="123456:ABC-DEF",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        assert bot.capture == capture
        assert bot.bot_user.id == 123456
        assert bot.bot_user.is_bot is True
        assert bot.bot_user.first_name == "Test Bot"
        assert bot.bot_user.username == "test_bot"

    async def test_send_message(self, capture):
        """Test sending a message through MockBot."""
        bot = MockBot(
            capture=capture,
            token="123456:ABC-DEF",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        result = await bot.send_message(chat_id=100, text="Hello")

        assert isinstance(result, Message)
        assert result.text == "Hello"
        assert len(capture) == 1

    def test_reset_capture(self, capture):
        """Test resetting captured requests."""
        bot = MockBot(
            capture=capture,
            token="123456:ABC-DEF",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        from aiogram_test_framework.types import CapturedRequest
        capture.add(CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 100, "text": "Test"},
        ))

        assert len(capture) == 1
        bot.reset_capture()
        assert len(capture) == 0

    def test_reset_message_counter(self, capture):
        """Test resetting the message counter."""
        bot = MockBot(
            capture=capture,
            token="123456:ABC-DEF",
            bot_id=123456,
            bot_username="test_bot",
            bot_first_name="Test Bot",
        )

        bot._mock_session._message_id_counter = 100
        bot.reset_message_counter()
        assert bot._mock_session._message_id_counter == 1
