# Troubleshooting

Symptom, cause, fix. Commands assume the default namespace `dash0-signal-control` and the two
workload names `dash0-edge-proxy` and `dash0-edge-collector`.

Three things to have ready before you start: the dataset the collector writes to, the token's scope,
and [verify.md](verify.md), because most of what looks like a bug here is one of the two credentials
pointing somewhere else.

## Symptom to cause to fix

| Symptom                                                                                               | Cause and fix                                                                                                                                                                                                                                                                                                                              |
|-------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Edge Proxy never Ready                                                                                | It cannot reach the Decision-Maker. Check token, region and egress on 443. Its own logs name the problem.                                                                                                                                                                                                                                  |
| Edge Proxy logs `Edge-settings upstream fetch failed` with `"outcome":"unauthenticated"` every minute | The rule feed credential is wrong. It is separate from the decision stream credential, and readiness stays green regardless.                                                                                                                                                                                                               |
| Collector `CrashLoopBackOff` on the first apply, `error creating AttrProc`                            | The dataset is empty. Set `DASH0_DATASET` or `dash0.dataset`.                                                                                                                                                                                                                                                                              |
| Collector logs `Polling Dash0 API for settings`                                                       | `EDGE_PROXY_ENDPOINT` is empty in the container. It works, but bypasses the Edge Proxy.                                                                                                                                                                                                                                                    |
| No `Edge mode detected` line                                                                          | The settings extension is not loaded. RED metrics will double count.                                                                                                                                                                                                                                                                       |
| `Decision-maker unavailable` once at startup, immediately followed by `Decision-maker available`      | Normal startup race, about 100 ms. The same pair repeating on a cadence means a service mesh is ageing out the connection to port 8011; relax `maxConnectionAge` on that route.                                                                                                                                                            |
| Traces arrive but nothing is ever reduced                                                             | The rules are in another dataset. The rule label, the collector's dataset and the export header must all agree. If no enabled sampling rule carries your dataset, nothing is sampled and everything is kept, which is expected rather than a fault.                                                                                                |
| A rule was created and has no effect                                                                  | Give it the full propagation window first, about a minute for a sampling rule and two for the others. Then check for a negative operator: a spam filter containing one is skipped entirely, and in a signal-to-metrics rule one evaluated against an absent attribute counts the record instead of excluding it. See [rules.md](rules.md). |
| An OTTL sampling rule on duration never matches                                                       | The `Nanoseconds(...)` wrapper is missing. Without it the expression is accepted by the API and never matches at runtime.                                                                                                                                                                                                                  |
| RED metrics roughly double the real rate                                                              | The edge marker is missing. Check the `Edge mode detected` line and that nothing strips `dash0.internal.state`.                                                                                                                                                                                                                            |
| RED metrics missing for some spans                                                                    | Those spans carry no `dash0.operation.name`, usually because identifying attributes were stripped upstream. See the table below.                                                                                                                                                                                                           |
| Incomplete traces                                                                                     | `dash0.trace_reservoir.watch_expirations` above zero. Raise the reservoir buffer duration.                                                                                                                                                                                                                                                 |
| `authentication token is not authorized to ingest into dataset`                                       | The token is restricted to a different dataset.                                                                                                                                                                                                                                                                                            |
| One signal exports fine, another times out with `DeadlineExceeded`                                    | IPv4-only pods handed an IPv6 address by DNS. See [verify.md](verify.md#5-check-every-signal-not-just-one). The cluster fix is DNS returning A records only; the stopgap is a `hostAliases` entry pinning the IPv4, which rotates, so treat it as temporary.                                                                               |
| Collector `OOMKilled`                                                                                 | Check `total_memory_mib` in the logs matches the container limit, not the node's RAM. Otherwise lower the reservoir memory ceiling.                                                                                                                                                                                                        |
| Edge Proxy `CrashLoopBackOff` after applying the NetworkPolicy                                        | Your CNI enforces host to pod traffic and the kubelet probes are blocked. Add your node CIDRs to the policy.                                                                                                                                                                                                                               |
| The whole installation disappeared after an apply                                                     | `kubectl apply --prune` was used. The shared `app.kubernetes.io/part-of` label is on the Namespace object too, so a prune takes the namespace and everything in it. Never prune against these manifests; teardown is `kubectl delete -k .` or `helm uninstall` plus deleting the namespace.                                                |
| Every number is roughly twice what you expect                                                         | The same telemetry is exported to the same Dash0 dataset twice, once by your central collector and once through the edge collector. Send the edge collector's output to a second dataset if you want a side by side.                                                                                                                       |
| Central collector logs `tls: first record does not look like a TLS handshake` and retries forever     | Its exporter to the edge collector has `tls: insecure: false`. The edge collector's OTLP receiver is plaintext gRPC inside the cluster, so this hop needs `tls: { insecure: true }`. Existing exporter blocks aimed at an internet endpoint usually carry `false`, so check it rather than copying one.                                     |
| Browser or mobile traces produce no RED metrics                                                       | Expected. RED is skipped for RUM resources, which Dash0 analyses separately. Those spans still arrive and are still tail sampled. See the table below.                                                                                                                                                                                     |
| Creating a signal-to-metrics rule returns `400 ... origin already exists in this organization`, but no listing shows it | That origin was used before and deleting the rule does not release it. The claim is organisation wide, so it can also be a rule in a dataset you cannot see. Use a different `dash0.com/origin`. Spam filters and sampling rules are not affected.                                                                             |

## Attributes that must survive the trip

The edge collector adds `dash0.`-prefixed attributes and then hashes the complete resource. Every
failure below is silent.

> **Never remove, rename or add a resource attribute after the Dash0 processors run. If you need
> redaction inside the edge collector, put it at the very start of the pipeline.**

| Attribute lost                                         | Where                      | Result                                                         |
|--------------------------------------------------------|----------------------------|----------------------------------------------------------------|
| `dash0.operation.name` / `.type`                       | after the Dash0 processors | RED metrics vanish for those spans                             |
| `dash0.dataset`                                        | after the Dash0 processors | Sampling and filtering silently target the wrong dataset       |
| `dash0.internal.state`                                 | after the Dash0 processors | RED and signal-to-metrics derived twice, doubling every number |
| `http.request.method`, `http.route`, `url.path`        | before the edge collector  | Every HTTP span becomes one `unknown` operation                |
| `db.system.name`, `db.query.text`, `db.operation.name` | before the edge collector  | The same, for database spans                                   |
| `messaging.*`, `rpc.method`, `rpc.service`             | before the edge collector  | The same, per category                                         |
| `service.name`, `service.namespace`                    | before the edge collector  | Service identity and the service catalogue                     |
| `k8s.*`, `host.*`, `container.id`                      | before the edge collector  | Kubernetes and infrastructure grouping                         |
| Anything an OTTL sampling rule references              | before the edge collector  | That rule silently never matches                               |

A trace root of kind CLIENT is always named `Unknown operation` however many HTTP attributes it
carries, so judge operation naming on the SERVER spans before concluding that attributes are
missing.

## What this deployment does not do

In gateway position behind your central collector, the edge collector sees OTLP over a socket and
nothing else. That is everything SignalControl needs and nothing that node-local agents do.

| Capability                                                  | Here                                                                                                                              | Where it comes from instead |
|-------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------|-----------------------------|
| Tail sampling, RED metrics, signal to metrics, spam filters | Yes, fully                                                                                                                        | The edge collector          |
| RED metrics for browser and mobile (RUM) traces             | No, skipped by design. The spans arrive, are tail sampled, and still feed spam filters and signal to metrics                       | Dash0 analyses RUM separately |
| `k8sattributes` enrichment                                  | No, and actively harmful: pod IP association would resolve to your gateway pod and tag every workload with the gateway's metadata | Your agent tier             |
| Host metrics, log file collection, kubelet stats            | No, needs node-local access                                                                                                       | Your agents                 |
| `resourcedetection`                                         | No, and harmful: it would describe the edge collector's own pod                                                                   | Your SDKs and agent tier    |

So your central collector needs to enrich with `service.name`, `k8s.*` and `host.*` before it
forwards. If it does not, resource views in Dash0 will look thin. The upstream Collector chart's
`presets.kubernetesAttributes.enabled: true` covers this.

### What counts as RUM

If you route browser or mobile traces through the edge collector, expect a real reduction in RED
coverage rather than a fault. A resource is treated as RUM, and skipped for RED, when any of these
holds:

| Resource attribute      | Value                                     |
|-------------------------|-------------------------------------------|
| `telemetry.sdk.language`| `webjs`, `swift`, or `javascript` together with `native.os.name` |
| `process.runtime.name`  | `browser`                                 |
| `device_name`           | contains `iphone`                         |

The decision is also made per scope, so a resource carrying both backend and browser scopes keeps
RED for its backend spans. `dash0.red_metrics_connector.spans_skipped` counts what was skipped, next
to `dash0.red_metrics_connector.spans_consumed`. If the skipped counter is most of your traffic and
you did not expect that, your RUM volume is larger than you thought rather than the connector being
broken.
