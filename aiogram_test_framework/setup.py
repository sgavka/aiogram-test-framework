"""
Test setup utilities for configuring the bot testing environment.

This module provides generic utilities for creating test dispatchers.
Project-specific setup (middlewares, handlers, container overrides) should
be done directly in tests using your own bot helpers.
"""

from aiogram import Dispatcher
from aiogram.fsm.storage.memory import MemoryStorage


def create_test_dispatcher() -> Dispatcher:
    """
    Create a test dispatcher with in-memory storage.

    Returns:
        Dispatcher instance with MemoryStorage
    """
    storage = MemoryStorage()
    return Dispatcher(storage=storage)
