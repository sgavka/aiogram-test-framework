# Aiogram Test Framework

A testing framework for Aiogram 3.x Telegram bots that provides:

- Mocking the Telegram Bot API
- Capturing all outgoing bot requests
- Simulating user interactions
- Testing handlers with full middleware chain

## Installation

```bash
pip install aiogram-test-framework
```

## Quick Start

```python
import pytest
from aiogram import Bot, Dispatcher
from aiogram_test_framework import AsyncBotTestMixin


def setup_dispatcher(bot: Bot, dispatcher: Dispatcher) -> None:
    """Configure dispatcher with middlewares and handlers."""
    # Your setup code here
    pass


class TestMyHandler(AsyncBotTestMixin):
    @pytest.fixture(autouse=True)
    async def setup(self):
        self.client = await self.setup_client(
            setup_dispatcher_func=setup_dispatcher,
        )
        yield
        await self.client.close()
        self.reset_factories()

    async def test_start_command(self):
        user = self.client.create_user()
        await user.send_command("start")
        assert user.has_received_message_containing("Welcome")
```

## Components

### TestClient

High-level test client for interacting with an Aiogram bot.

```python
from aiogram_test_framework import TestClient

# Create client
client = await TestClient.create(
    bot_token="123456:ABC-DEF",
    bot_id=123456,
    bot_username="test_bot",
    bot_first_name="Test Bot",
    setup_dispatcher_func=setup_dispatcher,
)

# Create users and interact
user = client.create_user()
await user.send_command("start")
assert user.has_received_message_containing("Welcome")

# Close when done
await client.close()
```

### MockBot

A mock Bot that captures all API requests for testing.

```python
from aiogram_test_framework import MockBot, RequestCapture

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
assert messages[0].text == "Hello"
```

### RequestCapture

Captures and stores all requests made by the bot to the Telegram API.

```python
from aiogram_test_framework import RequestCapture, RequestType

capture = RequestCapture()

# After bot makes requests...
messages = capture.get_sent_messages()
messages = capture.get_sent_messages(chat_id=12345)  # Filter by chat
edited = capture.get_edited_messages()
deleted = capture.get_deleted_messages()
callbacks = capture.get_callback_answers()
dice_sends = capture.get_dice_sends()

# Get last message
last = capture.get_last_message()
last_in_chat = capture.get_last_message(chat_id=12345)

# Check content
has_welcome = capture.has_message_containing("Welcome")
has_welcome = capture.has_message_containing("Welcome", chat_id=12345)

# Get by type
all_sends = capture.get_by_type(RequestType.SEND_MESSAGE)
count = capture.count_by_type(RequestType.SEND_MESSAGE)

# Clear for next test
capture.clear()
```

### TestUser

Represents a simulated Telegram user that can interact with the bot.

```python
# Create via client
user = client.create_user(user_id=12345, first_name="John")

# Send messages/commands
responses = await user.send_message("Hello bot")
responses = await user.send_command("start")
responses = await user.send_command("start", args="referral_code")

# Click inline buttons
responses = await user.click_button("callback_data")

# Check responses
messages = user.get_sent_messages()
last = user.get_last_message()
has_welcome = user.has_received_message_containing("Welcome")
```

## Factories

The framework provides factories for creating mock Telegram objects:

- `UserFactory` - Create mock User objects
- `ChatFactory` - Create mock Chat objects
- `MessageFactory` - Create mock Message objects
- `CallbackQueryFactory` - Create mock CallbackQuery objects
- `UpdateFactory` - Create mock Update objects
- `KeyboardFactory` - Create mock keyboard markups

```python
from aiogram_test_framework import UserFactory, MessageFactory

# Create user
user = UserFactory.create(
    user_id=12345,
    first_name="John",
    username="johndoe",
)

# Create message
message = MessageFactory.create(
    text="Hello!",
    from_user=user,
)

# Create command
command = MessageFactory.create_command(
    command="start",
    from_user=user,
    args="ref123",
)
```

## Usage with Different Test Frameworks

### pytest

```python
import pytest
from aiogram_test_framework import AsyncBotTestMixin


class TestMyHandler(AsyncBotTestMixin):
    @pytest.fixture(autouse=True)
    async def setup(self):
        self.client = await self.setup_client(
            setup_dispatcher_func=setup_dispatcher,
        )
        yield
        await self.client.close()
        self.reset_factories()

    async def test_start_command(self):
        user = self.client.create_user()
        await user.send_command("start")
        assert user.has_received_message_containing("Welcome")
```

### unittest

```python
import asyncio
import unittest
from aiogram_test_framework import AsyncBotTestMixin


class TestMyHandler(unittest.TestCase, AsyncBotTestMixin):
    def setUp(self):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self.client = self.loop.run_until_complete(
            self.setup_client(setup_dispatcher_func=setup_dispatcher)
        )

    def tearDown(self):
        if hasattr(self, 'client') and self.client:
            self.loop.run_until_complete(self.client.close())
        self.reset_factories()
        self.loop.close()

    def test_start_command(self):
        async def run_test():
            user = self.client.create_user()
            await user.send_command("start")
            assert user.has_received_message_containing("Welcome")

        self.loop.run_until_complete(run_test())
```

### Django

```python
from asgiref.sync import async_to_sync
from django.test import TransactionTestCase
from aiogram_test_framework import AsyncBotTestMixin


class TestMyHandler(TransactionTestCase, AsyncBotTestMixin):
    def setUp(self) -> None:
        async_to_sync(self._async_setup)()

    def tearDown(self) -> None:
        async_to_sync(self._async_teardown)()

    async def _async_setup(self) -> None:
        self.client = await self.setup_client(
            setup_dispatcher_func=setup_dispatcher,
        )

    async def _async_teardown(self) -> None:
        await self.client.close()
        self.reset_factories()

    async def test_start_command(self) -> None:
        user = self.client.create_user()
        await user.send_command("start")
        assert user.has_received_message_containing("Welcome")
```

## License

MIT

## Todos
- [x] Add tests
- [ ] Tests with different Aiogram versions
