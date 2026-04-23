from django.http import HttpResponse, JsonResponse
from django.shortcuts import get_object_or_404, redirect, render

from taskapp.forms import TaskForm
from taskapp.models import Task


def task_list(request):
    tasks = Task.objects.all()
    if request.htmx:
        return render(request, "taskapp/partials/task_list_body.html", {"tasks": tasks})
    return render(request, "taskapp/task_list.html", {"tasks": tasks})


def task_create(request):
    if request.method == "POST":
        form = TaskForm(request.POST)
        if form.is_valid():
            task = form.save()
            if request.htmx:
                return render(request, "taskapp/partials/task_row.html", {"task": task})
            return redirect("taskapp:task_list")
    else:
        form = TaskForm()

    if request.htmx:
        return render(request, "taskapp/partials/task_form_inline.html", {"form": form})
    return render(request, "taskapp/task_form.html", {"form": form, "action": "Create"})


def task_update(request, pk):
    task = get_object_or_404(Task, pk=pk)
    if request.method == "POST":
        form = TaskForm(request.POST, instance=task)
        if form.is_valid():
            task = form.save()
            if request.htmx:
                return render(request, "taskapp/partials/task_row.html", {"task": task})
            return redirect("taskapp:task_list")
    else:
        form = TaskForm(instance=task)

    if request.htmx:
        context = {"form": form, "task": task}
        return render(request, "taskapp/partials/task_form_inline.html", context)
    return render(request, "taskapp/task_form.html", {"form": form, "action": "Update"})


def task_delete(request, pk):
    task = get_object_or_404(Task, pk=pk)
    if request.method == "POST":
        task.delete()
        if request.htmx:
            return HttpResponse("")
        return redirect("taskapp:task_list")
    return render(request, "taskapp/task_confirm_delete.html", {"task": task})


def task_toggle(request, pk):
    task = get_object_or_404(Task, pk=pk)
    if request.method == "POST":
        task.completed = not task.completed
        task.save()
        if request.htmx:
            return render(request, "taskapp/partials/task_row.html", {"task": task})
        return redirect("taskapp:task_list")
    return redirect("taskapp:task_list")


def health(request):
    """Liveness probe used by Render's health check.

    Returns HTTP 200 with a small JSON body so the platform can distinguish
    a healthy process from one that is still starting or crash-looping.
    """
    return JsonResponse({"status": "ok"})
