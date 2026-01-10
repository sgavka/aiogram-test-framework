"""
Factories for creating mock Telegram objects for testing.
"""

import random
from datetime import datetime
from typing import Optional, Any

from aiogram.types import (
    User,
    Chat,
    Message,
    MessageEntity,
    Update,
    CallbackQuery,
    InlineKeyboardMarkup,
    InlineKeyboardButton,
    Dice,
)


class UserFactory:
    """Factory for creating mock Telegram User objects."""

    _user_id_counter = 100000

    @classmethod
    def create(
        cls,
        user_id: Optional[int] = None,
        first_name: str = "Test",
        last_name: Optional[str] = "User",
        username: Optional[str] = None,
        language_code: str = "en",
        is_bot: bool = False,
        is_premium: bool = False,
    ) -> User:
        """Create a mock User object."""
        if user_id is None:
            user_id = cls._user_id_counter
            cls._user_id_counter += 1

        if username is None:
            username = f"test_user_{user_id}"

        return User(
            id=user_id,
            is_bot=is_bot,
            first_name=first_name,
            last_name=last_name,
            username=username,
            language_code=language_code,
            is_premium=is_premium,
        )

    @classmethod
    def reset_counter(cls) -> None:
        """Reset the user ID counter."""
        cls._user_id_counter = 100000


class ChatFactory:
    """Factory for creating mock Telegram Chat objects."""

    @classmethod
    def create_private(
        cls,
        chat_id: int,
        first_name: str = "Test",
        last_name: Optional[str] = "User",
        username: Optional[str] = None,
    ) -> Chat:
        """Create a private chat."""
        return Chat(
            id=chat_id,
            type="private",
            first_name=first_name,
            last_name=last_name,
            username=username or f"test_user_{chat_id}",
        )

    @classmethod
    def create_private_from_user(cls, user: User) -> Chat:
        """Create a private chat from a User object."""
        return cls.create_private(
            chat_id=user.id,
            first_name=user.first_name,
            last_name=user.last_name,
            username=user.username,
        )

    @classmethod
    def create_group(
        cls,
        chat_id: int,
        title: str = "Test Group",
    ) -> Chat:
        """Create a group chat."""
        return Chat(
            id=chat_id,
            type="group",
            title=title,
        )


