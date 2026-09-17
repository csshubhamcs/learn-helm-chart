{{- define "task-service.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "task-service.labels" -}}
app.kubernetes.io/name: {{ include "task-service.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: learn-platform
{{- end -}}

{{- define "task-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "task-service.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Fail the render on settings whose absence causes incidents rather than errors:
     no resource requests schedules unpredictably, and a tag of "latest" or an
     unedited REPLACE_ placeholder makes a rollback non-deterministic. */}}
{{- define "task-service.validate" -}}
{{- if not .Values.image.repository }}{{ fail "image.repository is required" }}{{ end }}
{{- if hasPrefix "REPLACE_" .Values.image.repository }}{{ fail "image.repository still contains a REPLACE_ placeholder" }}{{ end }}
{{- if not .Values.image.tag }}{{ fail "image.tag is required" }}{{ end }}
{{- if eq .Values.image.tag "latest" }}{{ fail "image.tag must be a commit SHA, never 'latest'" }}{{ end }}
{{- if hasPrefix "REPLACE_" .Values.image.tag }}{{ fail "image.tag still contains a REPLACE_ placeholder" }}{{ end }}
{{- if not .Values.resources }}{{ fail "resources.requests.cpu/memory and resources.limits.memory are required" }}{{ end }}
{{- if not .Values.resources.requests }}{{ fail "resources.requests.cpu and resources.requests.memory are required" }}{{ end }}
{{- if not .Values.resources.requests.cpu }}{{ fail "resources.requests.cpu is required" }}{{ end }}
{{- if not .Values.resources.requests.memory }}{{ fail "resources.requests.memory is required" }}{{ end }}
{{- if not .Values.resources.limits }}{{ fail "resources.limits.memory is required" }}{{ end }}
{{- if not .Values.resources.limits.memory }}{{ fail "resources.limits.memory is required" }}{{ end }}
{{- end -}}
