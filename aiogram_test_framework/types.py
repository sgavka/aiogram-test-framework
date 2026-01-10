"""
Type definitions for the testing framework.
"""

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any, Optional


class RequestType(str, Enum):
    """Types of Telegram Bot API requests."""

    # Messages
    SEND_MESSAGE = "sendMessage"
    EDIT_MESSAGE_TEXT = "editMessageText"
    EDIT_MESSAGE_REPLY_MARKUP = "editMessageReplyMarkup"
    DELETE_MESSAGE = "deleteMessage"
    FORWARD_MESSAGE = "forwardMessage"
    COPY_MESSAGE = "copyMessage"

    # Media
    SEND_PHOTO = "sendPhoto"
    SEND_VIDEO = "sendVideo"
    SEND_AUDIO = "sendAudio"
    SEND_DOCUMENT = "sendDocument"
    SEND_STICKER = "sendSticker"
    SEND_ANIMATION = "sendAnimation"
    SEND_VOICE = "sendVoice"
    SEND_VIDEO_NOTE = "sendVideoNote"
    SEND_MEDIA_GROUP = "sendMediaGroup"

    # Special
    SEND_DICE = "sendDice"
    SEND_LOCATION = "sendLocation"
    SEND_CONTACT = "sendContact"
    SEND_POLL = "sendPoll"

    # Chat actions
    SEND_CHAT_ACTION = "sendChatAction"

    # Callbacks
    ANSWER_CALLBACK_QUERY = "answerCallbackQuery"
    ANSWER_INLINE_QUERY = "answerInlineQuery"

    # Chat management
    GET_CHAT = "getChat"
    GET_CHAT_MEMBER = "getChatMember"
    BAN_CHAT_MEMBER = "banChatMember"
    UNBAN_CHAT_MEMBER = "unbanChatMember"
    RESTRICT_CHAT_MEMBER = "restrictChatMember"

    # Bot info
    GET_ME = "getMe"
    GET_MY_COMMANDS = "getMyCommands"
    SET_MY_COMMANDS = "setMyCommands"

    # Other
    OTHER = "other"


@dataclass
class CapturedRequest:
    """A captured request made by the bot to Telegram API."""

    request_type: RequestType
    params: dict[str, Any]
    timestamp: datetime = field(default_factory=datetime.now)
    response: Optional[Any] = None

    @property
    def chat_id(self) -> Optional[int]:
        """Get the chat_id from the request params if present."""
        return self.params.get("chat_id")

    @property
    def text(self) -> Optional[str]:
        """Get the text from the request params if present."""
        return self.params.get("text")

    @property
    def message_id(self) -> Optional[int]:
        """Get the message_id from the request params if present."""
        return self.params.get("message_id")

    @property
    def reply_markup(self) -> Optional[Any]:
        """Get the reply_markup from the request params if present."""
        return self.params.get("reply_markup")

    def __repr__(self) -> str:
        text_preview = ""
        if self.text:
            text_preview = f", text={self.text[:50]!r}..."
        return f"CapturedRequest({self.request_type.value}, chat_id={self.chat_id}{text_preview})"
