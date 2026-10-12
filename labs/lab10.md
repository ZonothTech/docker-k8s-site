# Lab 10 – Capstone: ship Pinboard like production

## Table of Contents

- [Goals](#goals)
- [Pre-requisites](#pre-requisites)
- [The checklist](#the-checklist)
- [Guide](#guide)
  - [Step 01: A blank folder and the rules of the game](#step-01-a-blank-folder-and-the-rules-of-the-game)
  - [Step 02: Namespace, ResourceQuota, LimitRange](#step-02-namespace-resourcequota-limitrange)
  - [Step 03: Secret and ConfigMap](#step-03-secret-and-configmap)
  - [Step 04: The database tier](#step-04-the-database-tier)
  - [Step 05: The API tier — Deployment, Service, PDB, HPA](#step-05-the-api-tier--deployment-service-pdb-hpa)
  - [Step 06: The web tier and the Ingress](#step-06-the-web-tier-and-the-ingress)
  - [Step 07: The smoke-test Job](#step-07-the-smoke-test-job)
  - [Step 08: Apply everything and score yourself](#step-08-apply-everything-and-score-yourself)
- [Stretch goals](#stretch-goals)
- [Conclusion](#conclusion)

## Goals

- Deploy the whole Pinboard stack into a **new** namespace `pinboard-prod`, from an
  empty folder, writing every manifest yourself
- Meet a production checklist: security context, probes, resources, quotas,
  disruption budget, autoscaling, config/secret separation, host-based ingress
- Verify your work with a smoke-test Job and the course scorecard
- Leave with a folder you could realistically hand to a colleague

## Pre-requisites

- Have finished [Lab 09](lab09.md)
- kind cluster `pinboard` running, ingress-nginx (Lab 07) and metrics-server (Lab 09)
  installed
- Images `pinboard-api:1.1` and `pinboard-web:1.0` already loaded into the cluster
  (`docker exec pinboard-control-plane crictl images | grep pinboard` to confirm)
- The course repo at `~/docker-kubernetes-training`

> **Continuity.** Nine labs built Pinboard piece by piece in the `pinboard`
> namespace, each step adding one idea. This is the exam: the same application,
> the same cluster, a **new namespace**, and no copy-paste from the solutions.
> Leave the `pinboard` namespace running — it is your reference implementation and
> you are allowed to read your own Lab 08/09 files. You are *not* meant to copy
> them wholesale: type the manifests, and use `kubectl explain` when you are unsure
> of a field.

## The checklist

Everything below lives in namespace **`pinboard-prod`**. The one-page printable
version is [`capstone/CHECKLIST.md`](capstone/CHECKLIST.md).

| # | Object | Headline requirement |
|---|---|---|
| 1 | Namespace `pinboard-prod` | enforces the `restricted` Pod Security Standard |
| 2 | ResourceQuota + LimitRange | a namespace budget and per-container defaults |
| 3 | Secret `pinboard-db` | DB credentials + `DATABASE_URL` |
| 4 | ConfigMap `pinboard-api-config` | `APP_GREETING`, `APP_THEME`, `LOG_FORMAT` |
| 5 | StatefulSet + headless Service `pinboard-db` | PostgreSQL 17 on a 1 Gi PVC |
| 6 | Deployment + Service `pinboard-api` | probes, resources, securityContext, ClusterIP :8080 |
| 7 | PodDisruptionBudget `pinboard-api` | survives a node drain |
| 8 | HorizontalPodAutoscaler `pinboard-api` | CPU 50 %, 2–6 replicas |
| 9 | Deployment + Service `pinboard-web` | nginx front-end pointing at the API Service |
| 10 | Ingress `pinboard` | host `pinboard.localtest.me`, `/api` → api, `/` → web |
| 11 | Job `pinboard-smoke` | proves the stack answers from inside the cluster |

Time budget: roughly 10 minutes for items 1–4, 15 for the database, 20 for the API,
10 for web + ingress, 10 for the Job, and 15 for fixing whatever the scorecard
finds.

## Guide

### Step 01: A blank folder and the rules of the game

```bash
mkdir -p ~/pinboard-labs/lab10
cd ~/pinboard-labs/lab10
kubectl config set-context --current --namespace=pinboard-prod
```

Rules:

1. **Everything is a file.** No `kubectl run`, no `kubectl create deployment`. The
   only imperative commands allowed are the generators that *write* a file
   (`kubectl create … --dry-run=client -o yaml > file`) and read-only commands.
2. **`kubectl apply -f .` must work from scratch.** Number your files so the order
   is sane: namespace and config first, workloads after.
3. **Three references are open book:** `kubectl explain`, the Kubernetes docs, and
   your own Lab 08 / Lab 09 folders. The `labs/solutions/` folder is closed until
   you have a scorecard.
4. **The scorecard is the definition of done:**
   `bash ~/docker-kubernetes-training/labs/capstone/verify.sh pinboard-prod`.

> **Note.** `kubectl explain` is the fastest way out of every "what is that field
> called again?" moment, and it works offline against *your* cluster's API version:
> `kubectl explain statefulset.spec.volumeClaimTemplates`,
> `kubectl explain deployment.spec.template.spec.containers.securityContext`,
> `kubectl explain hpa.spec.behavior --recursive`.

### Step 02: Namespace, ResourceQuota, LimitRange

**Requirement.** A namespace `pinboard-prod` that *enforces* the `restricted` Pod
Security Standard, plus a ResourceQuota capping the namespace and a LimitRange
giving containers sensible defaults.

**Hints.**

- Lab 09, Step 09 for the three PSA labels (`enforce`, `audit`, `warn`) and Lab 09's
  Stretch goal for the quota/limit-range shapes.
- `kubectl explain resourcequota.spec.hard` and `kubectl explain limitrange.spec.limits`.
- A quota on a resource makes that resource **mandatory** for every container in the
  namespace. The API deliberately has no CPU limit, so do not put `limits.cpu` in
  the quota.
- Sizing: the stack peaks at 6 API + 2 web + 1 db + 1 job Pod. Leave headroom.

**Acceptance.**

```bash
kubectl get ns pinboard-prod --show-labels
kubectl -n pinboard-prod get resourcequota,limitrange
```

```text
NAME            STATUS   AGE   LABELS
pinboard-prod   Active   12s   app.kubernetes.io/part-of=pinboard,kubernetes.io/metadata.name=pinboard-prod,pod-security.kubernetes.io/audit=restricted,pod-security.kubernetes.io/enforce=restricted,pod-security.kubernetes.io/warn=restricted

NAME                            AGE   REQUEST                                                                                       LIMIT
resourcequota/pinboard-quota    8s    persistentvolumeclaims: 0/4, pods: 0/20, requests.cpu: 0/2, requests.memory: 0/2Gi            limits.memory: 0/4Gi

NAME                          CREATED AT
limitrange/pinboard-defaults  2026-08-20T13:02:44Z
```

> **Warning.** From this moment every Pod you create in this namespace is judged by
> the `restricted` standard. Expect your first `apply` to be rejected — read the
> message, it lists exactly which fields are missing. That is the intended
> experience, not a mistake.

### Step 03: Secret and ConfigMap

**Requirement.** A Secret `pinboard-db` holding `POSTGRES_USER`,
`POSTGRES_PASSWORD`, `POSTGRES_DB` and a ready-made `DATABASE_URL`; a ConfigMap
`pinboard-api-config` holding `APP_GREETING`, `APP_THEME` and `LOG_FORMAT`.

**Hints.**

- Generate both instead of typing them:
  `kubectl -n pinboard-prod create secret generic … --dry-run=client -o yaml > 01-db-secret.yaml`
  and the same for `create configmap`. Lab 08, Steps 03–04.
- The host part of `DATABASE_URL` is the **Service name** you will create in the
  next step (`pinboard-db`) — inside a namespace, the short name is enough.
- Pick a different theme from the `pinboard` namespace (`sky`, `rose`) so you can
  tell the two deployments apart in the browser at a glance.
- Choose a different password from Lab 08's. It is still not a secret — it is in a
  file on your laptop — but the habit matters.

**Acceptance.**

```bash
kubectl -n pinboard-prod get secret,configmap
kubectl -n pinboard-prod get secret pinboard-db -o jsonpath='{.data.DATABASE_URL}' | base64 -d; echo
```

```text
NAME                 TYPE     DATA   AGE
secret/pinboard-db   Opaque   4      6s

NAME                            DATA   AGE
configmap/kube-root-ca.crt      1      3m
configmap/pinboard-api-config   3      4s

postgres://pinboard:pr0d-not-really-secret@pinboard-db:5432/pinboard
```

### Step 04: The database tier

**Requirement.** A headless Service `pinboard-db` and a StatefulSet `pinboard-db`
running `postgres:17-alpine` with a 1 Gi PVC from the default StorageClass, probes,
and a `restricted`-compliant security context.

**Hints.**

- Lab 08, Step 06 — and the table under it explains every non-obvious line
  (`clusterIP: None`, `serviceName`, `fsGroup: 70`, `PGDATA`, the two `emptyDir`s).
- `kubectl explain statefulset.spec.volumeClaimTemplates.spec`.
- `readOnlyRootFilesystem: true` means PostgreSQL cannot write to `/tmp` or
  `/var/run/postgresql` unless you mount volumes there. If the Pod crashes with
  `could not create lock file`, that is what is missing.
- Do **not** set `storageClassName` — letting the cluster default apply is what
  makes the manifest portable.
- The probes use `pg_isready`; the environment variables it needs come from the
  Secret via `envFrom`.

**Acceptance.**

```bash
kubectl -n pinboard-prod rollout status statefulset/pinboard-db --timeout=180s
kubectl -n pinboard-prod get sts,svc,pvc
```

```text
statefulset rolling update complete 1 pods at revision pinboard-db-6c9d7f4b85...

NAME                           READY   AGE
statefulset.apps/pinboard-db   1/1     94s

NAME                  TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)    AGE
service/pinboard-db   ClusterIP   None         <none>        5432/TCP   94s

NAME                                       STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
persistentvolumeclaim/data-pinboard-db-0   Bound    pvc-b1d47a20-8c31-4f0e-9a7e-2b6d5e0c1af3   1Gi        RWO            standard       94s
```

<details>
<summary><strong>Check yourself:</strong> your StatefulSet Pod is rejected with <code>violates PodSecurity "restricted:latest": runAsNonRoot != true</code>, but you did set <code>runAsNonRoot</code> — on the container. Why?</summary>

You almost certainly set it on the *container* but left `runAsUser` unset, so the
image's default user (root, UID 0) applies and the kubelet rejects the Pod at
start; or you set it on the container while PSA also wants the other three fields
(`allowPrivilegeEscalation`, `capabilities.drop`, `seccompProfile`). The reliable
pattern is the one in the course manifests: identity fields
(`runAsNonRoot`, `runAsUser`, `runAsGroup`, `fsGroup`, `seccompProfile`) at **Pod**
level, hardening fields (`allowPrivilegeEscalation`, `readOnlyRootFilesystem`,
`capabilities.drop`) at **container** level. Read the whole rejection message — it
names every missing field at once.
</details>

### Step 05: The API tier — Deployment, Service, PDB, HPA

**Requirement.** A Deployment `pinboard-api` (3 replicas, image `pinboard-api:1.1`)
that reads its configuration from the ConfigMap and `DATABASE_URL` from the Secret,
with readiness, liveness and startup probes, requests and a memory limit, a
`restricted` security context, and a rolling-update strategy that never drops below
full capacity. Plus a ClusterIP Service on port 8080, a PodDisruptionBudget and an
HPA.

**Hints.**

- Lab 06 for the strategy and probes, Lab 08 Step 07 for `envFrom` +
  `secretKeyRef`, Lab 09 Steps 03 and 08 for HPA and PDB.
- `imagePullPolicy: IfNotPresent` — the image exists only because of
  `kind load docker-image`; with the default policy for a non-`latest` tag you are
  fine, but being explicit documents the intent.
- Name the container port (`name: http`) and refer to it by name from the probes
  and from `Service.spec.ports.targetPort`. Renaming a port then only happens in
  one place.
- `maxUnavailable: 0` + `maxSurge: 1` = a rollout that adds a Pod before removing
  one. Combined with a readiness probe, that is a zero-downtime update.
- The HPA needs `resources.requests.cpu`, otherwise it reports `<unknown>/50%`.
- `kubectl explain hpa.spec.behavior.scaleDown`.

**Acceptance.**

```bash
kubectl -n pinboard-prod rollout status deployment/pinboard-api
kubectl -n pinboard-prod get deploy,svc,pdb,hpa
```

```text
deployment "pinboard-api" successfully rolled out

NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/pinboard-api   3/3     3            3           71s

NAME                   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
service/pinboard-api   ClusterIP   10.96.201.44   <none>        8080/TCP   71s

NAME                                             MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
poddisruptionbudget.policy/pinboard-api          2               N/A               1                     71s

NAME                                               REFERENCE                 TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/pinboard-api   Deployment/pinboard-api   cpu: 2%/50%   2         6         3          71s
```

Then prove the API really reached PostgreSQL — from inside the cluster, before any
ingress exists:

```bash
kubectl -n pinboard-prod port-forward svc/pinboard-api 18080:8080 >/dev/null &
sleep 2; curl -s localhost:18080/api/info; echo; kill %1
```

```text
{"app":"pinboard-api","greeting":"Pinboard — production","hostname":"pinboard-api-7d5c9b6f84-2q8vp","store":"postgres","theme":"sky","uptime":"48s","version":"1.1"}
```

> **Warning.** If `TARGETS` says `<unknown>/50%` for more than a minute, check in
> this order: (1) does the container declare `requests.cpu`? (2) is metrics-server
> running — `kubectl -n kube-system get deploy metrics-server`? (3) does
> `kubectl -n pinboard-prod top pods` return numbers?

### Step 06: The web tier and the Ingress

**Requirement.** A Deployment + Service `pinboard-web` (image `pinboard-web:1.0`,
`API_URL` pointing at the API Service) and an Ingress named `pinboard` that serves
the app on **`http://pinboard.localtest.me`**, routing `/api` to the API and `/` to
the web.

**Hints.**

- Lab 07 for both, with two differences: the Service name is now resolved inside
  `pinboard-prod`, and the Ingress rule gains a `host:`.
- nginx wants to write to `/var/cache/nginx`, `/var/run` and (because of `envsubst`
  templating) `/etc/nginx/conf.d`. With `readOnlyRootFilesystem: true` each of those
  needs an `emptyDir`.
- `*.localtest.me` resolves to `127.0.0.1` from anywhere, so no `/etc/hosts` edit is
  needed. Your Lab 07 Ingress has no host and keeps answering on `http://localhost`;
  ingress-nginx matches the most specific rule, so the two coexist.
- Order matters inside a rule only for readability — ingress-nginx sorts paths by
  length, so `/api` wins over `/` regardless.

**Acceptance.**

```bash
kubectl -n pinboard-prod get ingress
curl -s http://pinboard.localtest.me/api/info; echo
curl -s -o /dev/null -w '%{http_code}\n' http://pinboard.localtest.me/
```

```text
NAME       CLASS   HOSTS                   ADDRESS     PORTS   AGE
pinboard   nginx   pinboard.localtest.me   localhost   80      24s

{"app":"pinboard-api","greeting":"Pinboard — production","hostname":"pinboard-api-7d5c9b6f84-6bkzt","store":"postgres","theme":"sky","uptime":"4m2s","version":"1.1"}
200
```

Open <http://pinboard.localtest.me> in the browser, pin a couple of notes, then do
the thing this whole course has been building towards:

```bash
kubectl -n pinboard-prod delete pod pinboard-db-0
kubectl -n pinboard-prod wait --for=condition=Ready pod/pinboard-db-0 --timeout=180s
curl -s http://pinboard.localtest.me/api/notes | head -c 100; echo
```

The notes are still there.

### Step 07: The smoke-test Job

**Requirement.** A Job `pinboard-smoke` that runs once, from inside the cluster, and
fails loudly if the stack is broken: it must reach `pinboard-web:8080` and
`pinboard-api:8080/readyz`.

**Hints.**

- `kubectl create job pinboard-smoke --image=busybox:1.37 --dry-run=client -o yaml > 60-smoke-job.yaml`
  gives you the skeleton; then add the command, the security context and
  `restartPolicy: OnFailure`.
- busybox has `wget`, not `curl`: `wget -q -T 3 -O - http://pinboard-api:8080/readyz`.
- The Job runs in a `restricted` namespace: busybox defaults to root, so you need
  `runAsNonRoot`, `runAsUser: 65534`, `seccompProfile`, `allowPrivilegeEscalation:
  false` and `capabilities.drop: ["ALL"]`.
- A Job that starts before the API is ready should retry rather than fail — wrap the
  `wget` in an `until … done` loop with a bounded counter, and set `backoffLimit`.
- `ttlSecondsAfterFinished` lets the cluster clean the Job up for you.
- Make it *meaningful*: grepping `/api/info` for `"store":"postgres"` catches the
  most likely misconfiguration (an API silently running on the in-memory store).

**Acceptance.**

```bash
kubectl -n pinboard-prod apply -f 60-smoke-job.yaml
kubectl -n pinboard-prod wait --for=condition=Complete job/pinboard-smoke --timeout=120s
kubectl -n pinboard-prod logs job/pinboard-smoke
```

```text
job.batch/pinboard-smoke created
job.batch/pinboard-smoke condition met

1/3 web tier ...
    ok
2/3 api readiness ...
ready
3/3 api store ...
    ok
SMOKE TEST PASSED
```

### Step 08: Apply everything and score yourself

First, prove that the folder is self-contained. Delete the namespace and rebuild it
from your files alone — this is the only honest test of "declarative":

```bash
kubectl delete namespace pinboard-prod --wait=true
cd ~/pinboard-labs/lab10
kubectl apply -f .
```

```text
namespace "pinboard-prod" deleted
namespace/pinboard-prod created
secret/pinboard-db created
configmap/pinboard-api-config created
resourcequota/pinboard-quota created
limitrange/pinboard-defaults created
service/pinboard-db created
statefulset.apps/pinboard-db created
deployment.apps/pinboard-api created
service/pinboard-api created
poddisruptionbudget.policy/pinboard-api created
horizontalpodautoscaler.autoscaling/pinboard-api created
deployment.apps/pinboard-web created
service/pinboard-web created
ingress.networking.k8s.io/pinboard created
job.batch/pinboard-smoke created
```

> **Note.** Deleting the namespace deletes the PVC and therefore the notes — that is
> what `Delete` as a reclaim policy means. If `kubectl apply -f .` complains that a
> resource "already exists" or that the namespace is `Terminating`, wait a few
> seconds and run it again; `apply` is idempotent by design.

Give it two minutes, then run the scorecard:

```bash
bash ~/docker-kubernetes-training/labs/capstone/verify.sh pinboard-prod
```

```text
================================================================
 Pinboard capstone verification — namespace: pinboard-prod
================================================================

1. Namespace, quota and limits
  PASS  Namespace pinboard-prod exists
  PASS  Namespace enforces the restricted Pod Security Standard
  PASS  ResourceQuota present
  PASS  LimitRange present

2. Configuration and credentials
  PASS  Secret pinboard-db has POSTGRES_PASSWORD
  PASS  Secret pinboard-db has DATABASE_URL
  PASS  ConfigMap pinboard-api-config present

3. Database tier
  PASS  StatefulSet pinboard-db is ready (1)
  PASS  Headless Service pinboard-db (clusterIP: None)
  PASS  A PersistentVolumeClaim is Bound

4. API tier
  PASS  Deployment pinboard-api has >= 2 available replicas (3)
  PASS  pinboard-api declares a readiness probe
  PASS  pinboard-api declares a liveness probe
  PASS  pinboard-api sets resources.limits.memory
  PASS  pinboard-api sets resources.requests.cpu (needed by the HPA)
  PASS  pinboard-api runs as non-root
  PASS  Service pinboard-api has ready endpoints
  PASS  PodDisruptionBudget present
  PASS  HorizontalPodAutoscaler present

5. Web tier and ingress
  PASS  Deployment pinboard-web has >= 1 available replica (2)
  PASS  Service pinboard-web has ready endpoints
  PASS  Ingress is served on host pinboard.localtest.me

6. End to end
  PASS  GET http://localhost/api/info through the ingress
  PASS  API reports store=postgres
  PASS  Job pinboard-smoke completed successfully (1)

================================================================
 SCORE: 25/25 — all checks passed. Pinboard is production-shaped.
================================================================
```

Anything short of 25/25 comes with a hint on the FAIL line. Use the method, not
guesswork:

```bash
kubectl -n pinboard-prod get pods
kubectl -n pinboard-prod describe pod <name>
kubectl -n pinboard-prod logs <name> [--previous]
kubectl -n pinboard-prod get events --sort-by=.lastTimestamp | tail -20
```

Only once you have a score should you compare with the reference solution:

```bash
diff -u ~/pinboard-labs/lab10/20-api-deployment.yaml \
        ~/docker-kubernetes-training/labs/solutions/lab10/20-api-deployment.yaml
```

<details>
<summary><strong>Check yourself:</strong> the scorecard is green, but is this really "production"?</summary>

No — and knowing why is the real graduation. Missing pieces this cluster cannot
teach: TLS (cert-manager + a real certificate), a real StorageClass with backups
and a tested restore, PostgreSQL high availability (an operator, or a managed
database), image provenance and vulnerability scanning in CI, RBAC and per-workload
ServiceAccounts, monitoring/alerting and log aggregation, GitOps so the cluster
state comes from git rather than from your laptop, and a second cluster to fail over
to. The checklist you just completed is the *floor*, not the ceiling — but it is a
floor most real workloads never reach.
</details>

## Stretch goals

Pick whichever is most useful to you; each is self-contained.

### 1. Kustomize: one base, two environments

```bash
cd ~/pinboard-labs/lab10
cat > kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - 00-namespace.yaml
  - 01-db-secret.yaml
  - 02-api-configmap.yaml
  - 03-quota-limitrange.yaml
  - 10-db-statefulset.yaml
  - 20-api-deployment.yaml
  - 30-web-deployment.yaml
  - 40-ingress.yaml
  - 60-smoke-job.yaml
EOF
mkdir -p overlays/dev overlays/prod
kubectl kustomize . | head -20
```

Then write `overlays/dev/kustomization.yaml` with `resources: [../../]`, a
`replicas:` block setting `pinboard-api` and `pinboard-web` to 1, and patches that
delete the HPA and the PDB (a `minAvailable: 2` budget with one replica blocks every
eviction). Render and apply:

```bash
kubectl kustomize overlays/dev | grep -c 'kind: HorizontalPodAutoscaler'
kubectl apply -k overlays/dev
```

The reference implementation is in
`~/docker-kubernetes-training/labs/solutions/lab10/` (`kustomization.yaml`,
`overlays/dev`, `overlays/prod`).

> **Warning.** Do not add a `commonLabels`/`labels` transformer that touches
> selectors on top of manifests you have already applied: `spec.selector` is
> immutable on Deployments and StatefulSets, and the apply will be rejected.

### 2. NetworkPolicy: only web → api → db

By default every Pod in the cluster can reach every other Pod. Write
`50-networkpolicy.yaml` with two policies:

- Pods labelled `app.kubernetes.io/name: pinboard-db` accept ingress on 5432 **only**
  from Pods labelled `app.kubernetes.io/name: pinboard-api`.
- Pods labelled `app.kubernetes.io/name: pinboard-api` accept ingress on 8080 only
  from `pinboard-web`, from the smoke Job, and from the `ingress-nginx` namespace
  (`namespaceSelector` on `kubernetes.io/metadata.name`).

Test it by trying to reach the database from a Pod that is not the API:

```bash
kubectl -n pinboard-prod run probe --rm -it --image=busybox:1.37 --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"probe","image":"busybox:1.37","stdin":true,"tty":true,"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
  -- sh -c 'nc -zv -w 3 pinboard-db 5432'
```

```text
nc: pinboard-db (10.244.1.19:5432): Operation timed out
```

(Note the `--overrides`: even a debugging Pod must satisfy the `restricted`
standard now.) Remember that NetworkPolicy is enforced by the CNI — an object that
applies cleanly is not proof that anything is filtered. Always test.

### 3. Helm-ify it

```bash
cd ~/pinboard-labs
helm create pinboard-chart
rm pinboard-chart/templates/*.yaml
cp ~/pinboard-labs/lab10/*.yaml pinboard-chart/templates/
```

Now parametrise: replace the image tag with `{{ .Values.api.image.tag }}`, the
replica counts with `{{ .Values.api.replicas }}`, the greeting/theme with values,
and the Ingress host with `{{ .Values.ingress.host }}`. Then:

```bash
helm template pinboard ./pinboard-chart --set api.image.tag=1.0 | grep image:
helm install pinboard ./pinboard-chart -n pinboard-helm --create-namespace
helm list -n pinboard-helm
helm uninstall pinboard -n pinboard-helm
```

Notice what you gain (one command, one release, `helm rollback`, values per
environment) and what you pay (templating YAML with a text templater, and a chart to
maintain). Kustomize and Helm are not rivals — many teams template with Helm and
patch with Kustomize on top.

## Conclusion

**What you have now:** a folder — `~/pinboard-labs/lab10/` — that builds a complete,
secured, autoscaled, persistent three-tier application on any Kubernetes cluster
with a single `kubectl apply -f .`, and a scorecard that says so.

Over ten labs you took the same application from `docker run` to this:

| Session | What Pinboard gained |
|---|---|
| 01–02 | containers, a multi-stage 10 MB distroless image |
| 03–04 | volumes, networks, environment config, one Compose file |
| 05–06 | Pods, Deployments, probes, rolling updates and rollbacks |
| 07 | Services, DNS, Ingress |
| 08 | ConfigMaps, Secrets, a StatefulSet with a PersistentVolume |
| 09 | metrics, autoscaling, a troubleshooting method, PDB, Pod Security |
| 10 | quotas, host routing, a smoke test, packaging — and a checklist |

**Cleanup.** Keep whatever you want to keep; the cluster is disposable. To free the
machine completely:

```bash
kind delete cluster --name pinboard
docker system prune -f
```

To keep the cluster but drop only the capstone namespace:

```bash
kubectl delete namespace pinboard-prod
```

**Where to go next:** the CKAD (application-focused, closest to this course) and CKA
certifications; `kubernetes.io/docs/concepts` read cover to cover once; a free
playground (killercoda.com, labs.play-with-k8s.com) to practise without a laptop;
and — the fastest path to real fluency — take something you already run and put it
through this exact checklist.

Thank you for taking the course. Now go and pin something.
