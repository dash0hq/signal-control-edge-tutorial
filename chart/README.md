# dash0-signal-control-edge

Helm chart for Dash0 SignalControl on the edge: an Edge Proxy plus a gateway
OpenTelemetry Collector that enriches, spam filters, derives RED and
signal-to-metrics, tail samples, and exports to Dash0.

**The install procedure is in [../docs/install-helm.md](../docs/install-helm.md).**
This file is the reference for what the chart contains and what its values do.

```
your central collector --OTLP--> dash0-edge-collector (Deployment)
                                        |  gRPC :8011
                                        v
                                  dash0-edge-proxy    (Deployment)
                                        |  TLS :443
                                        v
        decision-maker.<region>.<domain>   sampling decisions
        api.<region>.<domain>              organisation settings

dash0-edge-collector --OTLP/TLS--> ingress.<region>.<domain>:4317
```

The Edge Proxy exists so a fleet of collectors needs one connection out of your
network instead of one per pod, for both the decision stream and the settings
feed.

## What it deploys

| Object                  | Name                          | Notes                                |
|-------------------------|-------------------------------|--------------------------------------|
| Secret                  | `dash0-edge-credentials`      | only when `dash0.token.value` is set |
| Deployment              | `dash0-edge-proxy`            | fixed replicas, HPA on top           |
| Service                 | `dash0-edge-proxy`            | plain ClusterIP, gRPC 8011           |
| PodDisruptionBudget     | `dash0-edge-proxy`            | `maxUnavailable: 1`                  |
| HorizontalPodAutoscaler | `dash0-edge-proxy`            | CPU only                             |
| ConfigMap               | `dash0-edge-collector-config` | the collector configuration          |
| Deployment              | `dash0-edge-collector`        | fixed replicas, deliberately no HPA  |
| Service                 | `dash0-edge-collector`        | OTLP 4317 / 4318                     |
| PodDisruptionBudget     | `dash0-edge-collector`        | `maxUnavailable: 1`                  |
| Deployment              | `gen-checkout`                | only when `generator.enabled`        |
| NetworkPolicy           | several                       | only when `networkPolicy.enabled`    |

Resource names are fixed rather than derived from the release name. The
documentation, the NetworkPolicy selectors and the OTLP endpoint your central
collector exports to all name these two workloads literally, and a release name
prefix would make every documented `kubectl` command wrong for half the
installs. Install a second copy in a second namespace if you need one.

No `Namespace` object ships with the chart. Helm writes its own release metadata
into the target namespace before it applies any manifest, so a `Namespace`
inside a chart cannot bootstrap itself and `--create-namespace` then collides
with it. Pass `--create-namespace` and label the namespace for Pod Security
Standards afterwards, as the install guide describes. Both workloads are written
to pass `restricted`.

## Values

Only `dash0.dataset` and a token are required. Everything else has a working
default.

### `dash0`

| Key                             | Default         | What it does                                                                                                                                                                            |
|---------------------------------|-----------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `dash0.region`                  | `eu-west-1`     | Your Dash0 region, as it appears in your Dash0 URL.                                                                                                                                     |
| `dash0.domain`                  | `aws.dash0.com` | The Dash0 domain your organisation lives in. Change only if Dash0 gave you a different one.                                                                                             |
| `dash0.dataset`                 | `""`            | **Required.** The dataset slug telemetry is written to. It must already exist, and your rules must live in it: rules are looked up by dataset. Rendering fails with a message if unset. |
| `dash0.token.value`             | `""`            | A Dash0 auth token, starting with `auth_`. The chart puts it in a Secret it owns and never renders it into a Deployment.                                                                |
| `dash0.token.existingSecret`    | `""`            | Name of a Secret you created yourself. Mutually exclusive with `token.value`; when set, the chart creates no Secret.                                                                    |
| `dash0.token.existingSecretKey` | `token`         | The key inside `existingSecret` holding the raw token.                                                                                                                                  |
| `dash0.endpoints.api`           | `""`            | Explicit Dash0 API endpoint, including the scheme. Wins over the derivation.                                                                                                            |
| `dash0.endpoints.otlpIngress`   | `""`            | Explicit OTLP gRPC ingress, `host:port`, no scheme. Wins over the derivation.                                                                                                           |
| `dash0.endpoints.decisionMaker` | `""`            | Explicit Decision-Maker, `host:port`, no scheme. Wins over the derivation.                                                                                                              |

