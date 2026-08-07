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
kubectl -n dash0-signal-control logs deploy/dash0-edge-collector | \
  grep -E "Subscribing to edge-proxy|Edge mode detected|Using percentage memory limiter"
```

| Expected line                                                           | Why it matters                                                                                                                               |
|-------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------|
| `Subscribing to edge-proxy for settings and log patterns`               | The rule feed goes through the Edge Proxy. `Polling Dash0 API for settings` instead means `EDGE_PROXY_ENDPOINT` never reached the container. |
| `Edge mode detected, will stamp resources with edge RED metrics marker` | Without it Dash0 derives RED metrics a second time server side and every number doubles.                                                     |
| `Using percentage memory limiter total_memory_mib=4096`                 | Must match the container memory limit. If it matches the node's RAM, the pod has no limit and the memory limiter is inert.                   |

> **A Ready collector pod proves nothing: it stays Ready while the Edge Proxy is unreachable and
> while every export is failing.**

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
reduction. Read a window that ended a couple of minutes ago, because the most recent seconds are
always a partial flush.

```promql
sum(rate({otel_metric_name="otelcol_receiver_accepted_spans"}[3m]))              # in, before any rule
sum(rate({otel_metric_name="dash0.red_metrics_connector.spans_consumed"}[3m]))   # after spam filters, before sampling
sum(rate({otel_metric_name="otelcol_exporter_sent_spans"}[3m]))                  # stored, after everything
```

The middle one is what feeds RED metrics and signal-to-metrics rules. A healthy reduction is a large
gap between the first and the third with the second close to the first: sampling took the volume
out, and nothing measured was lost.

> Today the SignalControl page in the Dash0 UI measures its Spans row on the Dash0 side, after the
> edge collector has already reduced the stream, so for an edge install it understates the reduction
> achieved. Judge reduction from the three counters above rather than from that page.

## 4. What healthy looks like

| Counter                                                                             | Healthy                                                                                                                                                                                                                |
|-------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `otelcol_exporter_sent_spans`                                                       | Non-zero if you send traces                                                                                                                                                                                            |
| `otelcol_exporter_sent_log_records`                                                 | Non-zero if you send logs                                                                                                                                                                                              |
| `otelcol_exporter_sent_metric_points`                                               | Non-zero if you send metrics                                                                                                                                                                                           |
| `dash0.edge_settings.mode{mode="proxy"}`                                            | `1` on every collector pod                                                                                                                                                                                             |
| `dash0.edge_settings.grpc_stream_open`                                              | `1`                                                                                                                                                                                                                    |
| `dash0.edge_settings.rules_loaded{kind="signal_to_metrics"}`                        | Non-zero and steady. This counts the whole snapshot your organisation sends, every dataset, not the rules in yours, so do not expect it to match what you just created. A fall toward zero is the rule-wipe signature. |
| `dash0.edge_proxy.subscriber.count`                                                 | Summed across Edge Proxy pods, equals your collector pod count                                                                                                                                                         |
| `dash0.sampling_processor.spans_forwarded_fallback`                                 | **Flat once running.** A fresh collector accrues some of these in the seconds between starting and receiving its first rule snapshot, so a non-zero total right after install is expected. Judge it on `rate(...[2m])`, which must be zero. A rate above zero means rules are not reaching the collector.                                                                                                                                             |
| `dash0.trace_reservoir.watch_expirations`                                           | **Flat at zero**, by `rate(...[2m])`. An increase means decisions arrive after the trace left the buffer.                                                                                                                                  |
| `dash0.trace_reservoir.watch_matches` + `watch_direct_forwards` vs `spans_ingested` | Your real keep ratio                                                                                                                                                                                                   |
| `dash0.decision_maker_client.decisions_dropped`                                     | Zero. Non-zero means under-kept or partial traces.                                                                                                                                                                     |

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
kubectl -n dash0-signal-control exec deploy/dash0-edge-collector -- \
  sh -c 'getent hosts ingress.<region>.<domain>; ip -6 route show default'
```

The cluster side fix is a resolver that returns A records only for these names. See
[troubleshooting.md](troubleshooting.md) for the stopgap.

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
