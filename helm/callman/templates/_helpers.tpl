{{/*
Core naming
*/}}
{{- define "callman.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "callman.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "callman.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Labels. Component-scoped variants take a dict: (dict "root" $ "component" "backend")
*/}}
{{- define "callman.labels" -}}
helm.sh/chart: {{ include "callman.chart" .root }}
app.kubernetes.io/name: {{ include "callman.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/part-of: callman
{{- with .root.Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "callman.selectorLabels" -}}
app.kubernetes.io/name: {{ include "callman.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
Image reference with airgap registry override.
Call: (dict "root" $ "image" .Values.backend.image)
When global.imageRegistry is set, the source registry HOST is replaced and the
repository path is kept (ghcr.io/yurdtech/x -> <internal>/yurdtech/x). Plain
Docker Hub names (mongo, redis) gain the library/ prefix under the override so
mirrors that require a full path keep working.
*/}}
{{- define "callman.image" -}}
{{- $reg := .root.Values.global.imageRegistry -}}
{{- $repo := .image.repository -}}
{{- $tag := .image.tag | default .root.Chart.AppVersion -}}
{{- if $reg -}}
{{- if contains "/" $repo -}}
{{- if regexMatch "^[^/]+[.:][^/]+/" $repo -}}
{{- printf "%s/%s:%s" $reg (regexReplaceAll "^[^/]+/" $repo "") $tag -}}
{{- else -}}
{{- printf "%s/%s:%s" $reg $repo $tag -}}
{{- end -}}
{{- else -}}
{{- printf "%s/library/%s:%s" $reg $repo $tag -}}
{{- end -}}
{{- else -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
{{- end -}}

{{/*
Pull secrets: global list + optionally the chart-rendered credentials secret.
*/}}
{{- define "callman.imagePullSecrets" -}}
{{- $secrets := .Values.global.imagePullSecrets -}}
{{- if .Values.imageCredentials.create -}}
{{- $secrets = append $secrets (printf "%s-registry" (include "callman.fullname" .)) -}}
{{- end -}}
{{- if $secrets }}
imagePullSecrets:
{{- range $secrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "callman.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "callman.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "callman.secretName" -}}
{{- if .Values.secrets.existingSecret -}}
{{- .Values.secrets.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "callman.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Effective URIs. Explicit external URI wins; otherwise built against the
bundled store. Only rendered into the chart Secret (they carry passwords) —
with existingSecret the customer supplies MONGODB_URI/REDIS_URL keys instead
(or relies on these defaults staying valid for the bundled stores).
*/}}
{{- define "callman.mongoUri" -}}
{{- if .Values.externalMongo.uri -}}
{{- .Values.externalMongo.uri -}}
{{- else -}}
{{- printf "mongodb://%s:%s@%s-mongo:27017/callman?authSource=admin" .Values.mongo.auth.rootUsername (required "secrets.values.MONGO_ROOT_PASSWORD is required with the bundled mongo (or use secrets.existingSecret with a MONGODB_URI key)" .Values.secrets.values.MONGO_ROOT_PASSWORD) (include "callman.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "callman.redisUrl" -}}
{{- if .Values.externalRedis.url -}}
{{- .Values.externalRedis.url -}}
{{- else -}}
{{- printf "redis://:%s@%s-redis:6379" (required "secrets.values.REDIS_PASSWORD is required with the bundled redis (or use secrets.existingSecret with a REDIS_URL key)" .Values.secrets.values.REDIS_PASSWORD) (include "callman.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "callman.backendApiUrl" -}}
{{- if .Values.admin.backendApiUrl -}}
{{- .Values.admin.backendApiUrl -}}
{{- else -}}
{{- printf "http://%s-backend:%d" (include "callman.fullname" .) (int .Values.backend.port) -}}
{{- end -}}
{{- end -}}

{{/*
Security contexts. UIDs are never pinned so OpenShift's restricted-v2 SCC can
assign an arbitrary UID; fsGroup only when explicitly configured.
*/}}
{{- define "callman.podSecurityContext" -}}
securityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
  {{- with .Values.podSecurityContext.fsGroup }}
  fsGroup: {{ . }}
  {{- end }}
{{- end -}}

{{- define "callman.containerSecurityContext" -}}
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
{{- end -}}

{{/*
Store pod security context: same non-root posture, but per-store fsGroup
(mongo/redis official images need a writable data dir under arbitrary UIDs).
Call with (dict "root" $ "store" .Values.mongo)
*/}}
{{- define "callman.storePodSecurityContext" -}}
securityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
  {{- $fsGroup := .store.podSecurityContext.fsGroup | default .root.Values.podSecurityContext.fsGroup }}
  {{- with $fsGroup }}
  fsGroup: {{ . }}
  {{- end }}
{{- end -}}

{{/*
extraEnv map -> env entries. Call with a map of NAME: value.
*/}}
{{- define "callman.extraEnv" -}}
{{- range $name, $value := . }}
- name: {{ $name }}
  value: {{ $value | quote }}
{{- end }}
{{- end -}}

{{/*
Shared envFrom for backend-family workloads (backend, worker, migrate,
ui-runner): common ConfigMap + the secret (compose parity: every service read
the same .env).
*/}}
{{- define "callman.sharedEnvFrom" -}}
envFrom:
  - configMapRef:
      name: {{ include "callman.fullname" . }}-env
  - secretRef:
      name: {{ include "callman.secretName" . }}
{{- end -}}

{{/*
Certs volume + mount (compose ./certs:/certs:ro parity). Rendered only when
any cert source is configured.
*/}}
{{- define "callman.certsVolume" -}}
{{- if or .Values.certs.existingConfigMap .Values.certs.files }}
- name: certs
  configMap:
    name: {{ .Values.certs.existingConfigMap | default (printf "%s-certs" (include "callman.fullname" .)) }}
{{- end }}
{{- end -}}

{{- define "callman.certsMount" -}}
{{- if or .Values.certs.existingConfigMap .Values.certs.files }}
- name: certs
  mountPath: /certs
  readOnly: true
{{- end }}
{{- end -}}

{{/*
Template-time validation — the preflight.sh equivalent. Included from
secret.yaml (inline-secret checks) and configmap.yaml (topology checks) so a
bad values file fails to render with an actionable message.
*/}}
{{- define "callman.validateTopology" -}}
{{- if and (not .Values.mongo.enabled) (not .Values.externalMongo.uri) (not .Values.secrets.existingSecret) -}}
{{- fail "MongoDB is not configured: set mongo.enabled=true, or externalMongo.uri, or provide MONGODB_URI via secrets.existingSecret" -}}
{{- end -}}
{{- if and .Values.mongo.enabled .Values.externalMongo.uri -}}
{{- fail "mongo.enabled and externalMongo.uri are mutually exclusive — disable the bundled mongo to use an external one" -}}
{{- end -}}
{{- if and (not .Values.redis.enabled) (not .Values.externalRedis.url) (not .Values.secrets.existingSecret) -}}
{{- fail "Redis is not configured: set redis.enabled=true, or externalRedis.url, or provide REDIS_URL via secrets.existingSecret" -}}
{{- end -}}
{{- if and .Values.redis.enabled .Values.externalRedis.url -}}
{{- fail "redis.enabled and externalRedis.url are mutually exclusive — disable the bundled redis to use an external one" -}}
{{- end -}}
{{- if and .Values.backend.ingress.enabled .Values.backend.route.enabled -}}
{{- fail "backend.ingress.enabled and backend.route.enabled are mutually exclusive (Ingress for vanilla k8s, Route for OpenShift)" -}}
{{- end -}}
{{- if and .Values.admin.ingress.enabled .Values.admin.route.enabled -}}
{{- fail "admin.ingress.enabled and admin.route.enabled are mutually exclusive (Ingress for vanilla k8s, Route for OpenShift)" -}}
{{- end -}}
{{- if gt (int .Values.admin.replicaCount) 1 -}}
{{- if ne (toString (get .Values.admin.extraEnv "RELEASE_REMINDERS_ENABLED" | default "")) "false" -}}
{{- fail "admin.replicaCount > 1 requires admin.extraEnv.RELEASE_REMINDERS_ENABLED=\"false\" — the @Cron reminder sweep must not run in every replica" -}}
{{- end -}}
{{- end -}}
{{- if .Values.uiRunner.enabled -}}
{{- $shm := include "callman.toBytes" .Values.uiRunner.shmSize | int64 -}}
{{- $limit := include "callman.toBytes" (dig "limits" "memory" "0" .Values.uiRunner.resources) | int64 -}}
{{- if and (gt $limit 0) (lt $limit $shm) -}}
{{- fail (printf "uiRunner.resources.limits.memory (%s) must be >= uiRunner.shmSize (%s): the in-memory /dev/shm counts against the container limit" (dig "limits" "memory" "?" .Values.uiRunner.resources) (toString .Values.uiRunner.shmSize)) -}}
{{- end -}}
{{- end -}}
{{- if and .Values.worker.mountBackups .Values.migrate.backup.enabled -}}
{{- if and (gt (int .Values.worker.replicaCount) 1) (not (has "ReadWriteMany" .Values.backup.persistence.accessModes)) -}}
{{- fail "worker.mountBackups with worker.replicaCount > 1 requires backup.persistence.accessModes to include ReadWriteMany" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Inline-secret validation (skipped entirely with existingSecret — runtime zod
validation and /health/ready remain the backstop there).
*/}}
{{- define "callman.validateSecrets" -}}
{{- if not .Values.secrets.existingSecret -}}
{{- $s := .Values.secrets.values -}}
{{- $backendKeys := list "JWT_SECRET" "JWT_REFRESH_SECRET" "SESSION_TOKEN_ENCRYPTION_SECRET" "CONNECTION_ENCRYPTION_KEY" -}}
{{- $seen := dict -}}
{{- range $k := $backendKeys -}}
{{- $v := get $s $k | default "" -}}
{{- if lt (len $v) 32 -}}
{{- fail (printf "secrets.values.%s must be set and at least 32 characters (generate with: openssl rand -hex 32)" $k) -}}
{{- end -}}
{{- if hasKey $seen $v -}}
{{- fail "the four backend secrets (JWT_SECRET, JWT_REFRESH_SECRET, SESSION_TOKEN_ENCRYPTION_SECRET, CONNECTION_ENCRYPTION_KEY) must be four DISTINCT values" -}}
{{- end -}}
{{- $_ := set $seen $v true -}}
{{- end -}}
{{- $adminKeys := list "ADMIN_JWT_SECRET" "ADMIN_JWT_REFRESH_SECRET" -}}
{{- $adminSeen := dict -}}
{{- range $k := $adminKeys -}}
{{- $v := get $s $k | default "" -}}
{{- if lt (len $v) 32 -}}
{{- fail (printf "secrets.values.%s must be set and at least 32 characters (generate with: openssl rand -hex 32)" $k) -}}
{{- end -}}
{{- if hasKey $adminSeen $v -}}
{{- fail "ADMIN_JWT_SECRET and ADMIN_JWT_REFRESH_SECRET must be two DISTINCT values" -}}
{{- end -}}
{{- $_ := set $adminSeen $v true -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Parse a k8s quantity (2Gi, 512Mi, 1073741824) into bytes for comparisons.
*/}}
{{- define "callman.toBytes" -}}
{{- $q := toString . -}}
{{- if hasSuffix "Gi" $q -}}{{- mulf (trimSuffix "Gi" $q | float64) 1073741824 | int64 -}}
{{- else if hasSuffix "Mi" $q -}}{{- mulf (trimSuffix "Mi" $q | float64) 1048576 | int64 -}}
{{- else if hasSuffix "Ki" $q -}}{{- mulf (trimSuffix "Ki" $q | float64) 1024 | int64 -}}
{{- else if hasSuffix "G" $q -}}{{- mulf (trimSuffix "G" $q | float64) 1000000000 | int64 -}}
{{- else if hasSuffix "M" $q -}}{{- mulf (trimSuffix "M" $q | float64) 1000000 | int64 -}}
{{- else -}}{{- $q | float64 | int64 -}}
{{- end -}}
{{- end -}}
