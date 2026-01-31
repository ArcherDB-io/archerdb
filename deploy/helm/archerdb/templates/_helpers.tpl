{{/*
ArcherDB Helm Chart Helpers
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "archerdb.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this.
If release name contains chart name it will be used as a full name.
*/}}
{{- define "archerdb.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "archerdb.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "archerdb.labels" -}}
helm.sh/chart: {{ include "archerdb.chart" . }}
{{ include "archerdb.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "archerdb.selectorLabels" -}}
app.kubernetes.io/name: {{ include "archerdb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "archerdb.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "archerdb.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Generate comma-separated addresses for all replicas.
Format: fullname-0.fullname-headless:port,fullname-1.fullname-headless:port,...
*/}}
{{- define "archerdb.addresses" -}}
{{- $fullname := include "archerdb.fullname" . -}}
{{- $port := .Values.ports.client -}}
{{- $addresses := list -}}
{{- range $i := until (int .Values.replicaCount) -}}
{{- $addresses = append $addresses (printf "%s-%d.%s-headless:%d" $fullname $i $fullname (int $port)) -}}
{{- end -}}
{{- join "," $addresses -}}
{{- end }}

{{/*
Container image with tag defaulting to Chart appVersion
*/}}
{{- define "archerdb.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end }}

{{/*
Headless service name for StatefulSet DNS
*/}}
{{- define "archerdb.headlessServiceName" -}}
{{- printf "%s-headless" (include "archerdb.fullname" .) -}}
{{- end }}
