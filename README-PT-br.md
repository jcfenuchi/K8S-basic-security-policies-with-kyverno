# kyverno-guardrails-policies

English version: [README.md](README.md)

Chart Helm com o conjunto mínimo de [Kyverno](https://kyverno.io) `ClusterPolicy` que qualquer cluster Kubernetes de produção deveria ter antes do primeiro deploy de verdade: containers isolados do host, imagens vindas de origem confiável, limites de recursos e rede fechada por padrão.

O nome "guardrails" é proposital — isso não é uma postura de segurança completa (não substitui RBAC bem desenhado, scanner de imagem, admission de supply chain, etc.), é a cerca baixa que evita os erros mais comuns e mais caros: container privilegiado, `hostPath` solto, imagem `:latest` em produção, Pod sem limite de memória.

## Por que Kyverno

O Kubernetes já traz o Pod Security Admission (PSA), que aplica os Pod Security Standards por namespace. Ele resolve a parte de `identity` e `isolation` deste chart, mas para aí. O PSA não restringe registries, não exige labels, requests, limits ou probes e não bloqueia o namespace `default`. Ele também não cria recursos, e a NetworkPolicy default-deny depende disso. No modo de auditoria, o PSA só anota o log de auditoria do API server, sem um relatório por recurso que dê para consultar com `kubectl`.

O Kyverno cobre esses pontos com uma ferramenta só. As políticas são YAML comum, no mesmo formato dos manifests que elas validam, sem uma linguagem própria como o Rego do OPA Gatekeeper. O modo `Audit` grava cada violação em `PolicyReport`, e isso permite ligar as políticas num cluster que já está rodando e medir o impacto antes de bloquear qualquer coisa.

## O que tem aqui

20 políticas, divididas por categoria:

- **identity** — o que o container pode fazer no kernel do host: privileged, root, escalada de privilégio, capabilities, seccomp.
- **access** — o que o Pod herda por padrão da API do cluster (token de ServiceAccount).
- **isolation** — fronteira entre container e nó: namespaces do host, `hostPath`, `hostPort`, tipos de volume.
- **network** — gera uma `NetworkPolicy` default-deny em cada namespace.
- **images** — proíbe `:latest` e restringe a registries aprovados.
- **resources** — requests, limits, filesystem somente-leitura e probes.
- **organization** — labels obrigatórias e bloqueio do namespace `default`.

A lista completa, com severidade, está na tabela no fim deste README.

## Instalando

```bash
helm install kyverno-guardrails-policies . --create-namespace --namespace kyverno-guardrails-policies
```

O Kyverno precisa já estar instalado no cluster (este chart só cria `ClusterPolicy`, não o próprio Kyverno). As políticas foram validadas com o Kyverno CLI 1.19.1; a política `default-deny-networkpolicy` usa `generate.generateExisting`, que exige Kyverno 1.13 ou mais novo. O namespace `kyverno-guardrails-policies` é só o endereço do release — as políticas são recursos de cluster inteiro e valem para qualquer namespace, independente de onde o Helm guardou o release.

## Ligando e desligando políticas

Cada política tem uma chave em `values.yaml` com o mesmo nome do arquivo/da política. Para desligar uma:

```yaml
policies:
  require-read-only-root-filesystem:
    enabled: false
```

Ou direto na linha de comando:

```bash
helm upgrade kyverno-guardrails-policies . --set policies.require-probes.enabled=false
```

Duas políticas têm parâmetros próprios, além do `enabled`:

```yaml
policies:
  restrict-image-registries:
    enabled: true
    allowedRegistries:
      - "registry.empresa.com/*"
      - "ghcr.io/*"

  require-labels:
    enabled: true
    requiredLabels:
      - app
      - environment
      - owner
```

Ajuste essas duas listas para o que faz sentido no seu ambiente — os valores default são só um ponto de partida.

A `restrict-image-registries` confere `containers`, `initContainers` e `ephemeralContainers`, e compara o texto do campo `image` do jeito que ele foi escrito, sem normalizar. Uma imagem declarada como `nginx:1.27` não casa com `docker.io/library/*`, então ela vai aparecer como violação. Escreva o nome completo (`docker.io/library/nginx:1.27`) ou acrescente o padrão curto na lista, por exemplo `"nginx:*"`.


## Escolhendo os namespaces

Por padrão, todas as políticas valem em todos os namespaces. O bloco `scope` do `values.yaml` muda isso para o chart inteiro, de duas formas que podem ser usadas juntas.

`excludeNamespaces` tira namespaces da validação. Serve para namespaces cujos workloads ainda não foram adequados, como um sistema legado em migração ou agentes de monitoramento que precisam de acesso ao host:

```yaml
scope:
  excludeNamespaces: [legado, monitoring]
```

`namespaceSelector` limita as políticas aos namespaces com determinados labels. Se os namespaces de projeto já são criados com um label padronizado, as políticas passam a valer sozinhas em cada projeto novo, e o resto do cluster fica de fora:

```yaml
scope:
  namespaceSelector:
    matchLabels:
      environment: production
```

O Kyverno confere os labels do namespace onde o recurso está, não os do recurso. Com a configuração acima, num cluster com estes namespaces:

| Pod criado em | Labels do namespace | A política vale? |
|---|---|---|
| `projeto-a` | `environment: production` | Sim |
| `projeto-b` | `environment: staging` | Não |
| `monitoring` | nenhum | Não |
| `kube-system` | nenhum | Não |

Um namespace novo criado já com `environment: production` entra nas políticas sem nenhuma mudança neste chart. Para incluir ou tirar um namespace à mão, basta mudar o label, e o efeito é imediato:

```bash
kubectl get namespaces --show-labels                   # ver os labels atuais
kubectl label namespace legado environment=production  # passa a valer em "legado"
kubectl label namespace legado environment-            # deixa de valer (o "-" remove o label)
```

`matchLabels` exige o valor exato. Para aceitar mais de um valor, ou só exigir que o label exista, use `matchExpressions` (operadores `In`, `NotIn`, `Exists` e `DoesNotExist`):

```yaml
scope:
  namespaceSelector:
    matchExpressions:
      - key: environment          # production OU staging
        operator: In
        values: [production, staging]
      - key: department           # e com o label department, qualquer valor
        operator: Exists
```

Dois cuidados com o `namespaceSelector`. Um namespace sem o label fica fora de todas as políticas sem aviso nenhum, e nada aparece no `PolicyReport`; por isso padronize a criação de namespaces para que eles já nasçam com o label. E quem pode editar os labels de um namespace pode tirá-lo das políticas. Como o Namespace é um recurso de cluster, uma Role dentro do namespace não dá essa permissão; deixe-a só com os administradores do cluster.

Cada política aceita os mesmos dois campos em `policies.<nome>`, e o valor da política substitui o global. Um `[]` ou `{}` na política desliga o escopo global só para ela. No exemplo abaixo, o namespace `legado` fica fora de todas as políticas, menos da `disallow-privileged-containers`:

```yaml
scope:
  excludeNamespaces: [legado]

policies:
  disallow-privileged-containers:
    enabled: true
    excludeNamespaces: []
```

Na `default-deny-networkpolicy`, os namespaces `kube-system`, `kube-public`, `kube-node-lease`, `kyverno` e o do próprio release ficam sempre de fora, somados aos de `excludeNamespaces`.

O chart não exclui `kube-system` nas outras políticas. Quem faz isso é o filtro `resourceFilters` que a instalação padrão do Kyverno traz, e que já ignora os namespaces de sistema. Se esse filtro tiver sido alterado no seu cluster, inclua `kube-system` em `excludeNamespaces` antes de ligar o Enforce.

## Audit primeiro, Enforce depois

O padrão do chart é `validationFailureAction: Audit` para tudo: nada é bloqueado, mas toda violação aparece em `PolicyReport`. Isso é proposital — instalar isso num cluster com workloads já rodando e diretamente em modo `Enforce` pode bloquear a criação e atualização desses workloads sem aviso prévio.

Fluxo recomendado:

```bash
# 1. instale em Audit (padrão) e espere alguns dias
kubectl get policyreport -A
kubectl get clusterpolicyreport

# 2. corrija os workloads que estão violando (ou ajuste a política, se a
#    violação for legítima pro seu caso)

# 3. mude para Enforce, globalmente...
helm upgrade kyverno-guardrails-policies . --set validationFailureAction=Enforce

# ...ou política por política
helm upgrade kyverno-guardrails-policies . --set policies.disallow-privileged-containers.validationFailureAction=Enforce
```

Duas políticas merecem atenção redobrada antes de ligar:

- **`default-deny-networkpolicy`** vem **desligada por padrão**. Diferente das outras, ela não é uma validação — é uma regra `generate` que cria uma `NetworkPolicy` de verdade em todo namespace assim que é ativada, inclusive nos que já existem (`generateExisting: true`), e isso acontece independente de Audit/Enforce (gerar recurso não tem "modo auditoria"). Se o namespace ainda não tiver `NetworkPolicy` liberando o tráfego necessário, workloads existentes podem parar de se comunicar na hora. Mapeie o tráfego real do cluster antes de ligar. O background controller do Kyverno precisa de permissão para criar `NetworkPolicy`; se o Kyverno recusar a política por falta de permissão, acrescente `networkpolicies` em `backgroundController.rbac.clusterRole.extraResources` no values do Kyverno.
- **`disallow-automount-service-account-token`** exige que `automountServiceAccountToken` seja declarado explicitamente (`true` ou `false`) em vez de herdar o default implícito do cluster. A maioria dos controllers e operators de terceiros (cert-manager, ingress-nginx, etc.) hoje não declara esse campo, então eles vão aparecer como violação até você ajustar o manifesto/values deles para `true` (workloads que realmente falam com a API) ou `false` (a maioria). Rode em Audit por mais tempo que as outras enquanto faz esse levantamento.

## Conferindo o que está rodando

```bash
kubectl get clusterpolicies
kubectl get policyreport -A
kubectl get clusterpolicyreport
kubectl describe policyreport -n <namespace>
```

## Referência completa

| Política | Categoria | Severidade | Ligada por padrão |
|---|---|:---:|:---:|
| disallow-privileged-containers | identity | crítica | sim |
| disallow-host-namespaces | isolation | crítica | sim |
| disallow-root-user | identity | alta | sim |
| require-run-as-non-root | identity | alta | sim |
| disallow-privilege-escalation | identity | alta | sim |
| disallow-capabilities | identity | alta | sim |
| disallow-host-path | isolation | alta | sim |
| restrict-volume-types | isolation | alta | sim |
| restrict-image-registries | images | alta | sim |
| default-deny-networkpolicy | network | alta | **não** |
| require-seccomp-profile | identity | média | sim |
| disallow-automount-service-account-token | access | média | sim |
| disallow-host-ports | isolation | média | sim |
| disallow-latest-tag | images | média | sim |
| require-resource-requests | resources | média | sim |
| require-resource-limits | resources | média | sim |
| require-read-only-root-filesystem | resources | média | sim |
| require-probes | resources | média | sim |
| disallow-default-namespace | organization | média | sim |
| require-labels | organization | baixa | sim |

## Desenvolvendo

```bash
helm lint .
helm template . --set policies.default-deny-networkpolicy.enabled=true   # revisar antes de mexer nela
```

Para testar as políticas contra manifests de exemplo sem precisar de cluster, use o [Kyverno CLI](https://kyverno.io/docs/kyverno-cli/). Renderize com `namespace.create=false`: com o `Namespace` no mesmo arquivo, o CLI 1.19 não carrega nenhuma regra e informa "Applying 0 policy rule(s)".

```bash
helm template . --set namespace.create=false > /tmp/policies.yaml
kyverno apply /tmp/policies.yaml --resource meu-deployment.yaml
```

## Compatibilidade com versões futuras do Kyverno

A partir do Kyverno 1.19, o tipo `kyverno.io/v1 ClusterPolicy` usado por este chart está marcado como obsoleto e vai ser removido numa versão futura. O substituto são os tipos baseados em CEL (`ValidatingPolicy` e `GeneratingPolicy`, grupo `policies.kyverno.io`). As políticas continuam funcionando hoje, mas a migração precisa ser planejada antes de atualizar o Kyverno para a versão que remover o tipo antigo. O guia oficial está em <https://kyverno.io/docs/guides/migration-to-cel/>.

## Mais políticas

O catálogo oficial do Kyverno tem políticas prontas para situações mais específicas — multi-tenancy, supply chain, conformidade com CIS Benchmark, PSA migration, entre outras.

Vale dar uma olhada antes de criar algo do zero:

➡️ [Kyverno Policy Library — High Severity ClusterPolicies](https://kyverno.io/policies/?severity=high&type=ClusterPolicy%2CValidatingPolicy)