`region` and `domain` derive all three endpoints, so retargeting the whole
install is one value:

| Endpoint       | Derived as                             |
|----------------|----------------------------------------|
| Dash0 API      | `https://api.<region>.<domain>`        |
| OTLP ingress   | `ingress.<region>.<domain>:4317`       |
| Decision-Maker | `decision-maker.<region>.<domain>:443` |

An explicit `dash0.endpoints.*` value always wins over the derivation, for a
private link, an egress proxy of your own, or an environment that does not
follow the pattern. `helm install` prints the resolved endpoints and marks each
override, so you can read back what you actually got.

One token serves all three upstreams: the sampling decision stream, the settings
feed and the OTLP export. It needs ingest and read access to `dash0.dataset`.

### `namespace`

| Key                      | Default | What it does                                                                                             |
|--------------------------|---------|----------------------------------------------------------------------------------------------------------|
| `namespace.allowDefault` | `false` | Rendering fails when the target namespace is `default`. Set to `true` only if you really mean `default`. |

### `edgeProxy`

| Key                                                                      | Default                      | What it does                                                                                                                                                                                                                             |
|--------------------------------------------------------------------------|------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `edgeProxy.enabled`                                                      | `true`                       | Deploy the Edge Proxy.                                                                                                                                                                                                                   |
| `edgeProxy.replicaCount`                                                 | `3`                          | Set explicitly even with the autoscaler on: a Deployment applied without its HPA gets one replica, and a single Edge Proxy means every collector loses its decision stream at the same moment.                                           |
| `edgeProxy.image.repository`                                             | `ghcr.io/dash0hq/edge-proxy` | Public image, pulls anonymously.                                                                                                                                                                                                         |
| `edgeProxy.image.tag`                                                    | `""`                         | Empty means `.Chart.AppVersion`.                                                                                                                                                                                                         |
| `edgeProxy.image.pullPolicy`                                             | `IfNotPresent`               |                                                                                                                                                                                                                                          |
| `edgeProxy.resources`                                                    | 100m / 256Mi, 1 / 1Gi        | Memory grows with the number of connected collectors and their per subscriber buffers. Idle usage is tens of megabytes, so these are headroom rather than a measured working set.                                                        |
| `edgeProxy.gomemlimit`                                                   | `900MiB`                     | Go soft memory limit. Keep at roughly 90% of the memory limit.                                                                                                                                                                           |
| `edgeProxy.autoscaling.enabled`                                          | `true`                       |                                                                                                                                                                                                                                          |
| `edgeProxy.autoscaling.minReplicas`                                      | `3`                          |                                                                                                                                                                                                                                          |
| `edgeProxy.autoscaling.maxReplicas`                                      | `8`                          |                                                                                                                                                                                                                                          |
| `edgeProxy.autoscaling.targetCPUUtilizationPercentage`                   | `70`                         | CPU only. A memory target would never fire: the process idles far below any sane percentage of its request.                                                                                                                              |
| `edgeProxy.autoscaling.scaleDownStabilizationWindowSeconds`              | `600`                        | Every pod removed forces its collectors to reconnect, so scale in slowly.                                                                                                                                                                |
| `edgeProxy.podDisruptionBudget.enabled`                                  | `true`                       |                                                                                                                                                                                                                                          |
| `edgeProxy.podDisruptionBudget.maxUnavailable`                           | `1`                          | `maxUnavailable`, never `minAvailable`: `minAvailable: 1` on a single replica Deployment blocks node drains permanently.                                                                                                                 |
| `edgeProxy.logLevel`                                                     | `info`                       | `trace`, `debug`, `info`, `warn`, `error`.                                                                                                                                                                                               |
| `edgeProxy.debug`                                                        | `false`                      | Verbose per request logging at the network edges. Very noisy, troubleshooting only.                                                                                                                                                      |
| `edgeProxy.settingsRefreshInterval`                                      | `60s`                        | How often the settings feed is refreshed. The Edge Proxy rejects anything outside 10s to 1h.                                                                                                                                             |
| `edgeProxy.fallbackMinConnectedRatio`                                    | `"1.0"`                      | Enter fallback as soon as any upstream connection is lost, rather than the shipped default of tolerating half of them being down. Decisions for traces routed to a missing upstream never arrive, so failing loudly is the better trade. |
| `edgeProxy.nodeSelector` / `tolerations` / `affinity` / `podAnnotations` | empty                        | Standard scheduling escape hatches.                                                                                                                                                                                                      |

