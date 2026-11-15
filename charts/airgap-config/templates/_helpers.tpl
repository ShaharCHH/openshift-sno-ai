{{/* Sync-wave annotation: include "airgap-config.wave" (list $ "mirrors") */}}
{{- define "airgap-config.wave" -}}
argocd.argoproj.io/sync-wave: {{ index (index . 0).Values.syncWaves (index . 1) | quote }}
{{- end -}}
