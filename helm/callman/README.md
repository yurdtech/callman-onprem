# callman

Helm chart for the Callman on-prem platform: backend API, scenario worker,
migrations Job, admin panel, optional UI-test runner, optional bundled
MongoDB/Redis. One chart for vanilla Kubernetes (Ingress) and OpenShift
(Route, restricted-v2 SCC).

```bash
helm install callman oci://ghcr.io/yurdtech/charts/callman \
  -n callman --create-namespace -f my-values.yaml
```

Full guide, secret setup, the `.env` → values mapping table, airgap
procedure: [`docs/HELM-INSTALL.md`](../../docs/HELM-INSTALL.md).

Chart 0.4.0 adds `mock.limits.*` for mock engine v2 (resources with their own
data, test sessions, imports). Its `appVersion` must point at a backend release
with mock engine v2 — it is set when the chart is released; if you override
`backend.image.tag`, pick such a release. See
[`docs/MOCK-SERVER.md`](../../docs/MOCK-SERVER.md).
