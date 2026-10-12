# Capstone checklist — ship Pinboard like production

**Namespace `pinboard-prod` · folder `~/pinboard-labs/lab10` · 80 minutes**
Apply with `kubectl apply -f .` · score with
`bash ~/docker-kubernetes-training/labs/capstone/verify.sh pinboard-prod`

---

## The stack

| # | File (suggested) | Object(s) | Must have | Lab |
|---|---|---|---|---|
| 1 | `00-namespace.yaml` | Namespace `pinboard-prod` | label `pod-security.kubernetes.io/enforce: restricted` | 09 |
| 2 | `03-quota-limitrange.yaml` | ResourceQuota, LimitRange | quota on `requests.cpu`, `requests.memory`, `limits.memory`, `pods`; LimitRange default + defaultRequest. **No quota on `limits.cpu`.** | 09 |
| 3 | `01-db-secret.yaml` | Secret `pinboard-db` | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `DATABASE_URL` | 08 |
| 4 | `02-api-configmap.yaml` | ConfigMap `pinboard-api-config` | `APP_GREETING`, `APP_THEME`, `LOG_FORMAT` | 08 |
| 5 | `10-db-statefulset.yaml` | headless Service + StatefulSet `pinboard-db` | `clusterIP: None`, `serviceName`, `volumeClaimTemplates` 1 Gi, `PGDATA` subdir, probes, `securityContext` | 08 |
| 6 | `20-api-deployment.yaml` | Deployment + Service `pinboard-api` | 3 replicas, `envFrom` ConfigMap + `secretKeyRef` `DATABASE_URL`, readiness `/readyz`, liveness `/healthz`, startup probe, requests **and** memory limit, restricted `securityContext`, ClusterIP :8080 | 06–08 |
| 7 | same file | PodDisruptionBudget `pinboard-api` | `minAvailable: 2` | 09 |
| 8 | same file | HorizontalPodAutoscaler `pinboard-api` | `autoscaling/v2`, cpu 50 %, 2–6 | 09 |
| 9 | `30-web-deployment.yaml` | Deployment + Service `pinboard-web` | `API_URL=http://pinboard-api:8080`, probes, resources, `securityContext`, `emptyDir` for nginx scratch dirs | 07 |
| 10 | `40-ingress.yaml` | Ingress `pinboard` | `ingressClassName: nginx`, **`host: pinboard.localtest.me`**, `/api` → api, `/` → web | 07 |
| 11 | `60-smoke-job.yaml` | Job `pinboard-smoke` | busybox `wget` to `pinboard-web:8080` and `pinboard-api:8080/readyz`; restricted `securityContext` | 09 |

## Non-negotiables (every Pod in `pinboard-prod`)

- [ ] `runAsNonRoot: true` and `seccompProfile.type: RuntimeDefault` (Pod level)
- [ ] `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]` (container level)
- [ ] `readOnlyRootFilesystem: true` + an `emptyDir` for every writable path
- [ ] `resources.requests` (cpu **and** memory) and `resources.limits.memory`
- [ ] labels `app.kubernetes.io/name`, `/component`, `/part-of: pinboard`
- [ ] `imagePullPolicy: IfNotPresent` (images come from `kind load`, not a registry)

## Acceptance

- [ ] `kubectl -n pinboard-prod get pods` — all `Running`, all `READY 1/1`
- [ ] `kubectl -n pinboard-prod get pvc` — `Bound`
- [ ] `kubectl -n pinboard-prod get hpa` — targets are a number, not `<unknown>`
- [ ] `curl -s http://pinboard.localtest.me/api/info` → `"store":"postgres"`
- [ ] A note posted through the UI survives `kubectl -n pinboard-prod delete pod pinboard-db-0`
- [ ] `kubectl -n pinboard-prod get job pinboard-smoke` → `COMPLETIONS 1/1`
- [ ] `verify.sh` scores **25/25**

## Stretch

- [ ] Kustomize `base` + `overlays/dev` (1 replica, no HPA) and `overlays/prod`; `kubectl apply -k`
- [ ] NetworkPolicy: only web → api → db (and ingress-nginx → api)
- [ ] `helm create pinboard`, move the manifests into `templates/`, parametrise in `values.yaml`

## When you are stuck

```text
kubectl get <kind> -o wide          → what state?
kubectl describe <kind>/<name>      → Events, Last State, Reason
kubectl logs <pod> [--previous]     → what did the app say?
kubectl get events --sort-by=.lastTimestamp
kubectl debug -it <pod> --image=busybox:1.37 --target=<container> -- sh
kubectl explain <kind>.spec --recursive | less
```
