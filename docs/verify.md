# Verify

How to tell the installation is working, and what each number means.

## Before you start

* Both workloads are installed, in the namespace `dash0-signal-control` if you kept the default. See
  [install-helm.md](install-helm.md) or [install-kubectl.md](install-kubectl.md).
* Your central collector is exporting to
  `dash0-edge-collector.dash0-signal-control.svc.cluster.local:4317`, or the optional traffic
  generator is running.
* The collector reports its own telemetry into the same dataset it exports to, so every PromQL query
  below runs in that dataset.

## 1. Three log lines prove the wiring

```bash
kubectl -n dash0-signal-control logs -l app.kubernetes.io/name=dash0-edge-collector \
  --prefix --tail=-1 | \
  grep -E "Subscribing to edge-proxy|Edge mode detected|Using percentage memory limiter"
```

| Expected line                                                           | Why it matters                                                                                                                               |
|-------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------|
| `Subscribing to edge-proxy for settings and log patterns`               | The rule feed goes through the Edge Proxy. `Polling Dash0 API for settings` instead means `EDGE_PROXY_ENDPOINT` never reached the container. |
| `Edge mode detected, will stamp resources with edge RED metrics marker` | Without it Dash0 derives RED metrics a second time server side and every number doubles.                                                     |
| `Using percentage memory limiter` with `"total_memory_mib":4096`        | The collector logs JSON, so this arrives as a field, not as `key=value`. It must match the container memory limit. If it matches the node's RAM, the pod has no limit and the memory limiter is inert. |

> **A Ready collector pod proves nothing: it stays Ready while the Edge Proxy is unreachable and
> while every export is failing.**

> **Read logs by label, not with `logs deploy/...`.** `deploy/` resolves to one arbitrary pod of the
> three, and the export failure described in section 5 hits pods individually. A single-pod read
> returned zero while another pod in the same Deployment was failing 115 exports.

## 2. The Edge Proxy is serving

Its readiness gate is the authenticated connection to the Dash0 Decision-Maker, so a Ready Edge
Proxy pod does mean the token, the region and the egress rules are right. To check the gRPC service
directly, this pod satisfies the `restricted` Pod Security Standard that the namespace enforces:

```bash
NS=dash0-signal-control
kubectl -n $NS run health --rm --attach --restart=Never \
  --image=ghcr.io/grpc-ecosystem/grpc-health-probe:v0.4.39 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"health","image":"ghcr.io/grpc-ecosystem/grpc-health-probe:v0.4.39","args":["-addr=dash0-edge-proxy.'"$NS"'.svc.cluster.local:8011","-service=readiness"],"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}'
```

**With the NetworkPolicy overlay applied this probe cannot connect.** The
default deny policy gives an ad hoc pod no egress, and the Edge Proxy only
admits port 8011 from the collector. Run it before you apply the overlay, or
read readiness from the Deployment instead:

```bash
kubectl -n dash0-signal-control get deploy dash0-edge-proxy
```

## 3. Three counters are the pipeline, in order

These are the numbers to judge the deployment on. The gap between the first and the last is your
reduction. Run them in Dash0 against the dataset the collector exports to, in a dashboard panel or
the metrics query builder. Read a window that ended a couple of minutes ago, because the most recent
seconds are always a partial flush, and give a freshly installed collector about five minutes before
you trust a `[3m]` rate: the window has to fill before it stops reading low.

```promql
sum(rate({otel_metric_name="otelcol_receiver_accepted_spans"}[3m]))              # in, before any rule
sum(rate({otel_metric_name="dash0.red_metrics_connector.spans_consumed"}[3m]))   # after spam filters, before sampling
sum(rate({otel_metric_name="otelcol_exporter_sent_spans"}[3m]))                  # stored, after everything
```

The middle one is what feeds RED metrics and signal-to-metrics rules. A healthy reduction is a large
gap between the first and the third with the second close to the first: sampling took the volume
out, and nothing measured was lost.

> Judge the reduction from these three counters. Anything measured on the Dash0 side is measured
> after the edge collector has already reduced the stream, so it cannot show you what the edge
> removed; only the collector's own counters span both sides of the reduction.

## 4. What healthy looks like

