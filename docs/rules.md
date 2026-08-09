# Rules

Three rule types do the work: spam filters, signal to metrics, and tail sampling. They live in
Dash0, not in the cluster, and are pushed out to the collectors live, with no redeploy and no
restart.

## Before you start

* The edge collector and Edge Proxy are installed and healthy. See
  [install-helm.md](install-helm.md) or [install-kubectl.md](install-kubectl.md).
* **Admin on the organisation.** Creating sampling rules requires it.
* **The rules must live in the dataset the collector writes to.** Rules are looked up by dataset, so
  the rule's dataset label, the collector's `DASH0_DATASET` / `dash0.dataset`, and the token's scope
  all have to agree. Traces that arrive but are never reduced almost always mean rules in another
  dataset.

Every example below uses these three:

```bash
export DASH0_API_URL="https://api.eu-west-1.aws.dash0.com"   # your region
export DASH0_DATASET="my-dataset"
export DASH0_TOKEN="auth_..."
```

## Where each rule type acts

| Rule | Acts | Stored volume | Derived metrics |
| --- | --- | --- | --- |
| Spam filter | Earliest, before anything is derived | Down | **Down** |
| Signal to metrics | Middle | Unchanged | New metric appears |
| Tail sampling | Last, after the connectors | Down | **Unchanged** |

Filter what is worthless, derive metrics from what survives, then decide which traces are worth
storing. That ordering is also the reason to be conservative with filters and aggressive with
sampling: a filter removes telemetry for every purpose, sampling only removes it from storage.

Every rule below carries `dash0.com/origin`, set to the same value as `metadata.name`, because that
is what the delete endpoint takes as its path segment. Set it on every rule you create or you will
have to hunt the rule down in the UI to remove it.

## Spam filters

Drop telemetry you never want, as early as possible: health checks, probes, scrapers, debug logging
from noisy infrastructure. What matches is gone for every purpose, RED metrics included. `context`
is one of `span`, `log`, `datapoint`, `web_event`; `filter` entries are combined with AND.

```bash
curl -sS -X POST "${DASH0_API_URL}/api/spam-filters?dataset=${DASH0_DATASET}" \
  -H "Authorization: Bearer ${DASH0_TOKEN}" -H "Content-Type: application/json" -d '{
  "apiVersion": "v1alpha2", "kind": "Dash0SpamFilter",
  "metadata": { "name": "drop-health-checks", "labels": {
      "dash0.com/dataset": "'"${DASH0_DATASET}"'", "dash0.com/origin": "drop-health-checks" } },
  "spec": { "context": "span", "filter": [
      { "key": "http.route", "operator": "is_one_of", "values": ["/health", "/ready"] } ] }}'
```

> **Use positive operators only in spam filters: the collector skips any rule containing `is_not`,
> `is_not_one_of`, `does_not_contain` and friends, so such a rule is accepted, appears in the UI and
> quietly does nothing.**

Express the exclusion the other way round: name what you want dropped, rather than what you want
kept.

## Signal to metrics

Turn a pattern in spans or logs into a metric, derived at the edge from 100% of the signal, so you
keep the number permanently without keeping the raw telemetry. Purely additive, and immune to
whatever you sample afterwards. `match.signal` is `spans` (duration histogram) or `logs` (counter).

```bash
curl -sS -X POST "${DASH0_API_URL}/api/signal-to-metrics?dataset=${DASH0_DATASET}" \
  -H "Authorization: Bearer ${DASH0_TOKEN}" -H "Content-Type: application/json" -d '{
  "kind": "Dash0SignalToMetrics",
  "metadata": { "name": "checkout-duration", "labels": {
      "dash0.com/dataset": "'"${DASH0_DATASET}"'", "dash0.com/origin": "checkout-duration" } },
  "spec": { "enabled": true, "display": { "name": "Checkout duration" },
    "match": { "signal": "spans", "filters": [
        { "key": "http.route", "operator": "is_one_of", "values": ["/api/checkout"] } ] },
    "output": { "name": "checkout.duration", "interval": "60s" } }}'
```

