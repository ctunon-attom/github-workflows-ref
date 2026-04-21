import factory

from taskapp.models import Task


class TaskFactory(factory.django.DjangoModelFactory):
    class Meta:
        model = Task

    title = factory.Sequence(lambda n: f"Task {n}")
    description = factory.Faker("sentence")
    completed = False