| Counter                                                                             | Healthy                                                                                                                                                                                                                |
|-------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `otelcol_exporter_sent_spans`                                                       | Non-zero if you send traces                                                                                                                                                                                            |
| `otelcol_exporter_sent_log_records`                                                 | Non-zero if you send logs                                                                                                                                                                                              |
| `otelcol_exporter_sent_metric_points`                                               | Non-zero if you send metrics                                                                                                                                                                                           |
| `dash0.edge_settings.mode{mode="proxy"}`                                            | `1` on every collector pod                                                                                                                                                                                             |
| `dash0.edge_settings.grpc_stream_open`                                              | `1` per collector pod, so `sum(...)` equals your collector replica count                                                                                                                                              |
| `dash0.edge_settings.rules_loaded{kind="signal_to_metrics"}`                        | Zero until your organisation has signal-to-metrics rules, then non-zero and steady. This counts the whole snapshot your organisation sends, every dataset, not the rules in yours, so do not expect it to match what you just created. A fall from non-zero toward zero is the rule-wipe signature. |
| `dash0.edge_proxy.subscriber.count`                                                 | Summed across Edge Proxy pods, equals your collector pod count                                                                                                                                                         |
| `dash0.sampling_processor.spans_forwarded_fallback`                                 | Depends on whether your **organisation** has any sampling rules. If it does: flat once running, and a rate above zero means rules are not reaching this collector. A fresh collector always accrues some in the seconds before its first snapshot arrives, so judge it on `rate(...[2m])`, not on the total. If your organisation has no sampling rules anywhere: this rises steadily at your full span rate, which is fallback at ratio `1.0` keeping everything, and it is correct. It stops as soon as the organisation's first rule exists. |
| `dash0.trace_reservoir.watch_expirations`                                           | **Flat at zero**, by `rate(...[2m])`. An increase means decisions arrive after the trace left the buffer.                                                                                                                                  |
| `dash0.trace_reservoir.watch_matches` + `watch_direct_forwards` vs `spans_ingested` | Your real keep ratio                                                                                                                                                                                                   |
| `dash0.decision_maker_client.decisions_dropped`                                     | Zero. Non-zero means under-kept or partial traces. These are delta counters, so a healthy install returns **no series at all** rather than a series of zeros: an empty result here is the good outcome, not a broken query. |

## 5. Check every signal, not just one

> **All three `sent_` counters must be non-zero for every signal you send: a single per-signal zero
> is the signature of an IPv4-only pod network being handed an IPv6 address by DNS, because the
> collector opens one connection per signal.**

Each signal gets its own exporter instance and its own connection, resolving independently, so which
signals break is effectively random. Two things make it hide: the series exists with value `0`, so
its presence is not evidence of success, and the failing retry is logged at `info` rather than
`error`, so it does not show up in the obvious grep.

Confirm with `grep "Exporting failed"` on the collector logs, and with an IPv6 answer plus no IPv6
default route from:

```bash
INGRESS=ingress.eu-west-1.aws.dash0.com     # your region and domain
kubectl -n dash0-signal-control exec deploy/dash0-edge-collector -- \
  sh -c "getent hosts $INGRESS; ip -6 route show default"
```

The cluster side fix is a resolver that returns A records only for these names. Until you have that,
pin the IPv4 with `hostAliases`. Helm:

```yaml
collector:
  hostAliases:
    - ip: "203.0.113.10"                          # dig +short A ingress.<region>.<domain>
      hostnames: ["ingress.eu-west-1.aws.dash0.com"]
```

kustomize: the patch must live **inside** `base/`, because kustomize refuses to read a file outside
its own directory. Write `kubectl/base/hostaliases-patch.yaml` and add
`patches:\n  - path: hostaliases-patch.yaml` to `base/kustomization.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dash0-edge-collector
spec:
  template:
    spec:
      hostAliases:
        - ip: "203.0.113.10"
          hostnames: ["ingress.eu-west-1.aws.dash0.com"]
```

**The address rotates, so this is a temporary measure that will silently stop working.** Fix the
resolver.

## 6. RED metrics are the demonstration

Put `dash0.spans.red` and `dash0.spans.red_services` next to what your other tooling reports for the
same service and the same window. They should agree while Dash0 stores a fraction of the traces:
rate, error rate and the full latency distribution are computed from every span, before sampling.

Browser and mobile telemetry is excluded from edge RED metrics by design, so a gap there is expected
rather than a fault. RED metrics for that telemetry come from the Dash0 side instead.

## 7. Give rules time

Rules reach the collectors by a pull with caching at more than one layer: a sampling rule in about a
minute, a spam filter or signal-to-metrics rule in about two. Wait out the full window before
investigating.

## Next

* [rules.md](rules.md): a measured worked example showing what each rule type does to these numbers.
* [troubleshooting.md](troubleshooting.md): symptom to cause to fix.
