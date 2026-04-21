from django import forms

from taskapp.models import Task


class TaskForm(forms.ModelForm):
    class Meta:
        model = Task
        fields = ["title", "description"]
        widgets = {
            "title": forms.TextInput(attrs={"class": "form-input", "placeholder": "Task title"}),
            "description": forms.Textarea(
                attrs={"class": "form-textarea", "rows": 3, "placeholder": "Description (optional)"}
            ),
        }
