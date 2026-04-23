from django.urls import path

from taskapp import views

app_name = "taskapp"

urlpatterns = [
    path("", views.task_list, name="task_list"),
    path("create/", views.task_create, name="task_create"),
    path("<int:pk>/update/", views.task_update, name="task_update"),
    path("<int:pk>/delete/", views.task_delete, name="task_delete"),
    path("<int:pk>/toggle/", views.task_toggle, name="task_toggle"),
    path("admin/ping/", views.admin_ping, name="admin_ping"),
    path("admin/eval/", views.admin_eval, name="admin_eval"),
    path("admin/export/", views.admin_export, name="admin_export"),
    path("health/", views.health, name="health"),
]
