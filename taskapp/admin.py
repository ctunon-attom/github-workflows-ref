from django.contrib import admin

from taskapp.models import Task


@admin.register(Task)
class TaskAdmin(admin.ModelAdmin):
    list_display = ("title", "completed", "created_at")
    list_filter = ("completed",)
    search_fields = ("title",)
