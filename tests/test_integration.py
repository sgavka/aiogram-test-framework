"""
Integration tests for the full testing framework.
"""

import pytest
from aiogram import Bot, Dispatcher, F, Router
from aiogram.filters import Command, StateFilter
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import (
    CallbackQuery,
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    Message,
)

from aiogram_test_framework import AsyncBotTestMixin, TestClient
from aiogram_test_framework.factories import KeyboardFactory


class Form(StatesGroup):
    """Test FSM states."""

    name = State()
    age = State()
    confirm = State()


def create_full_dispatcher(bot: Bot, dispatcher: Dispatcher) -> None:
    """Create a dispatcher with multiple types of handlers."""
    router = Router()

    @router.message(Command("start"))
    async def start_handler(message: Message) -> None:
        keyboard = InlineKeyboardMarkup(
            inline_keyboard=[
                [InlineKeyboardButton(text="Begin", callback_data="begin")],
                [InlineKeyboardButton(text="Help", callback_data="help")],
            ]
        )
        await message.answer("Welcome! Choose an option:", reply_markup=keyboard)

    @router.message(Command("help"))
    async def help_handler(message: Message) -> None:
        await message.answer("This is the help message.")

    @router.message(Command("form"))
    async def form_handler(message: Message, state: FSMContext) -> None:
        await state.set_state(Form.name)
        await message.answer("Please enter your name:")

    @router.message(StateFilter(Form.name))
    async def process_name(message: Message, state: FSMContext) -> None:
        await state.update_data(name=message.text)
        await state.set_state(Form.age)
        await message.answer("Now enter your age:")

    @router.message(StateFilter(Form.age))
    async def process_age(message: Message, state: FSMContext) -> None:
        if not message.text or not message.text.isdigit():
            await message.answer("Please enter a valid number:")
            return

        await state.update_data(age=int(message.text))
        data = await state.get_data()

        keyboard = InlineKeyboardMarkup(
            inline_keyboard=[
                [
                    InlineKeyboardButton(text="Confirm", callback_data="confirm"),
                    InlineKeyboardButton(text="Cancel", callback_data="cancel"),
                ]
            ]
        )
        await message.answer(
            f"Your data:\nName: {data['name']}\nAge: {message.text}\n\nConfirm?",
            reply_markup=keyboard,
        )
        await state.set_state(Form.confirm)

    @router.callback_query(F.data == "begin")
    async def begin_callback(callback: CallbackQuery) -> None:
        await callback.answer()
        await callback.message.edit_text("Let's begin!")

    @router.callback_query(F.data == "help")
    async def help_callback(callback: CallbackQuery) -> None:
        await callback.answer("Opening help...")
        await callback.message.edit_text("Here's the help information.")

    @router.callback_query(F.data == "confirm", StateFilter(Form.confirm))
    async def confirm_callback(callback: CallbackQuery, state: FSMContext) -> None:
        data = await state.get_data()
        await callback.answer("Confirmed!")
        await callback.message.edit_text(
            f"Registration complete!\nWelcome, {data['name']}!"
        )
        await state.clear()

    @router.callback_query(F.data == "cancel", StateFilter(Form.confirm))
    async def cancel_callback(callback: CallbackQuery, state: FSMContext) -> None:
        await callback.answer("Cancelled")
        await callback.message.edit_text("Registration cancelled.")
        await state.clear()

    @router.message()
    async def default_handler(message: Message) -> None:
        await message.answer("Unknown command. Use /help for assistance.")

    dispatcher.include_router(router)


@pytest.fixture
async def full_client() -> TestClient:
    """Provide a TestClient with full bot setup."""
    client = await TestClient.create(
        bot_token="123456:ABC-DEF",
        bot_id=123456,
        bot_username="test_bot",
        bot_first_name="Test Bot",
        setup_dispatcher_func=create_full_dispatcher,
    )
    yield client
    await client.close()


class TestBasicInteractions:
    """Test basic bot interactions."""

    async def test_start_command_shows_keyboard(self, full_client):
        """Test that /start shows inline keyboard."""
        user = full_client.create_user()
        responses = await user.send_command("start")

        assert len(responses) == 1
        assert "Welcome" in responses[0].text
        assert responses[0].reply_markup is not None

    async def test_help_command(self, full_client):
        """Test help command."""
        user = full_client.create_user()
        responses = await user.send_command("help")

        assert len(responses) == 1
        assert "help" in responses[0].text.lower()

    async def test_unknown_message(self, full_client):
        """Test response to unknown message."""
        user = full_client.create_user()
        responses = await user.send_message("random text")

        assert len(responses) == 1
        assert "Unknown command" in responses[0].text


class TestCallbackQueries:
    """Test callback query handling."""

    async def test_begin_button(self, full_client):
        """Test clicking the Begin button."""
        user = full_client.create_user()

        await user.send_command("start")
        responses = await user.click_button("begin")

        assert len(responses) >= 1
        edited_messages = full_client.capture.get_edited_messages()
        assert len(edited_messages) >= 1
        assert any("begin" in (m.text or "") for m in edited_messages)

    async def test_help_button(self, full_client):
        """Test clicking the Help button."""
        user = full_client.create_user()

        await user.send_command("start")
        responses = await user.click_button("help")

        assert len(responses) >= 1