class MessageFactory:
    """Factory for creating mock Telegram Message objects."""

    _message_id_counter = 1

    @classmethod
    def create(
        cls,
        text: str,
        from_user: User,
        chat: Optional[Chat] = None,
        message_id: Optional[int] = None,
        date: Optional[datetime] = None,
        reply_to_message: Optional[Message] = None,
        reply_markup: Optional[InlineKeyboardMarkup] = None,
        entities: Optional[list[MessageEntity]] = None,
    ) -> Message:
        """
        Create a mock Message object.

        Args:
            text: Message text content
            from_user: User who sent the message
            chat: Chat where message was sent (auto-created from user if not provided)
            message_id: Message ID (auto-generated if not provided)
            date: Message date (defaults to now)
            reply_to_message: Message being replied to
            reply_markup: Inline keyboard attached to message
            entities: Message entities (mentions, commands, etc.)

        Returns:
            Mock Message object
        """
        if message_id is None:
            message_id = cls._message_id_counter
            cls._message_id_counter += 1

        if chat is None:
            chat = ChatFactory.create_private(
                chat_id=from_user.id,
                first_name=from_user.first_name,
                last_name=from_user.last_name,
                username=from_user.username,
            )

        if date is None:
            date = datetime.now()

        return Message(
            message_id=message_id,
            date=date,
            chat=chat,
            from_user=from_user,
            text=text,
            reply_to_message=reply_to_message,
            reply_markup=reply_markup,
            entities=entities,
        )

    @classmethod
    def create_command(
        cls,
        command: str,
        from_user: User,
        args: Optional[str] = None,
        chat: Optional[Chat] = None,
        message_id: Optional[int] = None,
    ) -> Message:
        """Create a command message (e.g., /start, /help)."""
        text = f"/{command}"
        if args:
            text = f"{text} {args}"

        return cls.create(
            text=text,
            from_user=from_user,
            chat=chat,
            message_id=message_id,
        )

    @classmethod
    def _get_dice_value_range(cls, emoji: str) -> tuple[int, int]:
        """Get the valid value range for a dice emoji type."""
        # 🎲 (dice), 🎯 (darts), 🎳 (bowling): 1-6
        # 🏀 (basketball), ⚽ (football/soccer): 1-5
        # 🎰 (slot machine): 1-64
        if emoji in ("🏀", "⚽"):
            return (1, 5)
        elif emoji == "🎰":
            return (1, 64)
        else:  # 🎲, 🎯, 🎳 and others
            return (1, 6)

    @classmethod
    def _get_random_dice_value(cls, emoji: str) -> int:
        """Get a random dice value based on emoji type."""
        min_val, max_val = cls._get_dice_value_range(emoji)
        return random.randint(min_val, max_val)

    @classmethod
    def _validate_dice_value(cls, value: int, emoji: str) -> None:
        """Validate that the dice value is within the valid range for the emoji."""
        min_val, max_val = cls._get_dice_value_range(emoji)
        if not (min_val <= value <= max_val):
            raise ValueError(
                f"Dice value {value} is out of range for emoji '{emoji}'. "
                f"Valid range is {min_val}-{max_val}."
            )

    @classmethod
    def create_dice(
        cls,
        from_user: User,
        value: Optional[int] = None,
        emoji: str = "🎲",
        chat: Optional[Chat] = None,
        message_id: Optional[int] = None,
        date: Optional[datetime] = None,
    ) -> Message:
        """
        Create a mock dice Message object.

        Args:
            from_user: User who sent the dice
            value: Dice value (random if None). Valid ranges depend on emoji:
                   🎲, 🎯, 🎳: 1-6; 🏀, ⚽: 1-5; 🎰: 1-64
            emoji: Dice emoji type (🎲, 🎯, 🏀, ⚽, 🎳, 🎰)
            chat: Chat where message was sent (auto-created from user if not provided)
            message_id: Message ID (auto-generated if not provided)
            date: Message date (defaults to now)

        Returns:
            Mock Message object with dice

        Raises:
            ValueError: If value is set and out of valid range for the emoji
        """
        if message_id is None:
            message_id = cls._message_id_counter
            cls._message_id_counter += 1

        if chat is None:
            chat = ChatFactory.create_private(
                chat_id=from_user.id,
                first_name=from_user.first_name,
                last_name=from_user.last_name,
                username=from_user.username,
            )

        if date is None:
            date = datetime.now()

        if value is None:
            value = cls._get_random_dice_value(emoji)
        else:
            cls._validate_dice_value(value, emoji)

        return Message(
            message_id=message_id,
            date=date,
            chat=chat,
            from_user=from_user,
            dice=Dice(emoji=emoji, value=value),
        )

    @classmethod
    def reset_counter(cls) -> None:
        """Reset the message ID counter."""
        cls._message_id_counter = 1


class CallbackQueryFactory:
    """Factory for creating mock CallbackQuery objects."""

    _callback_id_counter = 1

    @classmethod
    def create(
        cls,
        data: str,
        from_user: User,
        message: Optional[Message] = None,
        callback_id: Optional[str] = None,
        chat_instance: str = "test_instance",
    ) -> CallbackQuery:
        """Create a mock CallbackQuery object."""
        if callback_id is None:
            callback_id = str(cls._callback_id_counter)
            cls._callback_id_counter += 1

        if message is None:
            message = MessageFactory.create(
                text="Button message",
                from_user=User(
                    id=123456,
                    is_bot=True,
                    first_name="TestBot",
                ),
                chat=ChatFactory.create_private(
                    chat_id=from_user.id,
                    first_name=from_user.first_name,
                ),
            )

        return CallbackQuery(
            id=callback_id,
            from_user=from_user,
            chat_instance=chat_instance,
            message=message,
            data=data,
        )

    @classmethod
    def reset_counter(cls) -> None:
        """Reset the callback ID counter."""
        cls._callback_id_counter = 1


