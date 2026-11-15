{{/*
Image fields for one ClusterPolicy component. Args: (list componentValues gpuValues)
Emits only what is set, so an empty value means "operator default" (no hardcoded registry in the chart).
Air-gap: set gpu.repository (and per-component repository/image/version) to the mirror.
*/}}
{{- define "rhoai-config.gpuImage" -}}
{{- $c := index . 0 -}}{{- $g := index . 1 -}}
{{- with ($c.repository | default $g.repository) }}
repository: {{ . | quote }}
{{- end }}
{{- with $c.image }}
image: {{ . | quote }}
{{- end }}
{{- with $c.version }}
version: {{ . | quote }}
{{- end }}
{{- with $g.imagePullSecrets }}
imagePullSecrets:
{{ toYaml . | indent 2 }}
{{- end }}
{{- end -}}
