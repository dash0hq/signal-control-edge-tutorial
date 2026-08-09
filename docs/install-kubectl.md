# Install with kubectl

Installs Dash0 SignalControl on the edge: an Edge Proxy and a gateway OpenTelemetry Collector, in
one namespace, from the kustomize tree in [`kubectl/`](../kubectl/). For clusters without Helm.

Same workloads, same collector configuration and same parameters as
[install-helm.md](install-helm.md), driven by two `.env` files. No YAML in that directory is edited
and nothing needs `sed`.

## Before you start

* **A dataset that already exists** in Dash0, created under Settings, Datasets.
* **A Dash0 auth token** starting with `auth_`, with ingest and read access to that dataset.
* **Admin on the organisation**, which is what creating sampling rules requires.
* **Your region and domain**, as they appear in your Dash0 URL, for example `eu-west-1` and
  `aws.dash0.com`. Together they produce all three endpoints.
* **`kubectl` 1.27 or newer**, for `apply -k` with the `labels:` transformer.
* **Egress on TCP** to `decision-maker.<region>.<domain>:443`, `api.<region>.<domain>:443`,
  `ingress.<region>.<domain>:4317`, and to `ghcr.io:443` plus
  `pkg-containers.githubusercontent.com:443` for image pulls. Both images are public and multi-arch,
  so mirror them into your own registry if that is what your cluster pulls from.

> **A token restricted to a different dataset fails every export with**
> **`authentication token is not authorized to ingest into dataset "..."` while every pod stays**
> **Ready.** Check the token's scope before you check anything else.

## Step 1. Create the dataset

Do this before you apply anything. The dataset must already exist in Dash0: telemetry sent to a
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

## Step 2. Fill in the two env files and apply

```bash
cd kubectl
cp base/dash0.env.example base/dash0.env     # DASH0_REGION, DASH0_DOMAIN, DASH0_DATASET
cp base/token.env.example base/token.env     # one line, token=auth_...
$EDITOR base/dash0.env base/token.env
kubectl apply -k .
```

| Key in `base/dash0.env` | Example         | Notes                                                           |
|-------------------------|-----------------|-----------------------------------------------------------------|
| `DASH0_REGION`          | `eu-west-1`     | As it appears in your Dash0 URL.                                |
| `DASH0_DOMAIN`          | `aws.dash0.com` | Change only if Dash0 gave you a different domain.               |
| `DASH0_DATASET`         | `my-dataset`    | **Required, ships empty.** Must exist, and must hold the rules. |

> **`DASH0_DATASET` ships blank and is required: left empty the collector refuses to start with
> `error creating AttrProc`, which is a better outcome than a fully Ready install whose rules never
> match anything.**

A `CrashLoopBackOff` on `dash0-edge-collector` right after the first apply is almost always that.
The full message is:

```
error with key "dash0.dataset" (1-th action): error creating AttrProc.
Either field "value", "from_attribute", "from_context", or "default_value" must be specified
```

The three endpoints are derived from region and domain:

```
Dash0 API        https://api.<region>.<domain>
OTLP ingress     ingress.<region>.<domain>:4317
Decision-Maker   decision-maker.<region>.<domain>:443
```

`base/token.env` holds one line, `token=auth_...`. Both files are gitignored.

This path ships its own Namespace object carrying the `restricted` Pod Security Standard labels, so
there is no namespace labelling step to do by hand.

## Step 3. Use Edge Proxy readiness as a credential smoke test

`apply -k` creates both workloads at once, so there is no staged equivalent of the Helm smoke test.
Read the Edge Proxy's readiness and its logs before you look at the collector at all: its readiness
gate is the authenticated connection to the Dash0 Decision-Maker, so it tests the token, the region
and your egress rules on their own.

```bash
kubectl -n dash0-signal-control rollout status deploy/dash0-edge-proxy --timeout=90s
kubectl -n dash0-signal-control logs deploy/dash0-edge-proxy --tail=40
```

| Log line                                                                                                               | Meaning                                                                  |
|------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------|
| `invalid bearer token`                                                                                                 | The token in the Secret is wrong.                                        |
| `Edge-settings upstream fetch failed`, with `"error":"upstream returned status 401"` and `"outcome":"unauthenticated"` | The rule feed credential specifically. Readiness stays green regardless. |
| Nothing after `Starting upstream client`                                                                               | Egress to `decision-maker.<region>.<domain>:443` is blocked.             |

Then the collector:

```bash
kubectl -n dash0-signal-control rollout status deploy/dash0-edge-collector
```

A Ready collector pod proves nothing on its own: it stays Ready while the Edge Proxy is unreachable
and while every export is failing. [verify.md](verify.md) has the three log lines that prove the
wiring, and the counters that prove data is flowing.

## Step 4. Overlays

