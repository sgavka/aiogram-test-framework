"""
Tests for factory classes.
"""

from datetime import datetime

import pytest
from aiogram.types import (
    Chat,
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    Message,
    User,
)

from aiogram_test_framework.factories import (
    CallbackQueryFactory,
    ChatFactory,
    KeyboardFactory,
    MessageFactory,
    UpdateFactory,
    UserFactory,
)


class TestUserFactory:
    """Tests for UserFactory."""

    def test_create_user_with_defaults(self):
        """Test creating a user with default values."""
        user = UserFactory.create()

        assert user.id == 100000
        assert user.first_name == "Test"
        assert user.last_name == "User"
        assert user.username == "test_user_100000"
        assert user.language_code == "en"
        assert user.is_bot is False
        assert user.is_premium is False

    def test_create_user_with_custom_values(self):
        """Test creating a user with custom values."""
        user = UserFactory.create(
            user_id=999,
            first_name="John",
            last_name="Doe",
            username="johndoe",
            language_code="uk",
            is_bot=False,
            is_premium=True,
        )

        assert user.id == 999
        assert user.first_name == "John"
        assert user.last_name == "Doe"
        assert user.username == "johndoe"
        assert user.language_code == "uk"
        assert user.is_premium is True

    def test_user_id_auto_increments(self):
        """Test that user IDs auto-increment."""
        user1 = UserFactory.create()
        user2 = UserFactory.create()
        user3 = UserFactory.create()

        assert user1.id == 100000
        assert user2.id == 100001
        assert user3.id == 100002

    def test_reset_counter(self):
        """Test that reset_counter resets the ID counter."""
        UserFactory.create()
        UserFactory.create()
        UserFactory.reset_counter()

        user = UserFactory.create()
        assert user.id == 100000

    def test_username_generated_from_id(self):
        """Test that username is generated from ID when not provided."""
        user = UserFactory.create(user_id=12345)
        assert user.username == "test_user_12345"


class TestChatFactory:
    """Tests for ChatFactory."""

    def test_create_private_chat(self):
        """Test creating a private chat."""
        chat = ChatFactory.create_private(
            chat_id=123,
            first_name="Test",
            last_name="User",
            username="testuser",
        )

        assert chat.id == 123
        assert chat.type == "private"
        assert chat.first_name == "Test"
        assert chat.last_name == "User"
        assert chat.username == "testuser"

    def test_create_private_chat_default_username(self):
        """Test private chat gets default username."""
        chat = ChatFactory.create_private(chat_id=456)
        assert chat.username == "test_user_456"

    def test_create_private_from_user(self):
        """Test creating a private chat from a User object."""
        user = UserFactory.create(
            user_id=789,
            first_name="Jane",
            last_name="Smith",
            username="janesmith",
        )
        chat = ChatFactory.create_private_from_user(user)

        assert chat.id == 789
        assert chat.type == "private"
        assert chat.first_name == "Jane"
        assert chat.last_name == "Smith"
        assert chat.username == "janesmith"

    def test_create_group_chat(self):
        """Test creating a group chat."""
        chat = ChatFactory.create_group(
            chat_id=-100123,
            title="Test Group",
        )

        assert chat.id == -100123
        assert chat.type == "group"
        assert chat.title == "Test Group"


