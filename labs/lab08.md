# Lab 08 – Give Pinboard a real database

## Table of Contents

- [Goals](#goals)
- [Pre-requisites](#pre-requisites)
- [Guide](#guide)
  - [Step 01: Prepare the lab folder](#step-01-prepare-the-lab-folder)
  - [Step 02: Watch your notes disappear](#step-02-watch-your-notes-disappear)
  - [Step 03: A ConfigMap for the API settings](#step-03-a-configmap-for-the-api-settings)
  - [Step 04: A Secret for the database credentials](#step-04-a-secret-for-the-database-credentials)
  - [Step 05: Storage on kind — the default StorageClass](#step-05-storage-on-kind--the-default-storageclass)
  - [Step 06: The database StatefulSet and its headless Service](#step-06-the-database-statefulset-and-its-headless-service)
  - [Step 07: Point the API at PostgreSQL](#step-07-point-the-api-at-postgresql)
  - [Step 08: Prove that the data survives](#step-08-prove-that-the-data-survives)
  - [Step 09: How ConfigMap changes reach a Pod](#step-09-how-configmap-changes-reach-a-pod)
- [Stretch goal](#stretch-goal)
- [Conclusion](#conclusion)

## Goals

- Separate configuration (ConfigMap) and credentials (Secret) from the container image
- See for yourself that a Secret is **encoded, not encrypted**
- Use kind's default StorageClass to provision a PersistentVolume dynamically
- Run PostgreSQL as a **StatefulSet** with a headless Service and a `volumeClaimTemplates` PVC
- Wire the API to the database and prove that notes survive a Pod deletion

## Pre-requisites

- Have finished [Lab 07](lab07.md)
- The kind cluster `pinboard` is running and `kubectl config get-contexts` shows `kind-pinboard` as current
- The course repo cloned at `~/docker-kubernetes-training` (from [Lab 00 – Course setup](lab00-setup.md))
- The images `pinboard-api:1.1` and `pinboard-web:1.0` loaded into the cluster (Labs 05–07)

> **Continuity.** After Lab 07, Pinboard runs in the `pinboard` namespace: a
> `pinboard-api` Deployment with 3 replicas (image `pinboard-api:1.1`, probes,
> resources), a `pinboard-web` Deployment and Service, and an Ingress that serves
> the whole app on <http://localhost>. There is still **no database** — the API
> falls back to an in-memory store because `DATABASE_URL` is empty. Everything you
> pin to the board dies with the Pod. This lab fixes that.

## Guide

### Step 01: Prepare the lab folder

Every lab has its own folder. Create this one and bring over the manifests you
already wrote — Lab 08 *extends* them rather than replacing them:

```bash
mkdir -p ~/pinboard-labs/lab08
cd ~/pinboard-labs/lab08
cp ~/pinboard-labs/lab07/00-namespace.yaml \
   ~/pinboard-labs/lab07/20-api-deployment.yaml \
   ~/pinboard-labs/lab07/30-web-deployment.yaml \
   ~/pinboard-labs/lab07/40-ingress.yaml .
ls
```

```text
00-namespace.yaml  20-api-deployment.yaml  30-web-deployment.yaml  40-ingress.yaml
```

Keep the two conventions you adopted in Lab 07: **one file per tier**, holding every
object that belongs to it (`20-api-deployment.yaml` has the Deployment *and* its
Service, separated by `---`), and a **numeric prefix** so that `kubectl apply -f .`
processes the folder in a sensible order — namespace, then config, then the Pods
that consume it. The gaps in the numbering (`01`, `02`, `10`) are about to be filled.

One more piece of housekeeping before the interesting work. The database you are
about to deploy runs as a non-root user with a locked-down `securityContext`, and a
namespace where one workload is hardened and two are not is worse than useless — in
Lab 09 you will make the `restricted` standard a *rule* for this namespace, and
anything that does not comply will stop being schedulable. Bring the two Lab 07
manifests up to the same level now.

In `20-api-deployment.yaml`, add a Pod-level `securityContext` next to
`terminationGracePeriodSeconds`, and a container-level one after `resources`:

```yaml
    spec:
      terminationGracePeriodSeconds: 15
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api
          # … image, ports, env, probes, resources unchanged …
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

In `30-web-deployment.yaml` the same, plus three `emptyDir` volumes: nginx needs to
write its cache, its PID file and the config that `envsubst` renders at start-up,
and `readOnlyRootFilesystem: true` takes those paths away from it:

```yaml
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101        # "nginx" user in the official image
        runAsGroup: 101
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: web
          # … image, ports, env, probes, resources unchanged …
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: cache
              mountPath: /var/cache/nginx
            - name: run
              mountPath: /var/run
            - name: conf
              mountPath: /etc/nginx/conf.d
      volumes:
        - name: cache
          emptyDir: {}
        - name: run
          emptyDir: {}
        - name: conf
          emptyDir: {}
```

> **Note.** Both images already run as a non-root user — the API is distroless
> (UID 65532) and `pinboard-web` sets `USER 101:101` (Lab 02, Step 08) — so
> `runAsNonRoot: true` only *asserts* what they do. The web Pod repeats the UID
> explicitly because the upstream `nginx` image it is built from starts as root, and
> because `runAsUser` is what makes the assertion checkable without inspecting the
> image. Session 09 covers every field here — for now, apply and move on:

```bash
kubectl apply -f .
kubectl rollout status deployment/pinboard-web
```

```text
namespace/pinboard unchanged
deployment.apps/pinboard-api configured
service/pinboard-api unchanged
deployment.apps/pinboard-web configured
service/pinboard-web unchanged
ingress.networking.k8s.io/pinboard unchanged
deployment "pinboard-web" successfully rolled out
```

Confirm that `pinboard` is still your default namespace and that the app is up:

```bash
kubectl config set-context --current --namespace=pinboard
kubectl get deploy,svc,ingress
```

```text
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/pinboard-api   3/3     3            3           41m
deployment.apps/pinboard-web   2/2     2            2           22m

NAME                   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/pinboard-api   ClusterIP   10.96.148.203   <none>        8080/TCP   41m
service/pinboard-web   ClusterIP   10.96.62.17     <none>        8080/TCP   22m

NAME                                 CLASS   HOSTS   ADDRESS     PORTS   AGE
ingress.networking.k8s.io/pinboard   nginx   *       localhost   80      19m
```

### Step 02: Watch your notes disappear

Motivation first. Pin a note through the Ingress and read the board back a few
times:

```bash
curl -s -X POST http://localhost/api/notes \
  -H 'Content-Type: application/json' \
  -d '{"text":"Buy more sticky notes","author":"you"}'
echo
for i in 1 2 3 4; do curl -s http://localhost/api/notes; echo; done
```

```text
{"id":1,"text":"Buy more sticky notes","author":"you","createdAt":"2026-08-20T09:14:22.481Z"}
[]
[{"id":1,"text":"Buy more sticky notes","author":"you","createdAt":"2026-08-20T09:14:22.481Z"}]
[]
[]
```

Read that output again: the note is there only *sometimes*. The Service
round-robins across three replicas and each replica has its **own** in-memory
list. Now restart the Deployment and look again:

```bash
kubectl rollout restart deployment/pinboard-api
kubectl rollout status deployment/pinboard-api
curl -s http://localhost/api/notes; echo
```

```text
deployment.apps/pinboard-api restarted
Waiting for deployment "pinboard-api" rollout to finish: 1 out of 3 new replicas have been updated...
deployment "pinboard-api" successfully rolled out
[]
```

Gone. The container filesystem and the process memory are both ephemeral; a
rollout, a node reboot or an OOM kill throws the data away. Two problems to solve:
**shared state** (one store all replicas talk to) and **durable state** (survives
the Pod).

> **Note.** A quick look at the logs shows the API warned you about this on every
> start: `kubectl logs deploy/pinboard-api | head -2` prints
> `level=WARN msg="DATABASE_URL not set — using in-memory store, notes will be lost on restart"`.

### Step 03: A ConfigMap for the API settings

Non-secret configuration goes into a **ConfigMap**. Instead of typing YAML from
memory, let `kubectl` generate it for you and redirect it to a file — this is the
single most useful trick in the kubectl toolbox:

```bash
kubectl create configmap pinboard-api-config \
  --from-literal=APP_GREETING="Welcome to Pinboard on Kubernetes" \
  --from-literal=APP_THEME=emerald \
  --from-literal=LOG_FORMAT=json \
  --namespace pinboard --dry-run=client -o yaml > 02-api-configmap.yaml
cat 02-api-configmap.yaml
```

```text
apiVersion: v1
data:
  APP_GREETING: Welcome to Pinboard on Kubernetes
  APP_THEME: emerald
  LOG_FORMAT: json
kind: ConfigMap
metadata:
  creationTimestamp: null
  name: pinboard-api-config
  namespace: pinboard
```

`--dry-run=client` means "build the object locally, do not send it to the API
server". `-o yaml` prints it. Together they turn any imperative `kubectl create`
into a declarative manifest you can keep in git.

Tidy it up: drop `creationTimestamp: null` and add the course labels, so the file
matches the rest of the project. The final `02-api-configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pinboard-api-config
  namespace: pinboard
  labels:
    app.kubernetes.io/name: pinboard-api
    app.kubernetes.io/part-of: pinboard
data:
  APP_GREETING: "Welcome to Pinboard on Kubernetes"
  APP_THEME: "emerald"
  LOG_FORMAT: "json"
```

Apply it:

```bash
kubectl apply -f 02-api-configmap.yaml
kubectl describe configmap pinboard-api-config
```

```text
configmap/pinboard-api-config created

Name:         pinboard-api-config
Namespace:    pinboard
Labels:       app.kubernetes.io/name=pinboard-api
              app.kubernetes.io/part-of=pinboard
Annotations:  <none>

Data
====
APP_GREETING:
----
Welcome to Pinboard on Kubernetes
APP_THEME:
----
emerald
LOG_FORMAT:
----
json

BinaryData
====

Events:  <none>
```

> **Note.** The ConfigMap now owns `APP_THEME`. In Lab 06 you set the theme to
> `amber` directly in the Deployment; from Step 07 on, config comes from here and
> the header goes back to **emerald**. That is the point of the exercise: the image
> and the manifest stop carrying environment-specific values.

### Step 04: A Secret for the database credentials

Credentials go into a **Secret**. Same generator, different subcommand:

```bash
kubectl create secret generic pinboard-db \
  --from-literal=POSTGRES_USER=pinboard \
  --from-literal=POSTGRES_PASSWORD=pinboard-secret \
  --from-literal=POSTGRES_DB=pinboard \
  --from-literal=DATABASE_URL='postgres://pinboard:pinboard-secret@pinboard-db:5432/pinboard' \
  --namespace pinboard --dry-run=client -o yaml > 01-db-secret.yaml
cat 01-db-secret.yaml
```

```text
apiVersion: v1
data:
  DATABASE_URL: cG9zdGdyZXM6Ly9waW5ib2FyZDpwaW5ib2FyZC1zZWNyZXRAcGluYm9hcmQtZGI6NTQzMi9waW5ib2FyZA==
  POSTGRES_DB: cGluYm9hcmQ=
  POSTGRES_PASSWORD: cGluYm9hcmQtc2VjcmV0
  POSTGRES_USER: cGluYm9hcmQ=
kind: Secret
metadata:
  creationTimestamp: null
  name: pinboard-db
  namespace: pinboard
```

Note the `DATABASE_URL`: `pinboard-db` is the DNS name of the Service you create in
Step 06, so the API will find the database by name inside the cluster.

Rewrite the file with `stringData` instead of `data` — the API server base64-encodes
it for you on write, and a human can still read the manifest. Save `01-db-secret.yaml`:

```yaml
# Generated in Lab 08 with:
#   kubectl -n pinboard create secret generic pinboard-db \
#     --from-literal=POSTGRES_USER=pinboard \
#     --from-literal=POSTGRES_PASSWORD=pinboard-secret \
#     --from-literal=POSTGRES_DB=pinboard \
#     --dry-run=client -o yaml > 01-db-secret.yaml
# Remember: base64 is encoding, not encryption. Never commit real secrets.
apiVersion: v1
kind: Secret
metadata:
  name: pinboard-db
  namespace: pinboard
  labels:
    app.kubernetes.io/name: pinboard-db
    app.kubernetes.io/part-of: pinboard
type: Opaque
stringData:
  POSTGRES_USER: pinboard
  POSTGRES_PASSWORD: pinboard-secret
  POSTGRES_DB: pinboard
  DATABASE_URL: postgres://pinboard:pinboard-secret@pinboard-db:5432/pinboard
```

```bash
kubectl apply -f 01-db-secret.yaml
kubectl get secret pinboard-db
```

```text
secret/pinboard-db created

NAME          TYPE     DATA   AGE
pinboard-db   Opaque   4      3s
```

Now the lesson that every Kubernetes course owes you. Read the password back:

```bash
kubectl get secret pinboard-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo
```

```text
pinboard-secret
```

> **Warning.** **Secrets are encoded, not encrypted.** Anyone who can `get secrets`
> in this namespace — or read etcd, or read your git history — has the password.
> What actually protects a Secret is: RBAC (who may `get`/`list` Secrets),
> encryption at rest on the API server (`EncryptionConfiguration`), not mounting
> Secrets a workload does not need, and keeping real values out of git by using an
> external store (External Secrets Operator, Secrets Store CSI driver, Vault,
> cloud KMS). In this course we commit `pinboard-secret` because it protects
> nothing.

<details>
<summary><strong>Check yourself:</strong> the Deployment consumes <code>APP_THEME</code> from the ConfigMap and also declares <code>env: [{name: APP_THEME, value: rose}]</code>. Which one wins?</summary>

`env` wins. Kubernetes builds the container environment from `envFrom` first and
then applies `env`, so an explicit `env` entry always overrides the same key coming
from a ConfigMap or Secret. That is handy for per-environment overrides — and a
classic source of "my ConfigMap change did nothing" confusion.
</details>

### Step 05: Storage on kind — the default StorageClass

A Pod that needs durable storage asks for a **PersistentVolumeClaim** (PVC): "give
me 1 Gi, ReadWriteOnce". A **StorageClass** decides *how* that request is
satisfied, and a provisioner creates the **PersistentVolume** (PV) on demand —
dynamic provisioning. Look at what kind gives you:

```bash
kubectl get storageclass
```

```text
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false                  93m
```

Four things to read here:

- **`standard (default)`** — a PVC that does not name a `storageClassName` gets
  this class. That is why the manifest in the next step deliberately omits it: the
  same YAML works on kind, AKS, EKS and GKE, each with their own default.
- **`rancher.io/local-path`** — kind's provisioner. It creates a directory on the
  node the Pod lands on. On a cloud cluster you would see `disk.csi.azure.com`,
  `ebs.csi.aws.com`, … talking to a CSI driver.
- **`Delete`** — the reclaim policy: when the PVC goes away, so does the PV and its
  data. `Retain` keeps the volume for manual recovery.
- **`WaitForFirstConsumer`** — the PV is not created until a Pod is scheduled, so
  the volume is created on the *right* node. With `Immediate` you can end up with a
  volume on node A and a Pod that cannot be scheduled there.

> **Warning.** `rancher.io/local-path` is node-local storage. If the node dies, the
> data dies with it, and a Pod using that volume can only ever be scheduled back to
> that same node. It is perfect for a course, wrong for production. Real clusters
> use networked/replicated storage through a CSI driver — or a managed database
> outside the cluster.

### Step 06: The database StatefulSet and its headless Service

PostgreSQL is not a stateless replica set: it has an identity, an ordered start-up
and a volume that must follow it. That is exactly what a **StatefulSet** provides —
stable Pod names (`pinboard-db-0`), a stable DNS name via a **headless Service**,
and one PVC per Pod created from `volumeClaimTemplates`.

Create `10-db-statefulset.yaml`:

```yaml
# Headless Service: gives each Pod a stable DNS name
# (pinboard-db-0.pinboard-db.pinboard.svc.cluster.local) and a plain
# "pinboard-db" name that resolves to the Pod IPs.
apiVersion: v1
kind: Service
metadata:
  name: pinboard-db
  namespace: pinboard
  labels:
    app.kubernetes.io/name: pinboard-db
    app.kubernetes.io/component: database
    app.kubernetes.io/part-of: pinboard
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: pinboard-db
  ports:
    - name: postgres
      port: 5432
      targetPort: postgres
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: pinboard-db
  namespace: pinboard
  labels:
    app.kubernetes.io/name: pinboard-db
    app.kubernetes.io/component: database
    app.kubernetes.io/part-of: pinboard
spec:
  serviceName: pinboard-db
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: pinboard-db
  template:
    metadata:
      labels:
        app.kubernetes.io/name: pinboard-db
        app.kubernetes.io/component: database
        app.kubernetes.io/part-of: pinboard
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 70          # "postgres" user in the alpine image
        runAsGroup: 70
        fsGroup: 70
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: postgres
          image: postgres:17-alpine
          ports:
            - name: postgres
              containerPort: 5432
          envFrom:
            - secretRef:
                name: pinboard-db
          env:
            # Put the data in a sub-directory so the PVC's lost+found doesn't confuse initdb.
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
            - name: tmp
              mountPath: /tmp
            - name: run
              mountPath: /var/run/postgresql
          readinessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
            initialDelaySeconds: 30
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
      volumes:
        - name: tmp
          emptyDir: {}
        - name: run
          emptyDir: {}
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        # No storageClassName → the cluster default (kind: "standard", local-path provisioner)
        resources:
          requests:
            storage: 1Gi
```

Line by line, the parts that are not obvious:

| Field | Why it is there |
|---|---|
| `clusterIP: None` | Makes the Service **headless**: no virtual IP, no load balancing. DNS returns the Pod IPs directly, and each Pod also gets `<pod>.<service>.<ns>.svc.cluster.local`. A database needs to be addressed, not load-balanced. |
| `serviceName: pinboard-db` | Ties the StatefulSet to that headless Service — this is what makes the per-Pod DNS names exist. |
| `securityContext.runAsUser/runAsGroup: 70` | UID/GID of `postgres` in `postgres:17-alpine`. Without it the image starts as root and drops privileges itself; we refuse root outright (`runAsNonRoot: true`) because Session 09 turns on Pod Security Admission. |
| `fsGroup: 70` | On volume types that support it (cloud disks via CSI), the kubelet makes the mounted volume group-owned by GID 70, otherwise the non-root process cannot write to a freshly provisioned disk. kind's local-path volumes are plain host directories created world-writable, so here it changes nothing — it is there so the same manifest works on a cloud cluster. |
| `seccompProfile: RuntimeDefault` | Uses the container runtime's default seccomp filter instead of "unconfined". Required by the `restricted` PSA level. |
| `readOnlyRootFilesystem: true` | The container's own filesystem is immutable. Anything the process must write to needs an explicit volume — hence the two `emptyDir`s. |
| `emptyDir` on `/tmp` and `/var/run/postgresql` | Scratch space and the Unix socket directory. `emptyDir` lives and dies with the **Pod** (not the container), which is fine for both. |
| `PGDATA=/var/lib/postgresql/data/pgdata` | `initdb` refuses to run in a non-empty directory, and a freshly provisioned volume may contain `lost+found`. Pointing `PGDATA` at a sub-directory avoids the classic "directory exists but is not empty" crash loop. |
| `envFrom.secretRef` | Injects `POSTGRES_USER`/`PASSWORD`/`DB` — the official image uses them to bootstrap the cluster on first start. |
| `volumeClaimTemplates` | The StatefulSet creates one PVC per Pod, named `<template>-<pod>` → `data-pinboard-db-0`. Scaling to 2 would create `data-pinboard-db-1`. Deleting the StatefulSet does **not** delete these PVCs — deliberate, so you cannot lose a database by mistyping a `kubectl delete`. |

Apply it and watch the Pod come up:

```bash
kubectl apply -f 10-db-statefulset.yaml
kubectl rollout status statefulset/pinboard-db --timeout=180s
```

```text
service/pinboard-db created
statefulset.apps/pinboard-db created
Waiting for 1 pods to be ready...
statefulset rolling update complete 1 pods at revision pinboard-db-7c9f6b8d54...
```

Now look at the three objects the one manifest produced:

```bash
kubectl get sts,pvc,pv
```

```text
NAME                           READY   AGE
statefulset.apps/pinboard-db   1/1     71s

NAME                                      STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
persistentvolumeclaim/data-pinboard-db-0   Bound    pvc-6f0c1b9e-25a4-4c7c-9a0f-1c0f3a8b7d21   1Gi        RWO            standard       71s

NAME                                                        CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                            STORAGECLASS   AGE
persistentvolume/pvc-6f0c1b9e-25a4-4c7c-9a0f-1c0f3a8b7d21   1Gi        RWO            Delete           Bound    pinboard/data-pinboard-db-0      standard       69s
```

The PVC is the *request*, the PV is the *thing*. You wrote only the request; the
local-path provisioner created the PV and bound them together. `describe` shows the
whole story:

```bash
kubectl describe pvc data-pinboard-db-0
```

```text
Name:          data-pinboard-db-0
Namespace:     pinboard
StorageClass:  standard
Status:        Bound
Volume:        pvc-6f0c1b9e-25a4-4c7c-9a0f-1c0f3a8b7d21
Labels:        app.kubernetes.io/name=pinboard-db
Annotations:   pv.kubernetes.io/bind-completed: yes
               volume.kubernetes.io/selected-node: pinboard-worker
Capacity:      1Gi
Access Modes:  RWO
VolumeMode:    Filesystem
Used By:       pinboard-db-0
Events:
  Type    Reason                 Age   From                                                              Message
  ----    ------                 ----  ----                                                              -------
  Normal  WaitForFirstConsumer   84s   persistentvolume-controller                                       waiting for first consumer to be created before binding
  Normal  Provisioning           83s   rancher.io/local-path_local-path-provisioner-.../...              External provisioner is provisioning volume for claim "pinboard/data-pinboard-db-0"
  Normal  ProvisioningSucceeded  81s   rancher.io/local-path_local-path-provisioner-.../...              Successfully provisioned volume pvc-6f0c1b9e-25a4-4c7c-9a0f-1c0f3a8b7d21
```

`selected-node: pinboard-worker` is `WaitForFirstConsumer` in action — remember that
node name, it comes back in Step 08 and in the Stretch goal.

### Step 07: Point the API at PostgreSQL

The API switches store implementations purely on `DATABASE_URL`. Open your
`20-api-deployment.yaml` and replace the hand-written `env:` block from Lab 06 with
config from the two objects you just created. The container section becomes:

```yaml
        - name: api
          image: pinboard-api:1.1
          imagePullPolicy: IfNotPresent   # images are loaded with `kind load docker-image`
          ports:
            - name: http
              containerPort: 8080
          envFrom:
            - configMapRef:
                name: pinboard-api-config
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: pinboard-db
                  key: DATABASE_URL
```

Leave the probes, resources and `securityContext` exactly as they are. Two idioms
are worth naming:

- **`envFrom.configMapRef`** — every key of the ConfigMap becomes an environment
  variable with the same name. Cheap and readable, but it only works when the keys
  are already valid env var names.
- **`env.valueFrom.secretKeyRef`** — pull *one* key out of a Secret. Prefer this
  over `envFrom` for Secrets: the container gets only what it needs, and you can see
  in the manifest which value comes from where.

Apply and watch the rollout:

```bash
kubectl apply -f 20-api-deployment.yaml
kubectl rollout status deployment/pinboard-api
```

```text
deployment.apps/pinboard-api configured
Waiting for deployment "pinboard-api" rollout to finish: 1 old replicas are pending termination...
deployment "pinboard-api" successfully rolled out
```

Ask the API what it thinks it is:

```bash
curl -s http://localhost/api/info; echo
```

```text
{"app":"pinboard-api","greeting":"Welcome to Pinboard on Kubernetes","hostname":"pinboard-api-6d4f7b8c9d-2xk4t","store":"postgres","theme":"emerald","uptime":"12s","version":"1.1"}
```

`"store":"postgres"` — the API connected to the database, created the `notes`
table if it was missing, and `/readyz` now genuinely pings PostgreSQL. The greeting
and the theme come from the ConfigMap. Refresh <http://localhost> in the browser:
the header is emerald again and shows the new greeting.

The logs are JSON now, because the ConfigMap set `LOG_FORMAT=json`:

```bash
kubectl logs deploy/pinboard-api | head -2
```

```text
{"time":"2026-08-20T09:31:04.118Z","level":"INFO","msg":"pinboard-api starting","version":"1.1","theme":"emerald","store":"postgres","addr":":8080","hostname":"pinboard-api-6d4f7b8c9d-2xk4t"}
{"time":"2026-08-20T09:31:04.402Z","level":"INFO","msg":"request","method":"GET","path":"/api/info","status":200,"duration":"1.204ms"}
```

> **Note.** If the API had started *before* the database was ready, it would not
> have crashed: `newPGStore` retries the first connection 30 times, two seconds
> apart. Retrying beats ordering — Kubernetes gives you no `depends_on`, and any
> dependency can disappear later anyway.

### Step 08: Prove that the data survives

Pin a few notes, this time for real:

```bash
for t in "Kubernetes stores state in etcd" "PVCs outlive Pods" "Secrets are only base64"; do
  curl -s -X POST http://localhost/api/notes -H 'Content-Type: application/json' \
    -d "{\"text\":\"$t\",\"author\":\"lab08\"}" > /dev/null
done
curl -s http://localhost/api/notes; echo
```

```text
[{"id":3,"text":"Secrets are only base64","author":"lab08","createdAt":"2026-08-20T09:33:51.902Z"},{"id":2,"text":"PVCs outlive Pods","author":"lab08","createdAt":"2026-08-20T09:33:51.771Z"},{"id":1,"text":"Kubernetes stores state in etcd","author":"lab08","createdAt":"2026-08-20T09:33:51.630Z"}]
```

Call it as many times as you like — all three replicas now return the same list,
because they share one store. Now delete the database Pod:

```bash
kubectl delete pod pinboard-db-0
kubectl get pod -l app.kubernetes.io/name=pinboard-db -w
```

```text
pod "pinboard-db-0" deleted
NAME            READY   STATUS        RESTARTS   AGE
pinboard-db-0   1/1     Terminating   0          6m18s
pinboard-db-0   0/1     Pending       0          0s
pinboard-db-0   0/1     ContainerCreating   0     1s
pinboard-db-0   0/1     Running       0          3s
pinboard-db-0   1/1     Running       0          8s
```

Press `Ctrl-C` to stop watching. The StatefulSet recreated the Pod with the **same
name**, on the same node, and re-attached the **same PVC**. Read the board back:

```bash
curl -s http://localhost/api/notes | head -c 120; echo
```

```text
[{"id":3,"text":"Secrets are only base64","author":"lab08","createdAt":"2026-08-20T09:33:51.902Z"},{"i
```

The notes survived a Pod deletion. Go one level deeper and read the table with
`psql` inside the container:

```bash
kubectl exec -it pinboard-db-0 -- psql -U pinboard -d pinboard -c 'select * from notes'
```

```text
 id |              text               | author |          created_at
----+---------------------------------+--------+-------------------------------
  1 | Kubernetes stores state in etcd | lab08  | 2026-08-20 09:33:51.630612+00
  2 | PVCs outlive Pods               | lab08  | 2026-08-20 09:33:51.771043+00
  3 | Secrets are only base64         | lab08  | 2026-08-20 09:33:51.902118+00
(3 rows)
```

> **Note.** `kubectl exec` needs no password because `psql` connects over the local
> Unix socket as the `postgres` OS user (`trust` auth locally). Over TCP the
> password from the Secret is required — that is what the API uses.

<details>
<summary><strong>Check yourself:</strong> you run <code>kubectl delete statefulset pinboard-db</code>. Are the notes gone?</summary>

No. `volumeClaimTemplates` PVCs are intentionally **not** garbage-collected with
the StatefulSet, so `data-pinboard-db-0` (and its PV, and the data) stays. Re-apply
the manifest and `pinboard-db-0` binds the very same claim and finds its database.
The data disappears only when you delete the PVC — and then the `Delete` reclaim
policy removes the PV too. Kubernetes 1.27+ can change this with
`persistentVolumeClaimRetentionPolicy` if you *want* deletion to cascade.
</details>

### Step 09: How ConfigMap changes reach a Pod

Change the greeting in the ConfigMap:

```bash
kubectl patch configmap pinboard-api-config \
  --type merge -p '{"data":{"APP_GREETING":"Pinned in Kubernetes 1.37"}}'
curl -s http://localhost/api/info; echo
```

```text
configmap/pinboard-api-config patched
{"app":"pinboard-api","greeting":"Welcome to Pinboard on Kubernetes","hostname":"pinboard-api-6d4f7b8c9d-2xk4t","store":"postgres","theme":"emerald","uptime":"4m2s","version":"1.1"}
```

Nothing changed. **Environment variables are copied into the container at start
time** and there is no way to change a running process's environment. The Pods must
be replaced:

```bash
kubectl rollout restart deployment/pinboard-api
kubectl rollout status deployment/pinboard-api
curl -s http://localhost/api/info; echo
```

```text
deployment.apps/pinboard-api restarted
deployment "pinboard-api" successfully rolled out
{"app":"pinboard-api","greeting":"Pinned in Kubernetes 1.37","hostname":"pinboard-api-58c7d9f4b6-hn9lm","store":"postgres","theme":"emerald","uptime":"9s","version":"1.1"}
```

**Optional (≈ 5 min, the instructor demo showed it).** A ConfigMap mounted as a
**volume** behaves differently: the kubelet refreshes the files in place. Prove it
with a throwaway Pod. If you are short on time, skip to the last command block of this
step. Create `configmap-volume-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cm-watch
  namespace: pinboard
spec:
  containers:
    - name: watch
      image: busybox:1.37
      command: ["sh", "-c", "while true; do date +%T; cat /config/APP_GREETING; echo; sleep 10; done"]
      volumeMounts:
        - name: config
          mountPath: /config
          readOnly: true
  volumes:
    - name: config
      configMap:
        name: pinboard-api-config
```

```bash
kubectl apply -f configmap-volume-pod.yaml
kubectl logs -f cm-watch
```

Leave it streaming, and in a second terminal patch the ConfigMap again:

```bash
kubectl -n pinboard patch configmap pinboard-api-config \
  --type merge -p '{"data":{"APP_GREETING":"Live update, no restart"}}'
```

Within about a minute the streaming log flips over on its own:

```text
09:40:12
Pinned in Kubernetes 1.37
09:40:22
Pinned in Kubernetes 1.37
09:41:02
Live update, no restart
```

Stop the log with `Ctrl-C`, then delete the Pod **and its file** — otherwise the
`kubectl apply -f .` in the next labs would bring the throwaway Pod back (`--now`
because a shell loop as PID 1 ignores SIGTERM and would sit out the 30 s grace period):

```bash
kubectl delete -f configmap-volume-pod.yaml --now
rm configmap-volume-pod.yaml
```

> **Note.** The refresh is not instant: the kubelet re-syncs mounted ConfigMaps and
> Secrets roughly every minute (`configMapAndSecretChangeDetectionStrategy`, sync
> period + cache TTL), and `subPath` mounts are **never** updated. So: mounted files
> update live but with a delay, env vars never update, and your application still
> has to notice the file changed. Many apps watch the file; most don't — which is
> why `kubectl rollout restart` is the honest answer for config changes.

Finally, restore the greeting the manifest declares, and note the immutability
option:

```bash
kubectl apply -f 02-api-configmap.yaml
kubectl rollout restart deployment/pinboard-api
```

> **Note.** Adding `immutable: true` to a ConfigMap or Secret forbids any later
> change to `data` (you must delete and recreate it). It protects you from
> accidental edits and lets the kubelet stop watching the object, which measurably
> reduces API server load in large clusters. The usual pattern is
> immutable + a content hash in the name (`pinboard-api-config-7f3a1c`) so that a
> config change *is* a new object and therefore a normal rolling update.

## Stretch goal

1. **`emptyDir` is Pod-scoped, not container-scoped.** Run a Pod with two
   containers sharing an `emptyDir`, write from one, read from the other, then
   `kubectl delete pod` and confirm the data is gone:

   ```bash
   kubectl run scratch --image=busybox:1.37 --restart=Never -it --rm \
     --overrides='{"spec":{"containers":[{"name":"scratch","image":"busybox:1.37","stdin":true,"tty":true,"volumeMounts":[{"name":"tmp","mountPath":"/scratch"}]}],"volumes":[{"name":"tmp","emptyDir":{}}]}}' -- sh
   # inside: echo hello > /scratch/file; ls -l /scratch; exit
   ```

   `emptyDir` survives a container **restart** (crash, liveness kill) but not Pod
   deletion. That is exactly why the database uses a PVC and only its scratch
   directories use `emptyDir`.

2. **Find the bytes on the node.** The PV is a directory on a kind node — which is
   itself a Docker container:

   ```bash
   kubectl get pv -o yaml | grep -A6 'nodeAffinity\|hostPath:\|local:'
   docker exec pinboard-worker ls -l /var/local-path-provisioner
   docker exec pinboard-worker ls -l /var/local-path-provisioner/pvc-6f0c1b9e-25a4-4c7c-9a0f-1c0f3a8b7d21_pinboard_data-pinboard-db-0/pgdata | head
   ```

   ```text
   total 4
   drwxrwxrwx 3 root root 4096 Aug 20 09:26 pvc-6f0c1b9e-25a4-4c7c-9a0f-1c0f3a8b7d21_pinboard_data-pinboard-db-0
   ```

   The `nodeAffinity` block in the PV pins it to `pinboard-worker`: any Pod that
   claims it can *only* be scheduled there. Keep that in mind in Lab 09 when you
   drain a node.

3. **Break it on purpose.** In `01-db-secret.yaml`, change the password inside
   `DATABASE_URL` only (leave `POSTGRES_PASSWORD` alone), `kubectl apply -f
   01-db-secret.yaml` and `kubectl rollout restart deployment/pinboard-api`. The new API
   Pod never becomes `Ready` and ends in `CrashLoopBackOff`: read
   `kubectl logs <new-pod>` (`database not ready, retrying … password authentication
   failed`) and `kubectl describe pod <new-pod>` (startup probe failures, restarts). The
   old Pods keep serving — `maxUnavailable: 0` from Lab 06 at work. Restore the file and
   re-apply it; the next restart of the crashing Pod picks up the right value and the
   rollout completes. Note the asymmetry: changing `POSTGRES_PASSWORD` alone would break
   *nothing* — PostgreSQL only reads it to bootstrap an empty data directory, and the
   data directory already exists.

## Conclusion

**What you have now**, all of it declared in `~/pinboard-labs/lab08/`:

| File | Object |
|---|---|
| `00-namespace.yaml` | Namespace `pinboard` |
| `01-db-secret.yaml` | Secret `pinboard-db` (credentials + `DATABASE_URL`) |
| `02-api-configmap.yaml` | ConfigMap `pinboard-api-config` (greeting, theme, log format) |
| `10-db-statefulset.yaml` | Headless Service + StatefulSet `pinboard-db` with a 1 Gi PVC |
| `20-api-deployment.yaml` | Deployment + Service `pinboard-api`, now database-backed |
| `30-web-deployment.yaml` | Deployment + Service `pinboard-web` |
| `40-ingress.yaml` | Ingress `pinboard` on <http://localhost> |

You can rebuild the entire application on a fresh cluster with a single
`kubectl apply -f .`, and the notes now live in a PersistentVolume that outlives
every Pod that touches it. You also know the honest limits: base64 is not
encryption, local-path storage is node-bound, and env vars from a ConfigMap need a
restart.

**Cleanup: none.** Leave everything running — Lab 09 autoscales this exact
Deployment, breaks it on purpose and drains a node underneath it. If you deleted
the throwaway `cm-watch` Pod and its file, you are already in the right state (the
folder holds exactly the seven files above):

```bash
kubectl get all
```

Next: [Lab 09 – Operate Pinboard](lab09.md).
