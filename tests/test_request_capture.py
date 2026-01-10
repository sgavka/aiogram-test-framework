"""
Tests for RequestCapture class.
"""

from datetime import datetime

import pytest

from aiogram_test_framework.request_capture import RequestCapture
from aiogram_test_framework.types import CapturedRequest, RequestType


class TestRequestCapture:
    """Tests for RequestCapture."""

    def test_initial_state(self, capture):
        """Test that capture starts empty."""
        assert len(capture) == 0
        assert capture.all_requests == []

    def test_add_request(self, capture):
        """Test adding a request to capture."""
        request = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 123, "text": "Hello"},
        )
        capture.add(request)

        assert len(capture) == 1
        assert capture.all_requests[0] == request

    def test_clear(self, capture):
        """Test clearing all captured requests."""
        request = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 123, "text": "Hello"},
        )
        capture.add(request)
        capture.add(request)

        assert len(capture) == 2
        capture.clear()
        assert len(capture) == 0

    def test_get_by_type(self, capture):
        """Test getting requests by type."""
        msg_request = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 123, "text": "Hello"},
        )
        edit_request = CapturedRequest(
            request_type=RequestType.EDIT_MESSAGE_TEXT,
            params={"chat_id": 123, "text": "Edited"},
        )
        delete_request = CapturedRequest(
            request_type=RequestType.DELETE_MESSAGE,
            params={"chat_id": 123, "message_id": 1},
        )

        capture.add(msg_request)
        capture.add(edit_request)
        capture.add(delete_request)
        capture.add(msg_request)

        messages = capture.get_by_type(RequestType.SEND_MESSAGE)
        assert len(messages) == 2
        assert all(r.request_type == RequestType.SEND_MESSAGE for r in messages)

        edits = capture.get_by_type(RequestType.EDIT_MESSAGE_TEXT)
        assert len(edits) == 1

    def test_get_sent_messages(self, capture):
        """Test getting sent messages."""
        msg1 = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 100, "text": "Message 1"},
        )
        msg2 = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 200, "text": "Message 2"},
        )
        msg3 = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 100, "text": "Message 3"},
        )

        capture.add(msg1)
        capture.add(msg2)
        capture.add(msg3)

        all_messages = capture.get_sent_messages()
        assert len(all_messages) == 3

        messages_to_100 = capture.get_sent_messages(chat_id=100)
        assert len(messages_to_100) == 2
        assert all(m.chat_id == 100 for m in messages_to_100)

    def test_get_edited_messages(self, capture):
        """Test getting edited messages."""
        edit = CapturedRequest(
            request_type=RequestType.EDIT_MESSAGE_TEXT,
            params={"chat_id": 100, "text": "Edited"},
        )
        capture.add(edit)

        edits = capture.get_edited_messages()
        assert len(edits) == 1
        assert edits[0].request_type == RequestType.EDIT_MESSAGE_TEXT

    def test_get_deleted_messages(self, capture):
        """Test getting deleted messages."""
        delete = CapturedRequest(
            request_type=RequestType.DELETE_MESSAGE,
            params={"chat_id": 100, "message_id": 1},
        )
        capture.add(delete)

        deletes = capture.get_deleted_messages()
        assert len(deletes) == 1
        assert deletes[0].request_type == RequestType.DELETE_MESSAGE

    def test_get_callback_answers(self, capture):
        """Test getting callback answers."""
        answer = CapturedRequest(
            request_type=RequestType.ANSWER_CALLBACK_QUERY,
            params={"callback_query_id": "123"},
        )
        capture.add(answer)

        answers = capture.get_callback_answers()
        assert len(answers) == 1

    def test_get_dice_sends(self, capture):
        """Test getting dice sends."""
        dice = CapturedRequest(
            request_type=RequestType.SEND_DICE,
            params={"chat_id": 100},
        )
        capture.add(dice)

        dices = capture.get_dice_sends()
        assert len(dices) == 1

    def test_get_last_message(self, capture):
        """Test getting the last message."""
        msg1 = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 100, "text": "First"},
        )
        msg2 = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 100, "text": "Last"},
        )

        capture.add(msg1)
        capture.add(msg2)

        last = capture.get_last_message()
        assert last is not None
        assert last.text == "Last"

    def test_get_last_message_empty(self, capture):
        """Test getting last message when empty."""
        assert capture.get_last_message() is None

    def test_get_last_message_with_chat_filter(self, capture):
        """Test getting last message with chat filter."""
        msg1 = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 100, "text": "To 100"},
        )
        msg2 = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 200, "text": "To 200"},
        )
        msg3 = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 100, "text": "Last to 100"},
        )

        capture.add(msg1)
        capture.add(msg2)
        capture.add(msg3)

        last = capture.get_last_message(chat_id=100)
        assert last is not None
        assert last.text == "Last to 100"

    def test_get_last_request(self, capture):
        """Test getting the last request of any type."""
        msg = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 100, "text": "Message"},
        )
        edit = CapturedRequest(
            request_type=RequestType.EDIT_MESSAGE_TEXT,
            params={"chat_id": 100, "text": "Edit"},
        )

        capture.add(msg)
        capture.add(edit)

        last = capture.get_last_request()
        assert last is not None
        assert last.request_type == RequestType.EDIT_MESSAGE_TEXT

    def test_has_message_containing(self, capture):
        """Test checking if any message contains text."""
        msg1 = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 100, "text": "Hello world"},
        )
        msg2 = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 100, "text": "Goodbye world"},
        )

        capture.add(msg1)
        capture.add(msg2)

        assert capture.has_message_containing("Hello") is True
        assert capture.has_message_containing("world") is True
        assert capture.has_message_containing("NotFound") is False

    def test_has_message_containing_with_chat_filter(self, capture):
        """Test has_message_containing with chat filter."""
        msg1 = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 100, "text": "Hello from 100"},
        )
        msg2 = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 200, "text": "Hello from 200"},
        )

        capture.add(msg1)
        capture.add(msg2)

        assert capture.has_message_containing("Hello", chat_id=100) is True
        assert capture.has_message_containing("from 200", chat_id=100) is False
        assert capture.has_message_containing("from 200", chat_id=200) is True

    def test_count_by_type(self, capture):
        """Test counting requests by type."""
        msg = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 100, "text": "Message"},
        )
        edit = CapturedRequest(
            request_type=RequestType.EDIT_MESSAGE_TEXT,
            params={"chat_id": 100, "text": "Edit"},
        )

        capture.add(msg)
        capture.add(msg)
        capture.add(edit)

        assert capture.count_by_type(RequestType.SEND_MESSAGE) == 2
        assert capture.count_by_type(RequestType.EDIT_MESSAGE_TEXT) == 1
        assert capture.count_by_type(RequestType.DELETE_MESSAGE) == 0

    def test_repr(self, capture):
        """Test string representation."""
        assert "RequestCapture" in repr(capture)
        assert "total=0" in repr(capture)

        msg = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 100, "text": "Message"},
        )
        capture.add(msg)

        assert "total=1" in repr(capture)
        assert "messages=1" in repr(capture)