### `collector`

| Key                                                                      | Default                                    | What it does                                                                                                                                                                                                         |
|--------------------------------------------------------------------------|--------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `collector.enabled`                                                      | `true`                                     | Deploy the edge collector.                                                                                                                                                                                           |
| `collector.replicaCount`                                                 | `3`                                        | There is deliberately no autoscaler: every pod that goes away loses the traces buffered in its sampling reservoir, so autoscaling would trade a little CPU for a steady trickle of incomplete traces.                |
| `collector.image.repository`                                             | `ghcr.io/dash0hq/signal-control-collector` | Public image, pulls anonymously.                                                                                                                                                                                     |
| `collector.image.tag`                                                    | `""`                                       | Empty means `.Chart.AppVersion`.                                                                                                                                                                                     |
| `collector.image.pullPolicy`                                             | `IfNotPresent`                             |                                                                                                                                                                                                                      |
| `collector.resources`                                                    | 500m / 3Gi, 2 / 4Gi                        | The memory request sits close to the limit on purpose: the sampling reservoir is a real in process allocation that fills under load, so a small request invites the scheduler to overcommit the node.                |
| `collector.gomemlimit`                                                   | `3400MiB`                                  | Go soft memory limit. Keep at roughly 85% of the memory limit.                                                                                                                                                       |
| `collector.service.type`                                                 | `ClusterIP`                                | This Service is the address your central collector exports to.                                                                                                                                                       |
| `collector.reservoir.maxMemoryBytes`                                     | `"2147483648"`                             | Sampling buffer ceiling per pod, 2 GiB. Keep comfortably below the memory limit; the rest is pipeline and export overhead.                                                                                           |
| `collector.reservoir.bufferDuration`                                     | `30s`                                      | How long a trace waits for its sampling decision. The clock starts when the trace's first span arrives and is never extended, so any latency your central collector adds is subtracted from this budget.             |
| `collector.sampling.fallbackSampleRatio`                                 | `"1.0"`                                    | What happens when sampling rules are unavailable. See the choices below.                                                                                                                                             |
| `collector.logLevel`                                                     | `info`                                     |                                                                                                                                                                                                                      |
| `collector.otlpMaxRecvMsgSizeMib`                                        | `16`                                       | gRPC receive limit. The collector default is 4 MiB, which a central collector batching on your behalf will exceed. This is the one value templated into the collector config.                                        |
| `collector.edgeProxyEndpoint`                                            | `""`                                       | Where the collector reaches the Edge Proxy, for decisions and settings. Empty means the Edge Proxy Service this chart creates. Set it when you run the Edge Proxy elsewhere, or when `edgeProxy.enabled` is `false`. |
| `collector.podDisruptionBudget.enabled`                                  | `true`                                     |                                                                                                                                                                                                                      |
| `collector.podDisruptionBudget.maxUnavailable`                           | `1`                                        |                                                                                                                                                                                                                      |
| `collector.nodeSelector` / `tolerations` / `affinity` / `podAnnotations` | empty                                      | Standard scheduling escape hatches.                                                                                                                                                                                  |

