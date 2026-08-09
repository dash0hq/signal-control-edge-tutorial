# SignalControl on the edge, with kustomize

Install path for clusters without Helm. Everything is driven by two `.env`
files; no YAML in this tree is edited, and nothing needs `sed`.

**The install procedure is in [../docs/install-kubectl.md](../docs/install-kubectl.md).**
This file is the reference for the layout and for how the configuration reaches
the containers.

Both install paths produce the same two workloads and read the same collector
configuration. Prefer [the Helm chart](../chart/) if you have Helm.

## Layout

```
kustomization.yaml        the default install: kubectl apply -k .
base/
  kustomization.yaml      namespace, resources, ConfigMap and Secret generators
  dash0.env.example       region, domain, dataset, optional endpoint overrides
  token.env.example       token=auth_...
  collector-config.yaml   second copy of the collector config, see below
  namespace.yaml          carries the restricted Pod Security Standard labels
  edge-proxy.yaml         Deployment, Service, PDB, HPA
  edge-collector.yaml     Deployment, Service, PDB
endpoints/                overlay: explicit endpoints instead of region + domain
loadgen/                  overlay: one synthetic traffic generator
networkpolicy/            overlay: default-deny plus per workload policies
```

| Target          | Command                          | What you get                                                      |
|-----------------|----------------------------------|-------------------------------------------------------------------|
| default         | `kubectl apply -k .`             | namespace, Edge Proxy, edge collector                             |
| `endpoints`     | `kubectl apply -k endpoints`     | the same, with all three endpoints read straight from `dash0.env` |
| `loadgen`       | `kubectl apply -k loadgen`       | the same, plus one `gen-checkout` generator                       |
| `networkpolicy` | `kubectl apply -k networkpolicy` | the same, plus a default-deny and two per workload policies       |

The overlays live beside `base/` rather than inside it because kustomize treats
an overlay nested within its own base as a cycle
(`cycle detected: candidate root ... contains visited root ...`). That is also
why `kubectl apply -k .` goes through a one line passthrough kustomization.

The overlays do not compose with each other. For explicit endpoints plus
generated traffic, apply `-k endpoints` and then
`kubectl -n dash0-signal-control apply -f loadgen/telemetrygen.yaml`.

## The two files you edit

Copy the examples and fill them in. Both are gitignored, from the root
`.gitignore` and from `base/.gitignore`.

`base/dash0.env` is the only file with decisions in it:

| Key                             | Example         | Notes                                                         |
|---------------------------------|-----------------|---------------------------------------------------------------|
| `DASH0_REGION`                  | `eu-west-1`     | as it appears in your Dash0 URL                               |
| `DASH0_DOMAIN`                  | `aws.dash0.com` | change only if Dash0 gave you a different domain              |
| `DASH0_DATASET`                 | `production`    | **required, ships empty**; must exist and must hold the rules |
| `DASH0_ENDPOINT_API`            | commented out   | only with the `endpoints` overlay                             |
| `DASH0_ENDPOINT_OTLP`           | commented out   | only with the `endpoints` overlay                             |
| `DASH0_ENDPOINT_DECISION_MAKER` | commented out   | only with the `endpoints` overlay                             |

`DASH0_DATASET` has no default on purpose. A plausible placeholder would give
you a fully Ready install whose sampling rules never match anything, so the
example file leaves it empty and the collector refuses to start until you set
it. A `CrashLoopBackOff` on `dash0-edge-collector` right after the first apply
is almost always this.

`base/token.env` holds one line, `token=auth_...`. It becomes a Secret and is
never written into a manifest.

The three endpoints are derived from region and domain:

```
Dash0 API        https://api.<region>.<domain>
OTLP ingress     ingress.<region>.<domain>:4317
Decision-Maker   decision-maker.<region>.<domain>:443
```

The `endpoints` overlay is only for Dash0 hosts that do not follow that pattern.
Uncomment and set **all three** `DASH0_ENDPOINT_*` keys in `base/dash0.env`
first. All three or none: the overlay reads each one non-optionally, so a key
left commented out stops the pods with `CreateContainerConfigError` instead of
starting them against a half wrong endpoint.

## How the configuration reaches the containers

`kubectl apply -k` generates a ConfigMap from `dash0.env` and a Secret from
`token.env`. The Deployments pull the primitives in with `configMapKeyRef` and
`secretKeyRef`, then compose the endpoints with `$(VAR)`:

```yaml
- name: DASH0_REGION
  valueFrom: { configMapKeyRef: { name: dash0-edge-settings, key: DASH0_REGION } }
- name: DASH0_DOMAIN
  valueFrom: { configMapKeyRef: { name: dash0-edge-settings, key: DASH0_DOMAIN } }
- name: UPSTREAM_ADDRESS
  value: "decision-maker.$(DASH0_REGION).$(DASH0_DOMAIN):443"
```

The kubelet substitutes `$(VAR)` in an `env[].value` using entries declared
**earlier in the same container's `env` list**. Four consequences:

- **Order matters.** A forward reference is left as the literal text
  `$(NAME)`, not an error. Keep the primitives at the top of each `env` list.
- **A missing name is not an error either.** `$(NEVER_DECLARED)` survives
  verbatim into the container. That is why the `endpoints` overlay uses
  non-optional `configMapKeyRef`s: a missing key must stop the pod, not produce
  a hostname called `$(DASH0_ENDPOINT_OTLP)`.