| Overlay                          | Adds                                                                                                                                                                                 |
|----------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `kubectl apply -k endpoints`     | Explicit endpoints instead of region plus domain. Uncomment and set all three `DASH0_ENDPOINT_*` keys in `base/dash0.env` first, or the pods stop with `CreateContainerConfigError`. |
| `kubectl apply -k loadgen`       | The optional traffic generator, for a cluster with no real traffic yet.                                                                                                              |
| `kubectl apply -k networkpolicy` | Default deny plus the egress the two workloads need. Apply and smoke test it well before you need it, and add your node CIDRs first if your CNI enforces host to pod traffic.        |

**If you changed the namespace, change it in the overlay's `kustomization.yaml`
too. Each overlay declares its own `namespace:`, and one still pointing at
`dash0-signal-control` re-deploys the entire installation there.**

The `endpoints` and `loadgen` overlays do not compose. For explicit endpoints plus generated
traffic, apply `-k endpoints` then
`kubectl -n dash0-signal-control apply -f loadgen/telemetrygen.yaml`.

The generator is one workload producing an identical span every time at a fixed rate, so each rule
moves a number you can predict in advance. Its exact shape is in
[rules.md](rules.md#a-worked-example-measured). Stop the traffic without uninstalling:

```bash
kubectl -n dash0-signal-control scale deploy/gen-checkout --replicas=0
```

## Step 5. Point your central collector at the edge collector

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

If your central collector is the upstream `opentelemetry-collector` Helm chart, all of the above
goes under `config:` in its values file, and a pipeline you override there replaces the chart's
exporter list rather than adding to it, so name every destination you still want.

`tls: { insecure: true }` is not optional on this hop. The edge collector's OTLP receiver is
plaintext gRPC inside the cluster, so an exporter block copied from an existing internet facing
destination, where `insecure` is `false`, fails every export with `tls: first record does not look
like a TLS handshake`.

Set `send_batch_max_size` on your `batch` processor so one OTLP request stays under the receive
limit. `8192` is reasonable; the edge collector accepts 16 MiB per message. Round robin across the
collector pods is correct and needs no trace aware load balancer.

Your `batch` timeout is subtracted from the reservoir budget, because a trace's spans can be split
across consecutive batches. With the default `RESERVOIR_BUFFER_DURATION` of 30 s, a 10 s batch
timeout leaves about 20 s of real reassembly time. Adding the edge collector as a second exporter
also means your central collector's `memory_limiter` ceiling now covers two sending queues.

| Do not                                                    | Because                                                                                                                                                         |
|-----------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Sample upstream of the edge collector                     | RED metrics would be derived from an already reduced stream and undercount. Accurate RED from 100% of spans is the point of this deployment.                    |
| Strip or rename attributes on the way in                  | Operations collapse into one `unknown` bucket and OTTL rules stop matching. See [troubleshooting.md](troubleshooting.md#attributes-that-must-survive-the-trip). |
| Export the same telemetry to the same Dash0 dataset twice | Every span arrives twice and RED is derived twice. Point the edge collector at a second dataset instead and get a genuine side by side.                         |

## Sizing

The knobs are environment variables on the collector container in `base/edge-collector.yaml`. The
reservoir holds spans while their traces wait for a sampling decision, so it needs
`spans/s × bytes/span × RESERVOIR_BUFFER_DURATION ÷ replicas`. At 1 KB per span, 30 s of buffer and
3 replicas, 30k spans/s needs about 300 MiB per pod. The shipped default is a 2 GiB ceiling inside a
4 GiB container.

| Variable                     | Guidance                                                                                                                                |
|------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------|
| `RESERVOIR_MAX_MEMORY_BYTES` | A ceiling, not a target. When hit, the oldest traces are evicted immediately, which shows as incomplete traces rather than an OOM kill. |
| `RESERVOIR_BUFFER_DURATION`  | Shared with the latency your central collector adds, so a 5 s batch timeout leaves about 25 s of real reassembly budget.                |
| `GOMEMLIMIT`                 | Roughly 85% of the container memory limit. Always set a memory limit, or the memory limiter reads the node's RAM and never engages.     |
| Edge Proxy replicas          | Minimum 3. Never one: every collector would lose its decision stream at the same moment.                                                |
| Collector replicas           | Every pod that stops loses the traces in its reservoir, so change the count deliberately and roll when traffic is low.                  |

## Uninstall

```bash
kubectl delete -k .          # or: kubectl delete namespace dash0-signal-control
```

> **Never run `kubectl apply --prune` against these manifests: the shared `app.kubernetes.io/part-of` label
> is on the Namespace object too, so a prune takes the whole installation with it.**

## Next

* [verify.md](verify.md): confirm the wiring, then read the numbers.
* [rules.md](rules.md): create the spam filters, signal to metrics rules and sampling rules that do
  the actual work.