> **Write signal-to-metrics filters with positive operators too. A negative operator evaluated
> against a record that does not carry the attribute at all returns true, so the record is counted
> instead of excluded.** An exclusion meant to remove a class of records can therefore silently
> include everything that never had the attribute in the first place.

Dry run first, which is also how you catch that. The body wraps the rule in `definition`, `timeRange`
is optional and defaults to the last 15 minutes, nothing is persisted, and the answer is
`matchedCount`:

```bash
curl -sS -X POST "${DASH0_API_URL}/api/signal-to-metrics/test?dataset=${DASH0_DATASET}" \
  -H "Authorization: Bearer ${DASH0_TOKEN}" -H "Content-Type: application/json" -d '{
  "definition": {
    "kind": "Dash0SignalToMetrics",
    "metadata": { "name": "checkout-duration", "labels": {
        "dash0.com/dataset": "'"${DASH0_DATASET}"'", "dash0.com/origin": "checkout-duration" } },
    "spec": { "enabled": true, "display": { "name": "Checkout duration" },
      "match": { "signal": "spans", "filters": [
          { "key": "http.route", "operator": "is_one_of", "values": ["/api/checkout"] } ] },
      "output": { "name": "checkout.duration", "interval": "60s" } } },
  "timeRange": { "from": "now-30m", "to": "now" } }'
```

> **Send the whole rule, not an abbreviation. An incomplete body returns HTTP 400
> `The request body is not valid JSON`, and piping that through `jq .matchedCount` prints `null` and
> exits 0, so the failure is silent.**

> **Keep the attributes you carry onto the metric low cardinality: every distinct combination of
> values is a separate time series.**

## Tail sampling

Decide which whole traces to store based on what is in them. The decision is taken after the full
trace has been seen and is coordinated across every collector pod, so storage falls while RED
metrics and signal-to-metrics rules do not move.

Rules are **unioned**: a trace is kept if any enabled rule matches. Condition kinds are
`probabilistic` (hashes the trace ID, so pods agree with no coordination), `error` (span status, not
an attribute), `ottl` and `and`. There is no `or`: write separate rules, or one OTTL expression.

```bash
curl -sS -X POST "${DASH0_API_URL}/api/sampling-rules" \
  -H "Authorization: Bearer ${DASH0_TOKEN}" -H "Content-Type: application/json" -d '{
  "kind": "Dash0Sampling",
  "metadata": { "name": "slow-requests", "labels": {
      "dash0.com/dataset": "'"${DASH0_DATASET}"'", "dash0.com/origin": "slow-requests" } },
  "spec": { "enabled": true, "display": { "name": "Keep requests slower than 2s" },
    "conditions": { "kind": "ottl", "spec": {
      "ottl": "end_time_unix_nano - start_time_unix_nano > Nanoseconds(Duration(\"2s\"))" } } }}'
```

> **The `Nanoseconds(...)` wrapper is required: without it the expression is accepted by the API and
> then never matches anything at runtime.**

> **Sampling-rule creation reads the dataset only from `metadata.labels["dash0.com/dataset"]`, so a
> `?dataset=` query parameter is ignored on this endpoint and the rule lands in `default`.**

### What happens before you create any sampling rule

Nothing is sampled and you keep 100% of your traces. That is the expected starting state, not a
fault, and it is why the install guides do not ask you to create a rule first.

The mechanism is worth knowing, because it is organisation-scoped rather than dataset-scoped. The
collector subscribes to one rule feed for the whole organisation, and evaluates each trace against
whichever rules carry its dataset:

| State | What the collector does | Result |
| --- | --- | --- |
| Your dataset has no rules, other datasets do | Receives the feed, finds nothing for your dataset | Pass-through, everything kept |
| Your organisation has no rules at all | Never receives a feed, so it uses `fallbackSampleRatio` | Both install paths ship `1.0`, so everything kept |

