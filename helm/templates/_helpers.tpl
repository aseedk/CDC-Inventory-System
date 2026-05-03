{{/*
Common labels added to every resource.
*/}}
{{- define "cdc.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels for a named component.
Usage: {{ include "cdc.selectorLabels" "postgres-source" }}
*/}}
{{- define "cdc.selectorLabels" -}}
app.kubernetes.io/name: {{ . }}
{{- end }}

{{/*
Service type helper — returns NodePort when a nodePort value is set, else ClusterIP.
Usage: {{ include "cdc.serviceType" .Values.grafana.service.nodePort }}
*/}}
{{- define "cdc.serviceType" -}}
{{- if . -}}NodePort{{- else -}}ClusterIP{{- end -}}
{{- end }}
