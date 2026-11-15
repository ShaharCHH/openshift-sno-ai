{{/* Sync-wave annotation: include "rhoai-config.wave" (list $ "dsc") */}}
{{- define "rhoai-config.wave" -}}
argocd.argoproj.io/sync-wave: {{ index (index . 0).Values.syncWaves (index . 1) | quote }}
{{- end -}}

{{/*
Resolve a generated-or-supplied credential. Args: (list ctx secretName key supplied length namespace)
Order: supplied value, then the live Secret (lookup, so upgrades keep it), then random.
*/}}
{{- define "rhoai-config.cred" -}}
{{- $name := index . 1 -}}{{- $key := index . 2 -}}{{- $given := index . 3 -}}{{- $len := index . 4 -}}{{- $ns := index . 5 -}}
{{- if $given -}}{{ $given }}
{{- else -}}
{{- $live := lookup "v1" "Secret" $ns $name -}}
{{- if and $live $live.data (hasKey $live.data $key) -}}{{ index $live.data $key | b64dec }}
{{- else -}}{{ randAlphaNum (int $len) }}
{{- end -}}
{{- end -}}
{{- end -}}
