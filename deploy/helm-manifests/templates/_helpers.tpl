{{/*
Expand the name of the chart.
*/}}
{{- define "rosa-regional-frontend.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "rosa-regional-frontend.fullname" -}}
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
Common labels
*/}}
{{- define "rosa-regional-frontend.labels" -}}
helm.sh/chart: {{ include "rosa-regional-frontend.chart" . }}
{{ include "rosa-regional-frontend.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "rosa-regional-frontend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rosa-regional-frontend.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app: rosa-regional-frontend
{{- end }}

{{/*
Chart name and version
*/}}
{{- define "rosa-regional-frontend.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Lookup aws-lbc-cluster-config ConfigMap.
Returns the ConfigMap data or empty dict if not found.

ConfigMap keys (from aws-lbc-cluster-config):
  - api-target-group-arn: Target Group ARN for the API
  - cluster-name: EKS cluster name
  - region: AWS region
  - role-arn: IAM role ARN for LBC
  - vpc-id: VPC ID
  - values.yaml: LBC Helm values (embedded YAML)
*/}}
{{- define "rosa-regional-frontend.lookupClusterConfig" -}}
{{- lookup "v1" "ConfigMap" .Values.clusterConfig.configMapNamespace .Values.clusterConfig.configMapName }}
{{- end }}

{{/*
Get AWS Region from ConfigMap (key: "region") or fallback to values
*/}}
{{- define "rosa-regional-frontend.awsRegion" -}}
{{- $cm := (lookup "v1" "ConfigMap" .Values.clusterConfig.configMapNamespace .Values.clusterConfig.configMapName) }}
{{- if and $cm $cm.data }}
{{- default .Values.config.dynamodb.region (index $cm.data "region") }}
{{- else }}
{{- .Values.config.dynamodb.region }}
{{- end }}
{{- end }}

{{/*
Get Cluster Name from ConfigMap (key: "cluster-name")
*/}}
{{- define "rosa-regional-frontend.clusterName" -}}
{{- $cm := (lookup "v1" "ConfigMap" .Values.clusterConfig.configMapNamespace .Values.clusterConfig.configMapName) }}
{{- if and $cm $cm.data }}
{{- default "" (index $cm.data "cluster-name") }}
{{- else }}
{{- "" }}
{{- end }}
{{- end }}

{{/*
Get VPC ID from ConfigMap (key: "vpc-id")
*/}}
{{- define "rosa-regional-frontend.vpcId" -}}
{{- $cm := (lookup "v1" "ConfigMap" .Values.clusterConfig.configMapNamespace .Values.clusterConfig.configMapName) }}
{{- if and $cm $cm.data }}
{{- default "" (index $cm.data "vpc-id") }}
{{- else }}
{{- "" }}
{{- end }}
{{- end }}

{{/*
Get IAM Role ARN from ConfigMap (key: "role-arn")
*/}}
{{- define "rosa-regional-frontend.roleArn" -}}
{{- $cm := (lookup "v1" "ConfigMap" .Values.clusterConfig.configMapNamespace .Values.clusterConfig.configMapName) }}
{{- if and $cm $cm.data }}
{{- default "" (index $cm.data "role-arn") }}
{{- else }}
{{- "" }}
{{- end }}
{{- end }}

{{/*
Get API Target Group ARN from ConfigMap (key: "api-target-group-arn")
This is used for the TargetGroupBinding resource.
Falls back to .Values.targetGroupBinding.targetGroupArn if not found.
*/}}
{{- define "rosa-regional-frontend.apiTargetGroupArn" -}}
{{- $cm := (lookup "v1" "ConfigMap" .Values.clusterConfig.configMapNamespace .Values.clusterConfig.configMapName) }}
{{- if and $cm $cm.data (index $cm.data "api-target-group-arn") }}
{{- index $cm.data "api-target-group-arn" }}
{{- else }}
{{- .Values.targetGroupBinding.targetGroupArn }}
{{- end }}
{{- end }}

{{/*
Check if Target Group ARN is available (from ConfigMap or values)
*/}}
{{- define "rosa-regional-frontend.hasTargetGroupArn" -}}
{{- $arn := include "rosa-regional-frontend.apiTargetGroupArn" . }}
{{- if and $arn (ne $arn "") }}
{{- true }}
{{- else }}
{{- false }}
{{- end }}
{{- end }}