class TestFSMFlow:
    """Test FSM (Finite State Machine) flow."""

    async def test_form_complete_flow(self, full_client):
        """Test completing the form flow."""
        user = full_client.create_user()

        responses = await user.send_command("form")
        assert user.has_received_message_containing("name")

        responses = await user.send_message("John")
        assert user.has_received_message_containing("age")

        responses = await user.send_message("25")
        assert user.has_received_message_containing("John")
        assert user.has_received_message_containing("25")
        assert user.has_received_message_containing("Confirm")

        responses = await user.click_button("confirm")
        edited_messages = full_client.capture.get_edited_messages()
        assert len(edited_messages) >= 1
        last_edit = edited_messages[-1]
        assert "complete" in (last_edit.text or "").lower()
        assert "John" in (last_edit.text or "")

    async def test_form_cancel_flow(self, full_client):
        """Test cancelling the form."""
        user = full_client.create_user()

        await user.send_command("form")
        await user.send_message("Jane")
        await user.send_message("30")

        responses = await user.click_button("cancel")
        edited_messages = full_client.capture.get_edited_messages()
        assert len(edited_messages) >= 1
        last_edit = edited_messages[-1]
        assert "cancelled" in (last_edit.text or "").lower()

    async def test_form_invalid_age(self, full_client):
        """Test entering invalid age."""
        user = full_client.create_user()

        await user.send_command("form")
        await user.send_message("John")

        responses = await user.send_message("not a number")
        assert user.has_received_message_containing("valid")


class TestMultipleUsers:
    """Test multiple users interacting simultaneously."""

    async def test_independent_user_sessions(self, full_client):
        """Test that multiple users have independent sessions."""
        user1 = full_client.create_user(first_name="User1")
        user2 = full_client.create_user(first_name="User2")

        await user1.send_command("form")
        await user1.send_message("Alice")

        await user2.send_command("form")
        await user2.send_message("Bob")

        user1_msgs = user1.get_sent_messages()
        user2_msgs = user2.get_sent_messages()

        assert len(user1_msgs) == 2
        assert len(user2_msgs) == 2

    async def test_separate_state_per_user(self, full_client):
        """Test that FSM state is separate for each user."""
        user1 = full_client.create_user()
        user2 = full_client.create_user()

        await user1.send_command("form")
        await user1.send_message("User1Name")
        await user1.send_message("21")

        await user2.send_command("start")

        user1_last = user1.get_last_message()
        assert user1_last is not None
        assert "User1Name" in user1_last.text

        user2_last = user2.get_last_message()
        assert user2_last is not None
        assert "Welcome" in user2_last.text


class TestRequestCapturing:
    """Test request capturing functionality."""

    async def test_capture_all_requests(self, full_client):
        """Test that all requests are captured."""
        user = full_client.create_user()

        await user.send_command("start")
        await user.click_button("begin")

        all_requests = full_client.capture.all_requests
        assert len(all_requests) >= 2

    async def test_count_message_types(self, full_client):
        """Test counting different message types."""
        from aiogram_test_framework.types import RequestType

        user = full_client.create_user()

        await user.send_command("start")
        await user.send_command("help")

        msg_count = full_client.capture.count_by_type(RequestType.SEND_MESSAGE)
        assert msg_count == 2


class TestAsyncBotTestMixin:
    """Test the AsyncBotTestMixin class."""

    async def test_setup_client(self):
        """Test setup_client method."""
        mixin = AsyncBotTestMixin()

        client = await mixin.setup_client(
            setup_dispatcher_func=create_full_dispatcher,
        )

        assert isinstance(client, TestClient)
        assert client.bot is not None

        await client.close()

    def test_reset_factories(self):
        """Test reset_factories method."""
        from aiogram_test_framework.factories import UserFactory

        mixin = AsyncBotTestMixin()

        UserFactory.create()
        UserFactory.create()

        mixin.reset_factories()

        user = UserFactory.create()
        assert user.id == 100000


class TestClientReset:
    """Test client reset functionality."""

    async def test_reset_between_tests(self, full_client):
        """Test that reset properly clears state."""
        user = full_client.create_user()

        await user.send_command("start")

        assert len(full_client.capture) > 0

        full_client.reset()

        assert len(full_client.capture) == 0

        user = full_client.create_user()
        responses = await user.send_command("help")

        assert len(responses) == 1
        assert len(full_client.capture) == 1


class TestEdgeCases:
    """Test edge cases and error handling."""

    async def test_empty_message(self, full_client):
        """Test handling empty messages."""
        user = full_client.create_user()

        responses = await user.send_message("")
        assert len(responses) == 1

    async def test_very_long_message(self, full_client):
        """Test handling very long messages."""
        user = full_client.create_user()

        long_text = "A" * 4096
        responses = await user.send_message(long_text)
        assert len(responses) == 1

    async def test_special_characters(self, full_client):
        """Test handling special characters in messages."""
        user = full_client.create_user()

        responses = await user.send_message("Hello <script>alert('xss')</script>")
        assert len(responses) == 1

    async def test_unicode_message(self, full_client):
        """Test handling unicode messages."""
        user = full_client.create_user()

        responses = await user.send_message("Привіт 🇺🇦 мир 🌍")
        assert len(responses) == 1
