# Install with Helm

Installs Dash0 SignalControl on the edge: an Edge Proxy and a gateway OpenTelemetry Collector, in
one namespace, from the chart in [`chart/`](../chart/). Run every command from the root of this
repository, where `chart/` sits.

If you do not have Helm, use [install-kubectl.md](install-kubectl.md) instead. Both paths produce
the same two workloads and read the same collector configuration.

## Before you start

* **A dataset that already exists** in Dash0, created under Settings, Datasets.
* **A Dash0 auth token** starting with `auth_`, with ingest and read access to that dataset.
* **Admin on the organisation**, which is what creating sampling rules requires.
* **Your region and domain**, as they appear in your Dash0 URL, for example `eu-west-1` and
  `aws.dash0.com`. Together they produce all three endpoints.
* **Helm 3.16 or 4.x** (both validated) and `kubectl` 1.27 or newer.
* **Egress on TCP** to `decision-maker.<region>.<domain>:443`, `api.<region>.<domain>:443`,
  `ingress.<region>.<domain>:4317`, and to `ghcr.io:443` plus
  `pkg-containers.githubusercontent.com:443` for image pulls. Both images are public and multi-arch,
  so mirror them into your own registry if that is what your cluster pulls from.

> **A token restricted to a different dataset fails every export with**
> **`authentication token is not authorized to ingest into dataset "..."` while every pod stays**
> **Ready.** Check the token's scope before you check anything else.

## Step 1. Create the dataset

Do this before you deploy anything. The dataset must already exist in Dash0: telemetry sent to a
dataset that does not exist is accepted, but you cannot attach rules to it afterwards.

```bash
export DASH0_API_URL="https://api.eu-west-1.aws.dash0.com"   # your region
export DASH0_DATASET="my-dataset"
export DASH0_TOKEN="auth_..."

# must print 200, not 404
curl -sS -o /dev/null -w '%{http_code}\n' \
  "${DASH0_API_URL}/api/sampling-rules?dataset=${DASH0_DATASET}" \
  -H "Authorization: Bearer ${DASH0_TOKEN}"
```

You do **not** need a sampling rule to install. Until one exists in your dataset nothing is sampled
and you keep 100% of your traces, which is the right starting point: get telemetry flowing first,
confirm it in Dash0, then add rules from [docs/rules.md](rules.md) when you want reduction.

## Step 2. Write your values

```bash
cat > my-values.yaml <<'EOF'
dash0:
  region: eu-west-1
  dataset: my-dataset
  token:
    value: auth_xxxxxxxx
EOF
```

| Key | Meaning |
| --- | --- |
| `dash0.dataset` | **Required.** Must exist, and must be the dataset your rules live in. |
| `dash0.token.value` | **Required** unless `existingSecret` is set. The chart puts it in a Secret it owns and never renders it into a Deployment. |
| `dash0.token.existingSecret` | A Secret you created yourself, one key holding the raw token. Wins over `value`. |
| `dash0.region` | Defaults to `eu-west-1`. |
| `dash0.domain` | Defaults to `aws.dash0.com`. Change only if Dash0 gave you another. |

`helm show values ./chart` has the rest, including `dash0.endpoints.api`, `.otlpIngress` and
`.decisionMaker` for pinning one endpoint individually, which is what a private link needs. An
override always wins over the region plus domain derivation, and `helm install` prints the endpoints
it resolved.

## Step 3. Install the Edge Proxy on its own

```bash
helm install signal-control-edge ./chart \
  --namespace dash0-signal-control --create-namespace \
  -f my-values.yaml --set collector.enabled=false
```

> **`--create-namespace` is required, because the chart ships no Namespace object: Helm writes its
> release Secret into the target namespace before it applies any manifest, so a Namespace inside the
> chart cannot bootstrap itself.**

The chart also refuses to install into `default` unless you set `namespace.allowDefault=true`.

## Step 4. Label the namespace

`helm install` prints this exact command when it finds the namespace unlabelled.

```bash
kubectl label namespace dash0-signal-control \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
```

> **A namespace created by `--create-namespace` carries no Pod Security labels, so labelling it is a
> required install step rather than optional hardening.**

Both workloads are written to pass `restricted`, so nothing breaks when you apply it. Confirm it
took with
`kubectl get namespace dash0-signal-control -o jsonpath='{.metadata.labels}'; echo`.

## Step 5. Use Edge Proxy readiness as a credential smoke test

The Edge Proxy's readiness gate is the authenticated connection to the Dash0 Decision-Maker, so this
step tests the token, the region and your egress rules on their own, before the collector exists.

```bash
kubectl -n dash0-signal-control wait --for=condition=available \
  --timeout=90s deploy/dash0-edge-proxy
kubectl -n dash0-signal-control logs deploy/dash0-edge-proxy --tail=40
```