### `generator`

Off by default. Turn it on only for a cluster that has nothing to send yet. It
runs one `telemetrygen` producing 30 spans/s as 10 traces/s of three identical
spans, so each rule you add moves a number you can predict.

| Key                          | Default                                                               | What it does                                                                                                                                            |
|------------------------------|-----------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| `generator.enabled`          | `false`                                                               |                                                                                                                                                         |
| `generator.image.repository` | `ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen` |                                                                                                                                                         |
| `generator.image.tag`        | `v0.158.0`                                                            |                                                                                                                                                         |
| `generator.image.pullPolicy` | `IfNotPresent`                                                        |                                                                                                                                                         |
| `generator.rate`             | `30`                                                                  | **Spans** per second, not traces. With `childSpans: 2` each trace is 3 spans, so 30 is 10 traces/s.                                                     |
| `generator.childSpans`       | `2`                                                                   |                                                                                                                                                         |
| `generator.service`          | `checkout-service`                                                    | `service.name` on the generated spans.                                                                                                                  |
| `generator.httpMethod`       | `POST`                                                                |                                                                                                                                                         |
| `generator.httpRoute`        | `/api/checkout`                                                       | With `httpMethod`, this is what lets `dash0operation` name the operation. Without both, every RED series collapses into one "Unknown operation" bucket. |
| `generator.spanDuration`     | `100ms`                                                               |                                                                                                                                                         |
| `generator.clusterName`      | `signal-control-loadgen`                                              | `k8s.cluster.name` resource attribute, so the synthetic traffic is easy to tell apart from your real services.                                          |
| `generator.environmentName`  | `test`                                                                | `deployment.environment.name` resource attribute, same reason.                                                                                          |
| `generator.resources`        | 50m / 64Mi, 300m / 128Mi                                              |                                                                                                                                                         |

Stop the traffic without uninstalling:

```sh
kubectl -n dash0-signal-control scale deploy/gen-checkout --replicas=0
```

### `networkPolicy`

| Key                                  | Default | What it does                                                                                                                                                                                                                  |
|--------------------------------------|---------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `networkPolicy.enabled`              | `false` | Apply only if your cluster runs a CNI that enforces NetworkPolicy, and smoke test it before you depend on the install.                                                                                                        |
| `networkPolicy.nodeCIDRs`            | `[]`    | Most CNIs exempt host to pod traffic, so kubelet probes pass. Some do not, and both Edge Proxy probes are on 8011 including liveness, so a blocked probe means `CrashLoopBackOff`. List your node CIDRs here if that applies. |
| `networkPolicy.otlpClientNamespaces` | `[]`    | Namespaces allowed to send OTLP to the collector. Empty means any namespace in the cluster. Narrow this to where your central collector runs.                                                                                 |

NetworkPolicy cannot match on DNS names, so the egress rules are port scoped
rather than host scoped. If your security team needs host level control, put
these hosts into your egress proxy or firewall instead:

| Workload               | Host                                              | Port     |
|------------------------|---------------------------------------------------|----------|
| `dash0-edge-proxy`     | `decision-maker.<region>.<domain>`                | TCP 443  |
| `dash0-edge-proxy`     | `api.<region>.<domain>`                           | TCP 443  |
| `dash0-edge-collector` | `ingress.<region>.<domain>`                       | TCP 4317 |
| both, at image pull    | `ghcr.io`, `pkg-containers.githubusercontent.com` | TCP 443  |

## Choices the chart makes on purpose

Read these before you change a default.

- **`collector.sampling.fallbackSampleRatio` is `1.0`, not the collector's own
  `0.01`.** An organisation with no sampling rules anywhere never receives a
  rule feed, so the collector uses this ratio. At `0.01` that keeps 1%, which is
  hard to tell apart from a working install while you are still setting rules
  up. `1.0` turns the same situation into "no reduction", which is visible.
  Lower it once your rules are in place.
