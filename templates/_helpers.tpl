{{/*
Bloco "match" + "exclude" de uma regra, aplicando o escopo de namespaces.

Parâmetros (dict):
  p            - values da política (.Values.policies.<nome>)
  root         - contexto raiz ($)
  kinds        - lista de kinds da regra
  namespaces   - (opcional) lista fixa de namespaces do match
  extraExclude - (opcional) namespaces sempre excluídos por esta regra

"excludeNamespaces" e "namespaceSelector" definidos na política substituem os
de .Values.scope (inclusive quando definidos vazios).

Quando o kind é Namespace, o label é conferido no próprio Namespace com
"selector": "namespaceSelector" nunca casa com um recurso Namespace.
*/}}
{{- define "kyverno-guardrails-policies.matchExclude" -}}
{{- $scope := .root.Values.scope | default dict -}}
{{- $excl := $scope.excludeNamespaces | default list -}}
{{- if hasKey .p "excludeNamespaces" }}{{ $excl = .p.excludeNamespaces | default list }}{{ end -}}
{{- $excl = concat (.extraExclude | default list) $excl | uniq -}}
{{- $sel := $scope.namespaceSelector | default dict -}}
{{- if hasKey .p "namespaceSelector" }}{{ $sel = .p.namespaceSelector | default dict }}{{ end -}}
match:
  any:
    - resources:
        kinds: {{ toJson .kinds }}
        {{- with .namespaces }}
        namespaces: {{ toJson . }}
        {{- end }}
        {{- with $sel }}
        {{ if has "Namespace" $.kinds }}selector{{ else }}namespaceSelector{{ end }}:
          {{- toYaml . | nindent 10 }}
        {{- end }}
{{- with $excl }}
exclude:
  any:
    - resources:
        namespaces: {{ toJson . }}
{{- end }}
{{- end }}