class TestMessageFactory:
    """Tests for MessageFactory."""

    def test_create_message_with_defaults(self):
        """Test creating a message with default values."""
        user = UserFactory.create()
        message = MessageFactory.create(text="Hello", from_user=user)

        assert message.message_id == 1
        assert message.text == "Hello"
        assert message.from_user == user
        assert message.chat.id == user.id
        assert message.chat.type == "private"
        assert isinstance(message.date, datetime)

    def test_create_message_with_custom_chat(self):
        """Test creating a message with a custom chat."""
        user = UserFactory.create()
        chat = ChatFactory.create_group(chat_id=-100, title="Test Group")
        message = MessageFactory.create(
            text="Hello group",
            from_user=user,
            chat=chat,
        )

        assert message.chat.id == -100
        assert message.chat.type == "group"

    def test_message_id_auto_increments(self):
        """Test that message IDs auto-increment."""
        user = UserFactory.create()

        msg1 = MessageFactory.create(text="First", from_user=user)
        msg2 = MessageFactory.create(text="Second", from_user=user)
        msg3 = MessageFactory.create(text="Third", from_user=user)

        assert msg1.message_id == 1
        assert msg2.message_id == 2
        assert msg3.message_id == 3

    def test_reset_counter(self):
        """Test that reset_counter resets the message ID counter."""
        user = UserFactory.create()
        MessageFactory.create(text="First", from_user=user)
        MessageFactory.create(text="Second", from_user=user)
        MessageFactory.reset_counter()

        msg = MessageFactory.create(text="New first", from_user=user)
        assert msg.message_id == 1

    def test_create_command_simple(self):
        """Test creating a simple command message."""
        user = UserFactory.create()
        message = MessageFactory.create_command(command="start", from_user=user)

        assert message.text == "/start"

    def test_create_command_with_args(self):
        """Test creating a command message with arguments."""
        user = UserFactory.create()
        message = MessageFactory.create_command(
            command="help",
            from_user=user,
            args="topic",
        )

        assert message.text == "/help topic"

    def test_create_message_with_reply_to(self):
        """Test creating a message with reply_to_message."""
        user = UserFactory.create()
        original = MessageFactory.create(text="Original", from_user=user)
        reply = MessageFactory.create(
            text="Reply",
            from_user=user,
            reply_to_message=original,
        )

        assert reply.reply_to_message == original

    def test_create_message_with_reply_markup(self):
        """Test creating a message with reply markup."""
        user = UserFactory.create()
        keyboard = KeyboardFactory.create_inline_keyboard([
            [("Button", "callback")]
        ])
        message = MessageFactory.create(
            text="With keyboard",
            from_user=user,
            reply_markup=keyboard,
        )

        assert message.reply_markup is not None


class TestCallbackQueryFactory:
    """Tests for CallbackQueryFactory."""

    def test_create_callback_query_with_defaults(self):
        """Test creating a callback query with default values."""
        user = UserFactory.create()
        callback = CallbackQueryFactory.create(data="test_data", from_user=user)

        assert callback.id == "1"
        assert callback.data == "test_data"
        assert callback.from_user == user
        assert callback.chat_instance == "test_instance"
        assert callback.message is not None

    def test_create_callback_with_custom_message(self):
        """Test creating a callback query with custom message."""
        user = UserFactory.create()
        message = MessageFactory.create(text="Button message", from_user=user)
        callback = CallbackQueryFactory.create(
            data="click",
            from_user=user,
            message=message,
        )

        assert callback.message == message

    def test_callback_id_auto_increments(self):
        """Test that callback IDs auto-increment."""
        user = UserFactory.create()

        cb1 = CallbackQueryFactory.create(data="data1", from_user=user)
        cb2 = CallbackQueryFactory.create(data="data2", from_user=user)
        cb3 = CallbackQueryFactory.create(data="data3", from_user=user)

        assert cb1.id == "1"
        assert cb2.id == "2"
        assert cb3.id == "3"

    def test_reset_counter(self):
        """Test that reset_counter resets the callback ID counter."""
        user = UserFactory.create()
        CallbackQueryFactory.create(data="data", from_user=user)
        CallbackQueryFactory.create(data="data", from_user=user)
        CallbackQueryFactory.reset_counter()

        cb = CallbackQueryFactory.create(data="data", from_user=user)
        assert cb.id == "1"