Both states keep all your data. The second is the reason both paths override
`fallbackSampleRatio` to `1.0`: the collector's own default is `0.01`, which would keep 1% and look
uncomfortably like a working install while you are still setting rules up.

## A worked example, measured

Measured against the optional traffic generator that ships with both install paths, which is
deliberately one workload: 30 spans/s as 10 traces/s of three identical spans, one root `lets-go`
(kind CLIENT) and two children `okey-dokey-0` and `okey-dokey-1` (kind SERVER), all
`checkout-service`, `POST /api/checkout`, status Unset, 100 ms. Three equal slices of 10/s, so each
rule moves a number you can predict before you add it. One rule at a time, each effect measured
before the next was added.

| Step | Rule added | Stored spans | Spans reaching the connectors | Derived metric |
| --- | --- | --- | --- | --- |
| 0 | none | 30.6/s | 30.6/s | none yet |
| 1 | signal to metrics matching `otel.span.name` `okey-dokey-0` | 30.6/s | 30.6/s | **10.0/s** |
| 2 | spam filter dropping `otel.span.name` `okey-dokey-1` | **20.6/s** | 20.6/s | 10.0/s |
| 3 | probabilistic sampling at 10% | **2.0/s** | **20.6/s** | 10.0/s |

The two rules deliberately target **different** span names, so neither moves the
other's number. Both use `otel.span.name` with `is_one_of`, in place of the
`http.route` filters shown in the examples above, which match all three spans.
Point them at the same name and the derived metric goes to zero at step 2.

Read the last row across: stored spans fell 93%, the spans feeding RED metrics did not move, and the
derived metric held steady. Step 2 lowering the middle column is the spam filter behaving correctly,
because it runs before the metric connectors while sampling runs after them.

Step 3 arithmetic, if you want to check it: after step 2 each trace carries two spans, and
probabilistic sampling keeps whole traces, so 10% of 10 traces/s is 2 spans/s.

Two notes on reading the generator's output. Its `--rate` counts spans, not traces. And a trace root
of kind CLIENT is always named `Unknown operation` however many HTTP attributes it carries, so judge
operation naming on the SERVER spans. Without `http.request.method` and `http.route` every RED series
collapses into one `Unknown operation` bucket, which is also what happens to real traffic whose
attributes were stripped upstream.

## Propagation

Rules reach the collectors by a pull with caching at more than one layer: a sampling rule in about a
minute, a spam filter or signal-to-metrics rule in about two. Wait out the full window before
concluding that a rule does not work.

## List and delete

```bash
# swap the path for spam-filters or signal-to-metrics to list those
curl -sS "${DASH0_API_URL}/api/sampling-rules?dataset=${DASH0_DATASET}" -H "Authorization: Bearer ${DASH0_TOKEN}"

curl -sS -X DELETE "${DASH0_API_URL}/api/sampling-rules/slow-requests?dataset=${DASH0_DATASET}"        -H "Authorization: Bearer ${DASH0_TOKEN}"
curl -sS -X DELETE "${DASH0_API_URL}/api/sampling-rules/baseline-5-percent?dataset=${DASH0_DATASET}"   -H "Authorization: Bearer ${DASH0_TOKEN}"
curl -sS -X DELETE "${DASH0_API_URL}/api/spam-filters/drop-health-checks?dataset=${DASH0_DATASET}"     -H "Authorization: Bearer ${DASH0_TOKEN}"
curl -sS -X DELETE "${DASH0_API_URL}/api/signal-to-metrics/checkout-duration?dataset=${DASH0_DATASET}" -H "Authorization: Bearer ${DASH0_TOKEN}"
```

Deleting the last enabled sampling rule puts the collector back into fallback, so remove the
baseline rule only when you are tearing the installation down.

## Next

* [verify.md](verify.md): what each rule should do to the numbers, and how to read them.
* [troubleshooting.md](troubleshooting.md): when a rule has no effect at all.
