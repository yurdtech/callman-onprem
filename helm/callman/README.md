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
