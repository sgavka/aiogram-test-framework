"""
Request capture system for tracking all bot API calls.
"""

from typing import Optional

from aiogram_test_framework.types import CapturedRequest, RequestType


class RequestCapture:
    """
    Captures and stores all requests made by the bot to the Telegram API.

    Usage:
        capture = RequestCapture()
        # ... bot makes requests ...
        messages = capture.get_sent_messages()
        assert len(messages) == 1
        assert "Welcome" in messages[0].text
    """

    def __init__(self) -> None:
        self._requests: list[CapturedRequest] = []

    def add(self, request: CapturedRequest) -> None:
        """Add a captured request to the list."""
        self._requests.append(request)

    def clear(self) -> None:
        """Clear all captured requests."""
        self._requests.clear()

    @property
    def all_requests(self) -> list[CapturedRequest]:
        """Get all captured requests."""
        return list(self._requests)

    def get_by_type(self, request_type: RequestType) -> list[CapturedRequest]:
        """Get all requests of a specific type."""
        return [r for r in self._requests if r.request_type == request_type]

    def get_sent_messages(self, chat_id: Optional[int] = None) -> list[CapturedRequest]:
        """Get all sendMessage requests, optionally filtered by chat_id."""
        messages = self.get_by_type(RequestType.SEND_MESSAGE)
        if chat_id is not None:
            messages = [m for m in messages if m.chat_id == chat_id]
        return messages

    def get_edited_messages(self, chat_id: Optional[int] = None) -> list[CapturedRequest]:
        """Get all editMessageText requests, optionally filtered by chat_id."""
        messages = self.get_by_type(RequestType.EDIT_MESSAGE_TEXT)
        if chat_id is not None:
            messages = [m for m in messages if m.chat_id == chat_id]
        return messages

    def get_deleted_messages(self, chat_id: Optional[int] = None) -> list[CapturedRequest]:
        """Get all deleteMessage requests, optionally filtered by chat_id."""
        messages = self.get_by_type(RequestType.DELETE_MESSAGE)
        if chat_id is not None:
            messages = [m for m in messages if m.chat_id == chat_id]
        return messages

    def get_callback_answers(self) -> list[CapturedRequest]:
        """Get all answerCallbackQuery requests."""
        return self.get_by_type(RequestType.ANSWER_CALLBACK_QUERY)

    def get_dice_sends(self, chat_id: Optional[int] = None) -> list[CapturedRequest]:
        """Get all sendDice requests, optionally filtered by chat_id."""
        messages = self.get_by_type(RequestType.SEND_DICE)
        if chat_id is not None:
            messages = [m for m in messages if m.chat_id == chat_id]
        return messages

    def get_last_message(self, chat_id: Optional[int] = None) -> Optional[CapturedRequest]:
        """Get the last sent message, optionally filtered by chat_id."""
        messages = self.get_sent_messages(chat_id=chat_id)
        return messages[-1] if messages else None

    def get_last_request(self) -> Optional[CapturedRequest]:
        """Get the last request of any type."""
        return self._requests[-1] if self._requests else None

    def has_message_containing(
        self,
        text: str,
        chat_id: Optional[int] = None,
    ) -> bool:
        """Check if any sent message contains the given text."""
        for message in self.get_sent_messages(chat_id=chat_id):
            if message.text and text in message.text:
                return True
        return False

    def count_by_type(self, request_type: RequestType) -> int:
        """Count requests of a specific type."""
        return len(self.get_by_type(request_type))

    def __len__(self) -> int:
        """Get the total number of captured requests."""
        return len(self._requests)

    def __repr__(self) -> str:
        return f"RequestCapture(total={len(self._requests)}, messages={self.count_by_type(RequestType.SEND_MESSAGE)})"