- **Values that arrive from a ConfigMap or Secret are never expanded**, and
  expansion is single pass. `$(VAR)` written inside a ConfigMap value stays
  literal, so derivation has to live in the manifest, not in `dash0.env`. That
  is why overriding an endpoint needs the `endpoints` overlay rather than just
  another key.
- **`envFrom` variables are usable in `$(VAR)`**, contrary to the common claim.
  These manifests still use explicit `configMapKeyRef` entries: they name the
  keys they depend on, so a typo fails loudly at pod start instead of leaving a
  literal in place.

The token is composed into `UPSTREAM_HEADERS` the same way, so the rendered
Deployment contains only a reference and the Secret stays the single object
holding the credential.

### The namespace comes from the downward API, not from the YAML

`namespace:` in `base/kustomization.yaml` rewrites `metadata.namespace`. It does
**not** reach inside an `env[].value`, and it does not reach inside ConfigMap
data. A service address written out in full would therefore survive an install
into any other namespace, the pods would go Ready, and the collector would talk
to nothing while keeping 100% of spans, which looks much like a working install.

So both Deployments declare `POD_NAMESPACE` from `fieldRef: metadata.namespace`
as their first `env` entry and compose from it:

```yaml
- name: POD_NAMESPACE
  valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
- name: EDGE_PROXY_ENDPOINT
  value: "dash0-edge-proxy.$(POD_NAMESPACE).svc.cluster.local:8011"
```

`collector-config.yaml` reads the same variable as `${env:POD_NAMESPACE}` for
its self-telemetry `service.namespace`.

To install into a different namespace, change the `namespace:` line in
`base/kustomization.yaml` **and the matching line in every overlay you use**:
`loadgen/kustomization.yaml` and `networkpolicy/kustomization.yaml` each declare
their own, because a `namespace:` set in `base/` applies only to resources
accumulated inside `base/`.

**An overlay whose `namespace:` still says `dash0-signal-control` re-deploys the
whole installation there, leaving you with two collectors exporting the same
telemetry to the same dataset.**

Read the namespace back from a running pod:

```sh
NS=dash0-signal-control        # your namespace
kubectl -n "$NS" get pod -l app.kubernetes.io/name=dash0-edge-collector \
  -o jsonpath='{.items[0].spec.containers[0].env}'
```

`base/namespace.yaml` also carries the `restricted` Pod Security Standard
labels, so this path enforces PSS out of the box. The Helm chart cannot ship a
`Namespace` object and asks you to apply those labels by hand.

### Generated names carry a content hash

Editing `dash0.env`, `token.env` or `collector-config.yaml` changes the
generated object name, which changes the pod template, which rolls the pods on
the next apply. That replaces the config checksum annotation you would otherwise
maintain by hand.

Superseded ConfigMaps and Secrets are left behind. Remove them with
`kubectl delete -k .`, or by deleting the namespace. Do **not** use
`kubectl apply --prune`: the shared `part-of` label is on the `Namespace` object
too, which puts namespaces in prune scope.

## Keeping the two collector configs in step

The collector configuration exists twice in this repository, once per install
path:

| Copy                                 | Read by                                        |
|--------------------------------------|------------------------------------------------|
| `kubectl/base/collector-config.yaml` | this base, through `configMapGenerator`        |
| `chart/files/collector-config.yaml`  | the Helm chart, through `.Files.Get` and `tpl` |

The copy lives here rather than as a reference because kustomize refuses to read
a file outside its own directory: it rejects a relative path and a symlink
alike.

**They must stay in step, and they differ by exactly one line:**
`max_recv_msg_size_mib`, hardcoded to `16` here and templated from
`.Values.collector.otlpMaxRecvMsgSizeMib` in the chart copy. Nothing else may
differ. Check it from the repository root, in a shell with process substitution,
and expect no output:

```sh
cmp <(sed 's/max_recv_msg_size_mib:.*/max_recv_msg_size_mib: X/' chart/files/collector-config.yaml) \
    <(sed 's/max_recv_msg_size_mib:.*/max_recv_msg_size_mib: X/' kubectl/base/collector-config.yaml)
```

The self-telemetry `service.namespace` is deliberately not templated in either
copy: it reads `${env:POD_NAMESPACE}` from the downward API, which is the one
mechanism both install paths share.

After editing either copy, validate it against the image, and treat **any**
output as failure rather than only a non-zero exit:

```sh
cat > /tmp/collector.env <<'EOF'
DASH0_DATASET=example
DASH0_AUTH_TOKEN=auth_x
DASH0_OTLP_ENDPOINT=ingress.eu-west-1.aws.dash0.com:4317
EDGE_PROXY_ENDPOINT=dash0-edge-proxy.dash0-signal-control.svc.cluster.local:8011
SELF_SERVICE_INSTANCE_ID=validate
POD_NAMESPACE=dash0-signal-control
RESERVOIR_MAX_MEMORY_BYTES=2147483648
RESERVOIR_BUFFER_DURATION=30s
SAMPLING_FALLBACK_SAMPLE_RATIO=1.0
LOG_LEVEL=info
EOF

docker run --rm --env-file /tmp/collector.env -v "$PWD/kubectl/base:/cfg:ro" \
  --entrypoint /otelcol ghcr.io/dash0hq/signal-control-collector:v2.0.2756 \
  validate --config /cfg/collector-config.yaml
```
