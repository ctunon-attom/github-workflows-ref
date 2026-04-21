import pytest
from django.test import Client
from django.urls import reverse

from taskapp.models import Task


@pytest.fixture
def client():
    return Client()


@pytest.mark.django_db
class TestTaskList:
    def test_returns_200(self, client):
        response = client.get(reverse("taskapp:task_list"))
        assert response.status_code == 200

    def test_shows_tasks(self, client, task):
        response = client.get(reverse("taskapp:task_list"))
        assert task.title in response.content.decode()

    def test_htmx_returns_partial(self, client, task):
        response = client.get(reverse("taskapp:task_list"), HTTP_HX_REQUEST="true")
        assert response.status_code == 200
        content = response.content.decode()
        assert task.title in content
        assert "<html" not in content


@pytest.mark.django_db
class TestTaskCreate:
    def test_get_form(self, client):
        response = client.get(reverse("taskapp:task_create"))
        assert response.status_code == 200

    def test_post_creates_task(self, client):
        response = client.post(
            reverse("taskapp:task_create"),
            {"title": "New task", "description": ""},
        )
        assert response.status_code == 302
        assert Task.objects.filter(title="New task").exists()

    def test_htmx_post_returns_partial(self, client):
        response = client.post(
            reverse("taskapp:task_create"),
            {"title": "HTMX task", "description": ""},
            HTTP_HX_REQUEST="true",
        )
        assert response.status_code == 200
        assert "HTMX task" in response.content.decode()

    def test_empty_title_rejected(self, client):
        response = client.post(
            reverse("taskapp:task_create"),
            {"title": "", "description": ""},
        )
        assert response.status_code == 200
        assert not Task.objects.exists()


@pytest.mark.django_db
class TestTaskUpdate:
    def test_get_form(self, client, task):
        response = client.get(reverse("taskapp:task_update", args=[task.pk]))
        assert response.status_code == 200

    def test_post_updates_task(self, client, task):
        response = client.post(
            reverse("taskapp:task_update", args=[task.pk]),
            {"title": "Updated", "description": "new desc"},
        )
        assert response.status_code == 302
        task.refresh_from_db()
        assert task.title == "Updated"


@pytest.mark.django_db
class TestTaskDelete:
    def test_get_confirm(self, client, task):
        response = client.get(reverse("taskapp:task_delete", args=[task.pk]))
        assert response.status_code == 200

    def test_post_deletes(self, client, task):
        pk = task.pk
        response = client.post(reverse("taskapp:task_delete", args=[pk]))
        assert response.status_code == 302
        assert not Task.objects.filter(pk=pk).exists()

    def test_htmx_post_returns_empty(self, client, task):
        pk = task.pk
        response = client.post(
            reverse("taskapp:task_delete", args=[pk]),
            HTTP_HX_REQUEST="true",
        )
        assert response.status_code == 200
        assert response.content == b""


@pytest.mark.django_db
class TestTaskToggle:
    def test_toggle_on(self, client, task):
        response = client.post(reverse("taskapp:task_toggle", args=[task.pk]))
        assert response.status_code == 302
        task.refresh_from_db()
        assert task.completed is True

    def test_toggle_off(self, client, completed_task):
        response = client.post(reverse("taskapp:task_toggle", args=[completed_task.pk]))
        assert response.status_code == 302
        completed_task.refresh_from_db()
        assert completed_task.completed is False

    def test_get_redirects(self, client, task):
        response = client.get(reverse("taskapp:task_toggle", args=[task.pk]))
        assert response.status_code == 302


class TestHealth:
    def test_returns_ok(self, client):
        response = client.get(reverse("taskapp:health"))
        assert response.status_code == 200
        assert response.json() == {"status": "ok"}