- **No autoscaler on the collector.** Every pod that goes away loses the traces
  buffered in its sampling reservoir.
- **`replicaCount` is set even with the Edge Proxy autoscaler on.** A Deployment
  applied without its HPA gets one replica, and a single Edge Proxy means every
  collector loses its decision stream at the same moment.
- **The collector overrides the image entrypoint** with `command: ["/otelcol"]`.
  The image's default shell wrapper does not forward SIGTERM, so without the
  override every pod termination burns the full grace period and is then killed.
- **PodDisruptionBudgets use `maxUnavailable`, never `minAvailable`.**
  `minAvailable: 1` on a single replica Deployment blocks node drains forever.
- **The Edge Proxy Service is a plain ClusterIP**, not headless and with no
  session affinity. Each collector pins one long lived gRPC connection to one
  proxy pod, which is normal for gRPC; balancing happens across the fleet.
- **`edgeProxy.fallbackMinConnectedRatio` is `1.0`**, not the shipped `0.5`.
  Enter fallback as soon as any upstream connection is lost: decisions for
  traces routed to a missing upstream never arrive.
- **The collector exports its own telemetry straight to Dash0**, not looped back
  through its own OTLP receiver. A loopback cannot flush at shutdown, and it
  would put the collector's telemetry through the spam filter.
- **Both pod templates satisfy the `restricted` Pod Security Standard**, so the
  namespace can enforce it without further edits.

## Keeping the two collector configs in step

The collector configuration exists twice in this repository, once per install
path:

| Copy                                 | Read by                                          |
|--------------------------------------|--------------------------------------------------|
| `chart/files/collector-config.yaml`  | this chart, through `.Files.Get` and `tpl`       |
| `kubectl/base/collector-config.yaml` | the kustomize base, through `configMapGenerator` |

They are duplicated rather than shared because kustomize refuses to read a file
outside its own directory: it rejects a relative path and a symlink alike.

**They must stay in step, and they differ by exactly one line:**
`max_recv_msg_size_mib`, which the chart copy templates from
`.Values.collector.otlpMaxRecvMsgSizeMib` and the kustomize copy hardcodes to
`16`. Nothing else may differ. Check it from the repository root, in a shell
with process substitution, and expect no output:

```sh
cmp <(sed 's/max_recv_msg_size_mib:.*/max_recv_msg_size_mib: X/' chart/files/collector-config.yaml) \
    <(sed 's/max_recv_msg_size_mib:.*/max_recv_msg_size_mib: X/' kubectl/base/collector-config.yaml)
```

The self-telemetry `service.namespace` is deliberately **not** templated: it
reads `${env:POD_NAMESPACE}`, supplied from the downward API by both install
paths. Helm could template `.Release.Namespace` there, but kustomize has no
equivalent, since its `namespace:` transformer does not reach inside ConfigMap
data. The downward API is the one mechanism both paths share.

After editing either copy, validate a rendered config against the image, and
treat **any** output as failure rather than only a non-zero exit:

```sh
mkdir -p /tmp/cfg
helm template t ./chart -n dash0-signal-control \
  --set dash0.dataset=example --set dash0.token.value=auth_x \
  | python3 -c 'import sys,yaml; [sys.stdout.write(d["data"]["config.yaml"]) for d in yaml.safe_load_all(sys.stdin) if d and d.get("kind")=="ConfigMap"]' \
  > /tmp/cfg/config.yaml

cat > /tmp/cfg/collector.env <<'EOF'
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

docker run --rm --env-file /tmp/cfg/collector.env -v /tmp/cfg:/cfg:ro --entrypoint /otelcol \
  ghcr.io/dash0hq/signal-control-collector:v2.0.2756 validate --config /cfg/config.yaml
```
