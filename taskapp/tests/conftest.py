import pytest

from taskapp.tests.factories import TaskFactory


@pytest.fixture
def task():
    return TaskFactory()


@pytest.fixture
def completed_task():
    return TaskFactory(completed=True)
