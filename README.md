# kyverno-guardrails-policies

Versão em pt-BR: [README-PT-br.md](README-PT-br.md)

Helm chart with the minimum set of [Kyverno](https://kyverno.io) `ClusterPolicy` resources that any production Kubernetes cluster should have before its first real deploy: containers isolated from the host, images from trusted sources, resource limits and a network closed by default.

The name "guardrails" is deliberate. This is not a complete security posture: it doesn't replace well-designed RBAC, image scanning or supply-chain admission controls. It is the low fence that prevents the most common and most expensive mistakes: a privileged container, a loose `hostPath`, a `:latest` image in production, a Pod with no memory limit.

## Why Kyverno

Kubernetes already ships Pod Security Admission (PSA), which applies the Pod Security Standards per namespace. It covers the `identity` and `isolation` parts of this chart, but stops there. PSA doesn't restrict registries, doesn't require labels, requests, limits or probes, and doesn't block the `default` namespace. It also can't create resources, which the default-deny NetworkPolicy depends on. In audit mode, PSA only annotates the API server audit log, with no per-resource report you can query with `kubectl`.

Kyverno covers all of this with a single tool. Policies are plain YAML, in the same format as the manifests they validate, with no separate language like OPA Gatekeeper's Rego. `Audit` mode records every violation in a `PolicyReport`, which lets you turn the policies on in a cluster that is already running and measure the impact before blocking anything.

## What's here

20 policies, grouped by category:

- `identity`: what the container can do in the host kernel (privileged, root, privilege escalation, capabilities, seccomp).
- `access`: what the Pod inherits from the cluster API by default (the ServiceAccount token).
- `isolation`: the boundary between container and node (host namespaces, `hostPath`, `hostPort`, volume types).
- `network`: generates a default-deny `NetworkPolicy` in each namespace.
- `images`: forbids `:latest` and restricts images to approved registries.
- `resources`: requests, limits, read-only root filesystem and probes.
- `organization`: required labels and a block on the `default` namespace.

The full list, with severity, is in the table at the end of this README.

## Installing

```bash
helm install kyverno-guardrails-policies . --create-namespace --namespace kyverno-guardrails-policies
```

Kyverno must already be installed in the cluster; this chart only creates `ClusterPolicy` resources, not Kyverno itself. The policies were validated with Kyverno CLI 1.19.1, and the `default-deny-networkpolicy` policy uses `generate.generateExisting`, which requires Kyverno 1.13 or newer. The `kyverno-guardrails-policies` namespace is only where the release is recorded. The policies are cluster-wide resources and apply to every namespace, no matter where Helm stored the release.

## Turning policies on and off

Each policy has a key in `values.yaml` with the same name as the file and the policy. To turn one off:

```yaml
policies:
  require-read-only-root-filesystem:
    enabled: false
```

Or straight from the command line:

```bash
helm upgrade kyverno-guardrails-policies . --set policies.require-probes.enabled=false
```

Two policies have their own parameters besides `enabled`:

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

Adjust both lists to what makes sense in your environment. The default values are only a starting point.

`restrict-image-registries` checks `containers`, `initContainers` and `ephemeralContainers`, and compares the `image` field exactly as written, without normalizing it. An image declared as `nginx:1.27` doesn't match `docker.io/library/*`, so it shows up as a violation. Write the full name (`docker.io/library/nginx:1.27`) or add the short pattern to the list, for example `"nginx:*"`.

## Choosing the namespaces

By default, every policy applies to every namespace. The `scope` block in `values.yaml` changes that for the whole chart, in two ways that can be combined.

`excludeNamespaces` takes namespaces out of validation. Use it for namespaces whose workloads haven't been brought into line yet, such as a legacy system being migrated or monitoring agents that need host access:

```yaml
scope:
  excludeNamespaces: [legacy, monitoring]
```

`namespaceSelector` limits the policies to namespaces with certain labels. If project namespaces are already created with a standard label, the policies start applying to each new project on their own, and the rest of the cluster stays out:

```yaml
scope:
  namespaceSelector:
    matchLabels:
      environment: production
```

Kyverno checks the labels of the namespace the resource lives in, not the resource's own labels. With the configuration above, in a cluster with these namespaces:

| Pod created in | Namespace labels | Does the policy apply? |
|---|---|---|
| `project-a` | `environment: production` | Yes |
| `project-b` | `environment: staging` | No |
| `monitoring` | none | No |
| `kube-system` | none | No |

A new namespace created with `environment: production` is covered by the policies without any change to this chart. To add or remove a namespace by hand, change the label, and the effect is immediate:

```bash
kubectl get namespaces --show-labels                   # see the current labels
kubectl label namespace legacy environment=production  # policies now apply to "legacy"
kubectl label namespace legacy environment-            # policies stop applying (the "-" removes the label)
```

`matchLabels` requires an exact value. To accept more than one value, or only require that a label exists, use `matchExpressions` (operators `In`, `NotIn`, `Exists` and `DoesNotExist`):

```yaml
scope:
  namespaceSelector:
    matchExpressions:
      - key: environment          # production OR staging
        operator: In
        values: [production, staging]
      - key: department           # and with a department label, any value
        operator: Exists
```

Two things to watch with `namespaceSelector`. A namespace without the label falls outside every policy with no warning at all, and nothing shows up in the `PolicyReport`; so standardize namespace creation so that namespaces are born with the label. And anyone who can edit a namespace's labels can take it out of the policies. Since a Namespace is a cluster-scoped resource, a Role inside the namespace doesn't grant that permission; keep it with cluster administrators only.

Each policy accepts the same two fields under `policies.<name>`, and the policy's value replaces the global one. A `[]` or `{}` on a policy turns off the global scope for that policy only. In the example below, the `legacy` namespace is excluded from every policy except `disallow-privileged-containers`:

```yaml
scope:
  excludeNamespaces: [legacy]

policies:
  disallow-privileged-containers:
    enabled: true
    excludeNamespaces: []
```

For `default-deny-networkpolicy`, the `kube-system`, `kube-public`, `kube-node-lease` and `kyverno` namespaces, plus the release's own namespace, are always excluded, in addition to those in `excludeNamespaces`.

The chart doesn't exclude `kube-system` in the other policies. That is done by the `resourceFilters` setting that comes with a default Kyverno install, which already ignores system namespaces. If that filter was changed in your cluster, add `kube-system` to `excludeNamespaces` before turning on Enforce.

## Audit first, Enforce later

The chart defaults to `validationFailureAction: Audit` for everything: nothing is blocked, but every violation shows up in a `PolicyReport`. This is on purpose. Installing straight into `Enforce` mode on a cluster with running workloads can block those workloads from being created or updated, with no prior warning.

Recommended flow:

```bash
# 1. install in Audit (the default) and wait a few days
kubectl get policyreport -A
kubectl get clusterpolicyreport

# 2. fix the violating workloads (or adjust the policy, if the
#    violation is legitimate for your case)

# 3. switch to Enforce, globally...
helm upgrade kyverno-guardrails-policies . --set validationFailureAction=Enforce

# ...or policy by policy
helm upgrade kyverno-guardrails-policies . --set policies.disallow-privileged-containers.validationFailureAction=Enforce
```

Two policies deserve extra care before you turn them on:

- `default-deny-networkpolicy` is off by default. Unlike the others, it isn't a validation but a `generate` rule: as soon as it is enabled, it creates a real `NetworkPolicy` in every namespace, including the ones that already exist (`generateExisting: true`), regardless of Audit or Enforce (generating a resource has no audit mode). If a namespace doesn't yet have a `NetworkPolicy` allowing the traffic it needs, existing workloads can stop talking to each other immediately. Map the cluster's real traffic before enabling it. Kyverno's background controller needs permission to create `NetworkPolicy` resources; if Kyverno rejects the policy for lack of permission, add `networkpolicies` to `backgroundController.rbac.clusterRole.extraResources` in Kyverno's values.
- `disallow-automount-service-account-token` requires `automountServiceAccountToken` to be declared explicitly (`true` or `false`) instead of inheriting the cluster's implicit default. Most third-party controllers and operators (cert-manager, ingress-nginx and others) don't declare this field today, so they will show up as violations until you set it in their manifests or values: `true` for workloads that really talk to the API, `false` for most of them. Keep this one in Audit longer than the others while you do that survey.

## Checking what's running

```bash
kubectl get clusterpolicies
kubectl get policyreport -A
kubectl get clusterpolicyreport
kubectl describe policyreport -n <namespace>
```

## Full reference

| Policy | Category | Severity | On by default |
|---|---|:---:|:---:|
| disallow-privileged-containers | identity | critical | yes |
| disallow-host-namespaces | isolation | critical | yes |
| disallow-root-user | identity | high | yes |
| require-run-as-non-root | identity | high | yes |
| disallow-privilege-escalation | identity | high | yes |
| disallow-capabilities | identity | high | yes |
| disallow-host-path | isolation | high | yes |
| restrict-volume-types | isolation | high | yes |
| restrict-image-registries | images | high | yes |
| default-deny-networkpolicy | network | high | no |
| require-seccomp-profile | identity | medium | yes |
| disallow-automount-service-account-token | access | medium | yes |
| disallow-host-ports | isolation | medium | yes |
| disallow-latest-tag | images | medium | yes |
| require-resource-requests | resources | medium | yes |
| require-resource-limits | resources | medium | yes |
| require-read-only-root-filesystem | resources | medium | yes |
| require-probes | resources | medium | yes |
| disallow-default-namespace | organization | medium | yes |
| require-labels | organization | low | yes |

## Development

```bash
helm lint .
helm template . --set policies.default-deny-networkpolicy.enabled=true   # review before touching it
```

To test the policies against sample manifests without a cluster, use the [Kyverno CLI](https://kyverno.io/docs/kyverno-cli/). Render with `namespace.create=false`: with the `Namespace` in the same file, CLI 1.19 loads no rules and reports "Applying 0 policy rule(s)".

```bash
helm template . --set namespace.create=false > /tmp/policies.yaml
kyverno apply /tmp/policies.yaml --resource my-deployment.yaml
```

## Compatibility with future Kyverno versions

As of Kyverno 1.19, the `kyverno.io/v1 ClusterPolicy` type used by this chart is marked as deprecated and will be removed in a future release. Its replacements are the CEL-based types (`ValidatingPolicy` and `GeneratingPolicy`, in the `policies.kyverno.io` group). The policies still work today, but the migration has to be planned before upgrading Kyverno to the release that removes the old type. The official guide is at <https://kyverno.io/docs/guides/migration-to-cel/>.

## More policies

Kyverno's official catalog has ready-made policies for more specific situations: multi-tenancy, supply chain, CIS Benchmark compliance, PSA migration and others. It's worth a look before writing something from scratch:

[Kyverno Policy Library: High Severity ClusterPolicies](https://kyverno.io/policies/?severity=high&type=ClusterPolicy%2CValidatingPolicy)