class TestCapturedRequest:
    """Tests for CapturedRequest dataclass."""

    def test_properties(self):
        """Test CapturedRequest property accessors."""
        request = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={
                "chat_id": 123,
                "text": "Hello world",
                "message_id": 456,
                "reply_markup": {"inline_keyboard": []},
            },
        )

        assert request.chat_id == 123
        assert request.text == "Hello world"
        assert request.message_id == 456
        assert request.reply_markup == {"inline_keyboard": []}

    def test_missing_properties(self):
        """Test properties when not present in params."""
        request = CapturedRequest(
            request_type=RequestType.ANSWER_CALLBACK_QUERY,
            params={"callback_query_id": "123"},
        )

        assert request.chat_id is None
        assert request.text is None
        assert request.message_id is None
        assert request.reply_markup is None

    def test_timestamp_default(self):
        """Test that timestamp defaults to now."""
        before = datetime.now()
        request = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={},
        )
        after = datetime.now()

        assert before <= request.timestamp <= after

    def test_repr(self):
        """Test CapturedRequest string representation."""
        request = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 123, "text": "Hello"},
        )

        repr_str = repr(request)
        assert "CapturedRequest" in repr_str
        assert "sendMessage" in repr_str
        assert "chat_id=123" in repr_str
        assert "Hello" in repr_str

    def test_repr_long_text_truncated(self):
        """Test that long text is truncated in repr."""
        long_text = "A" * 100
        request = CapturedRequest(
            request_type=RequestType.SEND_MESSAGE,
            params={"chat_id": 123, "text": long_text},
        )

        repr_str = repr(request)
        assert len(repr_str) < len(long_text) + 50
        assert "..." in repr_str
