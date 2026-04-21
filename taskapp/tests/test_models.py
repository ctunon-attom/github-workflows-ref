import pytest

from taskapp.models import Task
from taskapp.tests.factories import TaskFactory


@pytest.mark.django_db
class TestTaskModel:
    def test_str(self, task):
        assert str(task) == task.title

    def test_default_completed_is_false(self):
        task = TaskFactory()
        assert task.completed is False

    def test_ordering_newest_first(self):
        old = TaskFactory(title="old")
        new = TaskFactory(title="new")
        tasks = list(Task.objects.all())
        assert tasks[0] == new
        assert tasks[1] == old

    def test_blank_description_allowed(self):
        task = TaskFactory(description="")
        task.full_clean()
        assert task.description == ""
