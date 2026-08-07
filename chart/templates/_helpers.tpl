{{/*
Resource names are FIXED, not derived from the release name.

The documentation, the NetworkPolicy selectors and the OTLP
endpoint your central collector exports to all name these two workloads
literally. Prefixing them with a release name would make every documented
kubectl command wrong for half the installs. One namespace, one Edge Proxy, one
collector; install a second copy in a second namespace if you need one.
*/}}
{{- define "dash0edge.proxyName" -}}dash0-edge-proxy{{- end -}}
{{- define "dash0edge.collectorName" -}}dash0-edge-collector{{- end -}}
{{- define "dash0edge.secretName" -}}dash0-edge-credentials{{- end -}}
{{- define "dash0edge.generatorName" -}}gen-checkout{{- end -}}

{{/* Labels carried by every object in the release. */}}
{{- define "dash0edge.commonLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: dash0-signal-control
{{- end -}}

{{/*
Required inputs. Failing here rather than at pod start is the point: a missing
dataset produces a collector that looks healthy and matches no rules.
*/}}
{{- define "dash0edge.dataset" -}}
{{- if not .Values.dash0.dataset -}}
{{- fail "\n\ndash0.dataset is required.\n\n  --set dash0.dataset=<your-dataset-slug>\n\nThe dataset must already exist in Dash0, and your sampling rules and spam\nfilters must live in it: rules are looked up by dataset.\n" -}}
{{- end -}}
{{- .Values.dash0.dataset -}}
{{- end -}}

{{- define "dash0edge.tokenSecretName" -}}
{{- if .Values.dash0.token.existingSecret -}}
{{- .Values.dash0.token.existingSecret -}}
{{- else if .Values.dash0.token.value -}}
{{- include "dash0edge.secretName" . -}}
{{- else -}}
{{- fail "\n\nA Dash0 auth token is required. Supply exactly one of:\n\n  --set dash0.token.value=auth_xxxxxxxx\n  --set dash0.token.existingSecret=<secret-name>   # key: token\n" -}}
{{- end -}}
{{- end -}}

{{- define "dash0edge.tokenSecretKey" -}}
{{- if .Values.dash0.token.existingSecret -}}
{{- required "dash0.token.existingSecretKey must not be empty when dash0.token.existingSecret is set" .Values.dash0.token.existingSecretKey -}}
{{- else -}}
token
{{- end -}}
{{- end -}}

{{/* Create the Secret only when the chart owns the token. */}}
{{- define "dash0edge.createSecret" -}}
{{- if and .Values.dash0.token.value (not .Values.dash0.token.existingSecret) -}}true{{- end -}}
{{- end -}}

{{/*
Endpoints. Each explicit override wins over the region plus domain derivation,
so retargeting the whole install is one value.
*/}}
{{- define "dash0edge.region" -}}
{{- required "dash0.region is required, for example eu-west-1" .Values.dash0.region -}}
{{- end -}}

{{- define "dash0edge.domain" -}}
{{- required "dash0.domain is required, for example aws.dash0.com" .Values.dash0.domain -}}
{{- end -}}

{{- define "dash0edge.apiEndpoint" -}}
{{- with .Values.dash0.endpoints.api -}}
{{- . -}}
{{- else -}}
{{- printf "https://api.%s.%s" (include "dash0edge.region" $) (include "dash0edge.domain" $) -}}
{{- end -}}
{{- end -}}

{{- define "dash0edge.otlpEndpoint" -}}
{{- with .Values.dash0.endpoints.otlpIngress -}}
{{- . -}}
{{- else -}}
{{- printf "ingress.%s.%s:4317" (include "dash0edge.region" $) (include "dash0edge.domain" $) -}}
{{- end -}}
{{- end -}}

{{- define "dash0edge.decisionMakerEndpoint" -}}
{{- with .Values.dash0.endpoints.decisionMaker -}}
{{- . -}}
{{- else -}}
{{- printf "decision-maker.%s.%s:443" (include "dash0edge.region" $) (include "dash0edge.domain" $) -}}
{{- end -}}
{{- end -}}

{{- define "dash0edge.edgeProxyEndpoint" -}}
{{- with .Values.collector.edgeProxyEndpoint -}}
{{- . -}}
{{- else -}}
{{- printf "%s.%s.svc.cluster.local:8011" (include "dash0edge.proxyName" $) $.Release.Namespace -}}
{{- end -}}
{{- end -}}

{{- define "dash0edge.collectorEndpoint" -}}
{{- printf "%s.%s.svc.cluster.local:4317" (include "dash0edge.collectorName" .) .Release.Namespace -}}
{{- end -}}

{{- define "dash0edge.proxyImage" -}}
{{- printf "%s:%s" .Values.edgeProxy.image.repository (default .Chart.AppVersion .Values.edgeProxy.image.tag) -}}
{{- end -}}

{{- define "dash0edge.collectorImage" -}}
{{- printf "%s:%s" .Values.collector.image.repository (default .Chart.AppVersion .Values.collector.image.tag) -}}
{{- end -}}

{{/*
The rendered collector configuration. Held in a named template so the ConfigMap
and the pod template checksum hash the identical string.
*/}}
{{- define "dash0edge.collectorConfig" -}}
{{- tpl (.Files.Get "files/collector-config.yaml") . -}}
{{- end -}}

{{/*
Whole release validation, invoked from NOTES.txt so it runs even when both
workloads are disabled.
*/}}
{{- define "dash0edge.validate" -}}
{{- $_ := include "dash0edge.dataset" . -}}
{{- $_ = include "dash0edge.tokenSecretName" . -}}
{{- if and .Values.dash0.token.value .Values.dash0.token.existingSecret -}}
{{- fail "\n\ndash0.token.value and dash0.token.existingSecret are mutually exclusive. Set one.\n" -}}
{{- end -}}
{{- if and (eq .Release.Namespace "default") (not .Values.namespace.allowDefault) -}}
{{- fail "\n\nRefusing to install into the `default` namespace.\n\n  helm install signal-control-edge . --namespace dash0-signal-control --create-namespace ...\n\nEvery documented command assumes a dedicated namespace. Set\nnamespace.allowDefault=true if you really mean `default`.\n" -}}
{{- end -}}
{{- end -}}

{{/*
Does the target namespace carry Pod Security Standard labels? `lookup` returns
an empty map under `helm template`, so this only ever fires against a live
cluster.
*/}}
{{- define "dash0edge.namespaceMissingPSS" -}}
{{- $ns := lookup "v1" "Namespace" "" .Release.Namespace -}}
{{- if not (and $ns (hasKey (default dict $ns.metadata.labels) "pod-security.kubernetes.io/enforce")) -}}true{{- end -}}
{{- end -}}
