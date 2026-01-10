# Claude Code Session Notes

<project-context>
This is the aiogram-test-framework project - a testing framework for Aiogram 3.x Telegram bots.
</project-context>

<development-rules>
<rule name="running-tests">
Always use the virtual environment to run tests:
```bash
.venv/bin/pytest
```
For specific tests:
```bash
.venv/bin/pytest tests/test_mock_bot.py -v -k "dice"
```
</rule>

<rule name="code-patterns">
Follow existing patterns when adding new features:
- Send methods are mocked in `MockSession._generate_response()`
- Request types are defined in `types.py` as `RequestType` enum
- Captured requests use `CapturedRequest` dataclass
- Factories for creating test objects are in `factories.py`
</rule>

<rule name="architecture">
The framework has these core components:
- `MockSession` - Intercepts all Telegram API calls
- `MockBot` - Wraps MockSession as a Bot
- `RequestCapture` - Stores all captured requests
- `TestClient` - High-level test interface
- `TestUser` - Simulates user interactions
- Factories - Create test objects (User, Chat, Message, etc.)
</rule>

<rule name="adding-new-send-methods">
When adding support for new send methods (e.g., sendDocument, sendLocation):
1. Add the method response in `MockSession._generate_response()`
2. Add corresponding `RequestType` enum value in `types.py` if not exists
3. Add getter method in `RequestCapture` (e.g., `get_document_sends()`)
4. Add tests in `tests/test_mock_bot.py`
5. Update README.md with examples if needed
</rule>

<rule name="controlling-mock-values">
For methods that return random/dynamic values (like dice), use the queue pattern:
- Add a list to store queued values: `self._next_xxx_values: list[Type] = []`
- Add `set_next_xxx_value(value)` method to queue values
- Add `_get_next_xxx_value()` method to pop from queue or return random by default
- Expose through MockBot and TestClient for convenience

Example - Dice values:
- By default, dice return random values based on emoji type (1-6 for 🎲, 1-5 for 🏀/⚽, 1-64 for 🎰)
- Use `client.set_next_dice_value(6)` to control the next dice value from bot
- Use `user.send_dice(value=6)` to send a dice with specific value from user
- Multiple values can be queued: they are consumed in FIFO order
</rule>

<rule name="testing">
All code must have tests:
- Tests are in the `tests/` directory
- Use pytest with `asyncio_mode = "auto"`
- Follow existing test class naming: `TestClassName`
- Follow existing test method naming: `test_method_name`
- Use fixtures from `conftest.py` (e.g., `capture`)
</rule>

<rule name="imports">
Follow the existing import style:
- Group imports: stdlib, third-party (aiogram), local
- Use absolute imports for local modules
- Export public API from `__init__.py`
</rule>
</development-rules>

<common-tasks>
<task name="run-all-tests">
```bash
.venv/bin/pytest
```
</task>

<task name="run-tests-with-coverage">
```bash
.venv/bin/pytest --cov=aiogram_test_framework --cov-report=term-missing
```
</task>

<task name="run-specific-test-file">
```bash
.venv/bin/pytest tests/test_mock_bot.py -v
```
</task>

<task name="run-tests-matching-pattern">
```bash
.venv/bin/pytest -v -k "dice"
```
</task>

<task name="install-dev-dependencies">
```bash
.venv/bin/pip install -e ".[dev]"
```
</task>
</common-tasks>

<file-structure>
```
aiogram_test_framework/
  __init__.py          # Public API exports
  base.py              # AsyncBotTestMixin for test integration
  client.py            # TestClient - high-level testing interface
  factories.py         # Object factories (User, Chat, Message, etc.)
  mock_bot.py          # MockBot and MockSession for API mocking
  request_capture.py   # RequestCapture for tracking API calls
  setup.py             # Test dispatcher setup utilities
  types.py             # Type definitions and enums
  user.py              # TestUser for simulating user interactions

tests/
  conftest.py          # Pytest fixtures and setup
  test_*.py            # Test files
```
</file-structure>