class UpdateFactory:
    """Factory for creating mock Update objects."""

    _update_id_counter = 1

    @classmethod
    def create_message_update(
        cls,
        message: Message,
        update_id: Optional[int] = None,
    ) -> Update:
        """Create an Update with a message."""
        if update_id is None:
            update_id = cls._update_id_counter
            cls._update_id_counter += 1

        return Update(
            update_id=update_id,
            message=message,
        )

    @classmethod
    def create_callback_update(
        cls,
        callback_query: CallbackQuery,
        update_id: Optional[int] = None,
    ) -> Update:
        """Create an Update with a callback query."""
        if update_id is None:
            update_id = cls._update_id_counter
            cls._update_id_counter += 1

        return Update(
            update_id=update_id,
            callback_query=callback_query,
        )

    @classmethod
    def from_text(
        cls,
        text: str,
        from_user: User,
        chat: Optional[Chat] = None,
    ) -> Update:
        """Create an Update from text message."""
        message = MessageFactory.create(
            text=text,
            from_user=from_user,
            chat=chat,
        )
        return cls.create_message_update(message)

    @classmethod
    def from_command(
        cls,
        command: str,
        from_user: User,
        args: Optional[str] = None,
        chat: Optional[Chat] = None,
    ) -> Update:
        """Create an Update from a command."""
        message = MessageFactory.create_command(
            command=command,
            from_user=from_user,
            args=args,
            chat=chat,
        )
        return cls.create_message_update(message)

    @classmethod
    def from_callback(
        cls,
        data: str,
        from_user: User,
        message: Optional[Message] = None,
    ) -> Update:
        """Create an Update from a callback query."""
        callback = CallbackQueryFactory.create(
            data=data,
            from_user=from_user,
            message=message,
        )
        return cls.create_callback_update(callback)

    @classmethod
    def from_dice(
        cls,
        from_user: User,
        value: Optional[int] = None,
        emoji: str = "🎲",
        chat: Optional[Chat] = None,
    ) -> Update:
        """
        Create an Update from a dice message.

        Args:
            from_user: User who sent the dice
            value: Dice value (random if None, 1-6 for standard dice)
            emoji: Dice emoji type (🎲, 🎯, 🏀, ⚽, 🎳, 🎰)
            chat: Chat where message was sent

        Returns:
            Update with dice message
        """
        message = MessageFactory.create_dice(
            from_user=from_user,
            value=value,
            emoji=emoji,
            chat=chat,
        )
        return cls.create_message_update(message)

    @classmethod
    def reset_counter(cls) -> None:
        """Reset the update ID counter."""
        cls._update_id_counter = 1


class KeyboardFactory:
    """Factory for creating mock keyboard markups."""

    @classmethod
    def create_inline_keyboard(
        cls,
        buttons: list[list[tuple[str, str]]],
    ) -> InlineKeyboardMarkup:
        """
        Create an inline keyboard from a list of button rows.

        Args:
            buttons: List of rows, each row is a list of (text, callback_data) tuples

        Example:
            keyboard = MockKeyboardFactory.create_inline_keyboard([
                [("Button 1", "cb_1"), ("Button 2", "cb_2")],
                [("Button 3", "cb_3")],
            ])
        """
        keyboard = []
        for row in buttons:
            keyboard_row = []
            for text, callback_data in row:
                keyboard_row.append(
                    InlineKeyboardButton(text=text, callback_data=callback_data)
                )
            keyboard.append(keyboard_row)

        return InlineKeyboardMarkup(inline_keyboard=keyboard)
