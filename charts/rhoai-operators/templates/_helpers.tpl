{{/* Resolve a sync-wave name (prereqs, gpu, rhoai) to its number. */}}
{{- define "rhoai-operators.wave" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- index $root.Values.syncWaves $name -}}
{{- end -}}