| Log line | Meaning |
| --- | --- |
| `invalid bearer token` | The token in the Secret is wrong. |
| `Edge-settings upstream fetch failed`, with `"error":"upstream returned status 401"` and `"outcome":"unauthenticated"` | The rule feed credential specifically. Readiness stays green regardless. |
| Nothing after `Starting upstream client` | Egress to `decision-maker.<region>.<domain>:443` is blocked. |

**Do not deploy the collector until this wait passes.**

## Step 6. Add the collector

```bash
helm upgrade signal-control-edge ./chart -n dash0-signal-control -f my-values.yaml
kubectl -n dash0-signal-control rollout status deploy/dash0-edge-collector
```

A Ready collector pod proves nothing on its own: it stays Ready while the Edge Proxy is unreachable
and while every export is failing. [verify.md](verify.md) has the three log lines that prove the
wiring, and the counters that prove data is flowing.

## Step 7. Point your central collector at the edge collector

One exporter and one entry in your traces pipeline. The Collector fans out to every exporter
independently, so your existing destinations are unaffected.

```yaml
exporters:
  otlp/dash0-edge:
    endpoint: dash0-edge-collector.dash0-signal-control.svc.cluster.local:4317
    tls: { insecure: true }     # in-cluster plaintext
    compression: none           # use gzip if this hop crosses a network
    timeout: 10s
    # max_elapsed_time is bounded on purpose: a problem at the edge collector must never back up
    # your shared pipeline and affect your other destinations.
    retry_on_failure: { enabled: true, initial_interval: 1s, max_interval: 10s, max_elapsed_time: 60s }
    sending_queue: { enabled: true, num_consumers: 10, queue_size: 2000 }

service:
  pipelines:
    traces:
      exporters:
        - otlp/your-existing-destination      # unchanged
        - otlp/dash0-edge                     # the only addition
    logs:    { exporters: [..., otlp/dash0-edge] }     # optional
    metrics: { exporters: [..., otlp/dash0-edge] }     # optional
```

Set `send_batch_max_size` on your `batch` processor so one OTLP request stays under the receive
limit. `8192` is reasonable; the edge collector accepts 16 MiB per message
(`collector.otlpMaxRecvMsgSizeMib`). Round robin across the collector pods is correct and needs no
trace aware load balancer.

| Do not                                                    | Because                                                                                                                                                         |
|-----------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Sample upstream of the edge collector                     | RED metrics would be derived from an already reduced stream and undercount. Accurate RED from 100% of spans is the point of this deployment.                    |
| Strip or rename attributes on the way in                  | Operations collapse into one `unknown` bucket and OTTL rules stop matching. See [troubleshooting.md](troubleshooting.md#attributes-that-must-survive-the-trip). |
| Export the same telemetry to the same Dash0 dataset twice | Every span arrives twice and RED is derived twice. Point the edge collector at a second dataset instead and get a genuine side by side.                         |

## Optional test traffic

Only for a cluster with no real traffic yet:

```bash
helm upgrade signal-control-edge ./chart -n dash0-signal-control \
  -f my-values.yaml --set generator.enabled=true

kubectl -n dash0-signal-control scale deploy/gen-checkout --replicas=0   # stop the traffic
```

One generator, deliberately: every span is identical and the rate is fixed, so each rule moves a
number you can predict in advance. Its exact shape is in
[rules.md](rules.md#a-worked-example-measured).

## Sizing

The reservoir holds spans while their traces wait for a sampling decision, so it needs
`spans/s × bytes/span × reservoir.bufferDuration ÷ replicas`. At 1 KB per span, 30 s of buffer and
3 replicas, 30k spans/s needs about 300 MiB per pod. The shipped default is a 2 GiB ceiling inside a
4 GiB container.

| Value                                | Guidance                                                                                                                                              |
|--------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------|
| `collector.reservoir.maxMemoryBytes` | A ceiling, not a target. When hit, the oldest traces are evicted immediately, which shows as incomplete traces rather than an OOM kill.               |
| `collector.reservoir.bufferDuration` | Shared with the latency your central collector adds, so a 5 s batch timeout leaves about 25 s of real reassembly budget.                              |
| `collector.gomemlimit`               | Roughly 85% of the container memory limit. Always set a memory limit, or the memory limiter reads the node's RAM and never engages.                   |
| `edgeProxy.replicaCount`             | Minimum 3, with CPU based autoscaling. Never one: every collector would lose its decision stream at the same moment.                                  |
| `collector.replicaCount`             | Fixed on purpose, with no autoscaler. Every pod that stops loses the traces in its reservoir, so change it deliberately and roll when traffic is low. |

## Uninstall

```bash
helm uninstall signal-control-edge -n dash0-signal-control
kubectl delete namespace dash0-signal-control
```

The namespace is not part of the release, so it survives the uninstall.

## Next

* [verify.md](verify.md): confirm the wiring, then read the numbers.
* [rules.md](rules.md): create the spam filters, signal to metrics rules and sampling rules that do
  the actual work.