class TestUpdateFactory:
    """Tests for UpdateFactory."""

    def test_create_message_update(self):
        """Test creating an update with a message."""
        user = UserFactory.create()
        message = MessageFactory.create(text="Test", from_user=user)
        update = UpdateFactory.create_message_update(message)

        assert update.update_id == 1
        assert update.message == message

    def test_create_callback_update(self):
        """Test creating an update with a callback query."""
        user = UserFactory.create()
        callback = CallbackQueryFactory.create(data="data", from_user=user)
        update = UpdateFactory.create_callback_update(callback)

        assert update.update_id == 1
        assert update.callback_query == callback

    def test_update_id_auto_increments(self):
        """Test that update IDs auto-increment."""
        user = UserFactory.create()
        msg1 = MessageFactory.create(text="First", from_user=user)
        msg2 = MessageFactory.create(text="Second", from_user=user)

        upd1 = UpdateFactory.create_message_update(msg1)
        upd2 = UpdateFactory.create_message_update(msg2)

        assert upd1.update_id == 1
        assert upd2.update_id == 2

    def test_from_text(self):
        """Test creating an update from text."""
        user = UserFactory.create()
        update = UpdateFactory.from_text(text="Hello world", from_user=user)

        assert update.message is not None
        assert update.message.text == "Hello world"
        assert update.message.from_user == user

    def test_from_command(self):
        """Test creating an update from a command."""
        user = UserFactory.create()
        update = UpdateFactory.from_command(
            command="start",
            from_user=user,
            args="deep_link",
        )

        assert update.message is not None
        assert update.message.text == "/start deep_link"

    def test_from_callback(self):
        """Test creating an update from a callback."""
        user = UserFactory.create()
        update = UpdateFactory.from_callback(data="button_click", from_user=user)

        assert update.callback_query is not None
        assert update.callback_query.data == "button_click"

    def test_reset_counter(self):
        """Test that reset_counter resets the update ID counter."""
        user = UserFactory.create()
        msg = MessageFactory.create(text="Test", from_user=user)
        UpdateFactory.create_message_update(msg)
        UpdateFactory.create_message_update(msg)
        UpdateFactory.reset_counter()

        update = UpdateFactory.create_message_update(msg)
        assert update.update_id == 1


class TestKeyboardFactory:
    """Tests for KeyboardFactory."""

    def test_create_single_button(self):
        """Test creating a keyboard with a single button."""
        keyboard = KeyboardFactory.create_inline_keyboard([
            [("Click me", "click")]
        ])

        assert isinstance(keyboard, InlineKeyboardMarkup)
        assert len(keyboard.inline_keyboard) == 1
        assert len(keyboard.inline_keyboard[0]) == 1
        assert keyboard.inline_keyboard[0][0].text == "Click me"
        assert keyboard.inline_keyboard[0][0].callback_data == "click"

    def test_create_multiple_rows(self):
        """Test creating a keyboard with multiple rows."""
        keyboard = KeyboardFactory.create_inline_keyboard([
            [("Row 1 Button", "r1")],
            [("Row 2 Button", "r2")],
            [("Row 3 Button", "r3")],
        ])

        assert len(keyboard.inline_keyboard) == 3
        assert keyboard.inline_keyboard[0][0].callback_data == "r1"
        assert keyboard.inline_keyboard[1][0].callback_data == "r2"
        assert keyboard.inline_keyboard[2][0].callback_data == "r3"

    def test_create_multiple_buttons_per_row(self):
        """Test creating a keyboard with multiple buttons per row."""
        keyboard = KeyboardFactory.create_inline_keyboard([
            [("Yes", "yes"), ("No", "no")],
            [("Maybe", "maybe")],
        ])

        assert len(keyboard.inline_keyboard) == 2
        assert len(keyboard.inline_keyboard[0]) == 2
        assert len(keyboard.inline_keyboard[1]) == 1

        assert keyboard.inline_keyboard[0][0].text == "Yes"
        assert keyboard.inline_keyboard[0][1].text == "No"
        assert keyboard.inline_keyboard[1][0].text == "Maybe"

    def test_create_empty_keyboard(self):
        """Test creating an empty keyboard."""
        keyboard = KeyboardFactory.create_inline_keyboard([])
        assert len(keyboard.inline_keyboard) == 0
