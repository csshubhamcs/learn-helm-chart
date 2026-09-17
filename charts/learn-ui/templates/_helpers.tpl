{{- define "learn-ui.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "learn-ui.labels" -}}
app.kubernetes.io/name: {{ include "learn-ui.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: learn-platform
{{- end -}}

{{- define "learn-ui.selectorLabels" -}}
app.kubernetes.io/name: {{ include "learn-ui.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Fail the render on settings whose absence causes incidents rather than errors:
     no resource requests schedules unpredictably, and a tag of "latest" or an
     unedited REPLACE_ placeholder makes a rollback non-deterministic. */}}
{{- define "learn-ui.validate" -}}
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
{{/* These are browser-facing URLs written into /config.js at container start-up. Empty ones
     fail in the VISITOR's browser, long after a successful deploy, so catch them here. */}}
{{- if not .Values.env.KEYCLOAK_URL }}{{ fail "env.KEYCLOAK_URL is required (the public Keycloak URL the browser will use)" }}{{ end }}
{{- if not .Values.env.USER_API }}{{ fail "env.USER_API is required" }}{{ end }}
{{- if not .Values.env.TASK_API }}{{ fail "env.TASK_API is required" }}{{ end }}
{{- if hasPrefix "http://" .Values.env.KEYCLOAK_URL }}{{ fail "env.KEYCLOAK_URL must be https — tokens would travel in clear text" }}{{ end }}
{{- end -}}
