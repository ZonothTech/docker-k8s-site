# Lab 05 – Pinboard meets Kubernetes

## Table of Contents

- [Goals](#goals)
- [Pre-requisites](#pre-requisites)
- [Guide](#guide)
  - [Step 01: Create the kind cluster](#step-01-create-the-kind-cluster)
  - [Step 02: Look around the cluster](#step-02-look-around-the-cluster)
  - [Step 03: Load the Pinboard images into the cluster](#step-03-load-the-pinboard-images-into-the-cluster)
  - [Step 04: A namespace of your own](#step-04-a-namespace-of-your-own)
  - [Step 05: Your first Pod, imperatively](#step-05-your-first-pod-imperatively)
  - [Step 06: The same Pod, declaratively](#step-06-the-same-pod-declaratively)
  - [Step 07: Read the object, read the events](#step-07-read-the-object-read-the-events)
  - [Step 08: Break it — a Pod that cannot pull](#step-08-break-it--a-pod-that-cannot-pull)
  - [Step 09: A multi-container Pod with a sidecar](#step-09-a-multi-container-pod-with-a-sidecar) *(optional)*
  - [Step 10: Clean up the Pods, keep the cluster](#step-10-clean-up-the-pods-keep-the-cluster)
- [Stretch goal](#stretch-goal)
- [Conclusion](#conclusion)

## Goals

- Create the three-node course cluster with kind and read its architecture from `kubectl`
- Get locally built images onto the cluster nodes without a registry
- Work in your own namespace and switch the kubectl context to it
- Run the Pinboard API as a Pod — first with `kubectl run`, then from a manifest
- Use the everyday toolkit: `get`, `describe`, `logs`, `port-forward`, `explain`, `events`
- Recognise `ImagePullBackOff` from the events, and run a native sidecar container

## Pre-requisites

- Have finished [Lab 04](lab04.md)
- `kind` v0.33, `kubectl` 1.37 and Docker running (from [Lab 00 – Course setup](lab00-setup.md))
- The course repo cloned at `~/docker-kubernetes-training`
- No Compose stack running (`docker compose ls` should be empty) — kind needs the RAM

> **Continuity.** Pinboard now runs from a single Compose file, on one machine. From this
> lab on, the same three images run on a cluster: Compose's `services` become Pods,
> `depends_on` becomes probes and controllers, and `docker compose up` becomes a
> reconciliation loop that keeps running long after you close the terminal. Nothing about
> the *images* changes — `pinboard-api:1.0`, `1.1`, `1.2-broken` and `pinboard-web:1.0`
> from Lab 02 are exactly what the cluster will run.

## Guide

### Step 01: Create the kind cluster

Work in `~/pinboard-labs/lab05/` for the files you create in this lab:

```bash
mkdir -p ~/pinboard-labs/lab05
cd ~/pinboard-labs/lab05
```

kind ("Kubernetes IN Docker") runs each node as a Docker container. The course cluster
config is in the repo — one control plane with host ports 80/443 published (Lab 07 needs
them for the Ingress) and two workers:

```bash
cat ~/docker-kubernetes-training/labs/kind-config.yaml
kind create cluster --config ~/docker-kubernetes-training/labs/kind-config.yaml
```

```text
Creating cluster "pinboard" ...
 ✓ Ensuring node image (kindest/node:v1.37.0) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-pinboard"
You can now use your cluster with:

kubectl cluster-info --context kind-pinboard

Have a nice day! 👋
```

The cluster name comes from the config file (`name: pinboard`), which is why no `--name`
flag is needed. Creating the cluster takes 1–2 minutes — longer the very first time, when
the ~1 GB `kindest/node` image is downloaded. Read Step 02 while you wait.

> **Note.** The nodes are Docker containers — look at them with `docker ps`. That is also
> why `kubectl` on your laptop can reach the API server: kind published it on a random
> host port and wrote the kubeconfig entry for you.

### Step 02: Look around the cluster

```bash
kubectl cluster-info
```

```text
Kubernetes control plane is running at https://127.0.0.1:38491
CoreDNS is running at https://127.0.0.1:38491/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy

To further debug and diagnose cluster problems, use 'kubectl cluster-info dump'.
```

```bash
kubectl get nodes -o wide
```

```text
NAME                     STATUS   ROLES           AGE     VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION      CONTAINER-RUNTIME
pinboard-control-plane   Ready    control-plane   2m14s   v1.37.0   172.18.0.4    <none>        Debian GNU/Linux 13 (trixie)     6.8.0-51-generic    containerd://2.3.4
pinboard-worker          Ready    <none>          1m58s   v1.37.0   172.18.0.2    <none>        Debian GNU/Linux 13 (trixie)     6.8.0-51-generic    containerd://2.3.4
pinboard-worker2         Ready    <none>          1m58s   v1.37.0   172.18.0.3    <none>        Debian GNU/Linux 13 (trixie)     6.8.0-51-generic    containerd://2.3.4
```

Two things to notice: the node IPs are Docker network addresses, and the container
runtime is **containerd**, not Docker. Kubernetes talks to a CRI runtime; Docker Engine
is only what builds your images and runs the node containers.

Now the part that surprises most people — the control plane itself is made of Pods:

```bash
kubectl get pods -A
```

```text
NAMESPACE            NAME                                             READY   STATUS    RESTARTS   AGE
kube-system          coredns-668d6bf9bc-4qk9v                         1/1     Running   0          2m11s
kube-system          coredns-668d6bf9bc-9wz2t                         1/1     Running   0          2m11s
kube-system          etcd-pinboard-control-plane                      1/1     Running   0          2m17s
kube-system          kindnet-6nc4m                                    1/1     Running   0          1m59s
kube-system          kindnet-8xq7d                                    1/1     Running   0          2m11s
kube-system          kindnet-x5j2p                                    1/1     Running   0          1m57s
kube-system          kube-apiserver-pinboard-control-plane            1/1     Running   0          2m17s
kube-system          kube-controller-manager-pinboard-control-plane   1/1     Running   0          2m17s
kube-system          kube-proxy-2fj6b                                 1/1     Running   0          1m59s
kube-system          kube-proxy-7dnhg                                 1/1     Running   0          2m11s
kube-system          kube-proxy-lm4wq                                 1/1     Running   0          1m57s
kube-system          kube-scheduler-pinboard-control-plane            1/1     Running   0          2m17s
local-path-storage   local-path-provisioner-7dc846544d-2xqzn          1/1     Running   0          2m11s
```

Read that list as an architecture diagram:

- `etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` — the control
  plane, all on the control-plane node, all static Pods managed by that node's kubelet.
- `kube-proxy` and `kindnet` — one per node (a DaemonSet, Session 06). `kube-proxy`
  programs Service routing; `kindnet` is kind's CNI plugin, giving every Pod an IP on a
  flat network.
- `coredns` — cluster DNS, the reason `pinboard-api` will be a resolvable name in Lab 07.
- `local-path-provisioner` — kind's default StorageClass, which will provide the
  database's volume in Lab 08.

The kubelet is the one component *not* in that list: it runs as a systemd service on the
node itself, since something has to start the Pods.

```bash
kubectl config get-contexts
```

```text
CURRENT   NAME            CLUSTER         AUTHINFO        NAMESPACE
*         kind-pinboard   kind-pinboard   kind-pinboard
```

A *context* is the triple (cluster, user, namespace) that `kubectl` uses when you do not
say otherwise. The `NAMESPACE` column is empty, which means `default`. You will fix that
in Step 04.

### Step 03: Load the Pinboard images into the cluster

Your images live in the Docker daemon's image store on your laptop. The cluster nodes are
*other* machines (containers) with their own containerd image stores, and there is no
registry in this course. `kind load` copies images straight into every node:

```bash
kind load docker-image pinboard-api:1.0 pinboard-api:1.1 pinboard-api:1.2-broken pinboard-web:1.0 --name pinboard
```

```text
Image: "pinboard-api:1.0" with ID "sha256:0f7a2b3c4d5e..." not yet present on node "pinboard-worker2", loading...
Image: "pinboard-api:1.0" with ID "sha256:0f7a2b3c4d5e..." not yet present on node "pinboard-worker", loading...
Image: "pinboard-api:1.0" with ID "sha256:0f7a2b3c4d5e..." not yet present on node "pinboard-control-plane", loading...
Image: "pinboard-api:1.1" with ID "sha256:5e6f7a8b9c0d..." not yet present on node "pinboard-worker", loading...
...
Image: "pinboard-web:1.0" with ID "sha256:2b3c4d5e6f70..." not yet present on node "pinboard-control-plane", loading...
```

Verify on one node:

```bash
docker exec pinboard-worker crictl images | grep pinboard
```

```text
docker.io/library/pinboard-api          1.0          0f7a2b3c4d5e6       12.8MB
docker.io/library/pinboard-api          1.1          5e6f7a8b9c0d1       12.8MB
docker.io/library/pinboard-api          1.2-broken   7a8b9c0d1e2f3       12.8MB
docker.io/library/pinboard-web          1.0          2b3c4d5e6f70a       58.4MB
```

> **Warning.** Because these images exist only on the nodes, every Pod that uses them
> **must** set `imagePullPolicy: IfNotPresent`. The default policy for a non-`latest` tag
> is already `IfNotPresent`, but write it explicitly — with tag `latest` the default is
> `Always`, and the Pod would fail trying to pull a non-existent image from Docker Hub.
>
> Rebuilt an image? `kind load` it again, and remember that Kubernetes will not notice a
> new image under the *same* tag on its own — you would have to delete the Pod.

### Step 04: A namespace of your own

Namespaces partition names (not networks — Pods in different namespaces can still talk).
Everything in this course lives in `pinboard`:

```bash
kubectl create namespace pinboard
kubectl config set-context --current --namespace=pinboard
kubectl config get-contexts
```

```text
namespace/pinboard created
Context "kind-pinboard" modified.
CURRENT   NAME            CLUSTER         AUTHINFO        NAMESPACE
*         kind-pinboard   kind-pinboard   kind-pinboard   pinboard
```

From now on every `kubectl` command without `-n` works in `pinboard`. To see what a
namespace holds:

```bash
kubectl get all
```

```text
No resources found in pinboard namespace.
```

> **Note.** `get all` is a lie by omission: it lists a curated set of workload kinds, not
> ConfigMaps, Secrets, Ingresses or anything from a CRD. Use it as a quick sanity check,
> never as an audit.

<details>
<summary><b>Check yourself:</b> the cluster is full of running Pods, so why does <code>kubectl get all</code> print nothing?</summary>

Because almost every object is **namespaced**, and you are looking at the empty `pinboard`
namespace. The control-plane Pods live in `kube-system`. Add `-n kube-system` or `-A` to
look elsewhere. A handful of kinds are *cluster-scoped* and belong to no namespace at all —
Nodes, Namespaces, PersistentVolumes, StorageClasses, ClusterRoles, IngressClasses;
`kubectl api-resources --namespaced=false` lists them.
</details>

### Step 05: Your first Pod, imperatively

`kubectl run` creates a single Pod — useful for a quick experiment, never for anything
that matters:

```bash
kubectl run pinboard-api --image=pinboard-api:1.0 --port=8080
kubectl get pods
```

```text
pod/pinboard-api created
NAME           READY   STATUS    RESTARTS   AGE
pinboard-api   1/1     Running   0          8s
```

If `STATUS` was `ContainerCreating` on your first try, you simply watched the kubelet
create the sandbox and start the container. Add `-w` to watch transitions live.

```bash
kubectl get pod pinboard-api -o wide
```

```text
NAME           READY   STATUS    RESTARTS   AGE   IP           NODE               NOMINATED NODE   READINESS GATES
pinboard-api   1/1     Running   0          31s   10.244.1.3   pinboard-worker    <none>           <none>
```

The Pod has its own IP on the cluster network, and the scheduler placed it on a worker.

```bash
kubectl describe pod pinboard-api | tail -20
```

```text
Events:
  Type    Reason     Age   From               Message
  ----    ------     ----  ----               -------
  Normal  Scheduled  45s   default-scheduler  Successfully assigned pinboard/pinboard-api to pinboard-worker
  Normal  Pulled     44s   kubelet            Container image "pinboard-api:1.0" already present on machine
  Normal  Created    44s   kubelet            Created container: pinboard-api
  Normal  Started    44s   kubelet            Started container pinboard-api
```

"already present on machine" is `kind load` paying off. Now the logs:

```bash
kubectl logs pinboard-api
```

```text
time=2026-05-04T10:02:18.442Z level=WARN msg="DATABASE_URL not set — using in-memory store, notes will be lost on restart"
time=2026-05-04T10:02:18.443Z level=INFO msg="pinboard-api starting" version=1.0 theme=emerald store=memory addr=:8080 hostname=pinboard-api
```

Two things worth keeping: the in-memory store is fine until Lab 08 (a database in
Kubernetes is a Session 08 topic), and `hostname` is the **Pod name** — which will make
load balancing trivial to observe later.

Reach the Pod from your laptop. The Pod IP is only routable inside the cluster, so tunnel
through the API server:

```bash
kubectl port-forward pod/pinboard-api 8080:8080
```

```text
Forwarding from 127.0.0.1:8080 -> 8080
Forwarding from [::1]:8080 -> 8080
```

In a **second terminal**:

```bash
curl -s localhost:8080/api/info
curl -s localhost:8080/healthz
```

```text
{"app":"pinboard-api","greeting":"Welcome to Pinboard","hostname":"pinboard-api","store":"memory","theme":"emerald","uptime":"1m12s","version":"1.0"}
ok
```

Stop the forward with `Ctrl-C`. Now try to get a shell inside, the way you would with
`docker exec`:

```bash
kubectl exec -it pinboard-api -- sh
```

```text
error: Internal error occurred: error executing command in container: failed to exec in container:
failed to start exec "b0f4...": OCI runtime exec failed: exec failed: unable to start container process:
exec: "sh": executable file not found in $PATH: unknown
```

This is **not** a Kubernetes problem: the image is distroless. It contains the Go binary,
CA certificates and nothing else — no `sh`, no `ls`, no package manager. That is a
security win (nothing for an attacker to use) and a debugging cost.

> **Note.** The modern answer is `kubectl debug`, which attaches an *ephemeral container*
> with a full toolbox to a running Pod, sharing its namespaces. You will use it properly
> in Lab 09; there is a taster in this lab's [stretch goal](#stretch-goal).

Delete the Pod — the imperative part is over:

```bash
kubectl delete pod pinboard-api
```

```text
pod "pinboard-api" deleted
```

Nothing recreates it. A Pod is a mortal object; keeping N of them alive is a
*controller's* job (Lab 06).

### Step 06: The same Pod, declaratively

Create `pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pinboard-api
  namespace: pinboard
  labels:
    app.kubernetes.io/name: pinboard-api
    app.kubernetes.io/component: api
    app.kubernetes.io/part-of: pinboard
spec:
  containers:
    - name: api
      image: pinboard-api:1.0
      imagePullPolicy: IfNotPresent
      ports:
        - name: http
          containerPort: 8080
      env:
        - name: APP_THEME
          value: emerald
        - name: APP_GREETING
          value: "Welcome to Pinboard on Kubernetes"
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
        limits:
          memory: 64Mi
```

Every Kubernetes object has the same four top-level fields: `apiVersion`, `kind`,
`metadata`, `spec` (plus a `status` the cluster writes). The rest is detail:

- The `app.kubernetes.io/*` **labels** are the community-standard set. They are not
  decoration — from Lab 06 on, controllers and Services find Pods *by label*.
- `ports.name: http` names the port so that probes and Services can refer to `http`
  instead of `8080`.
- `resources.requests` is what the **scheduler** reserves; `limits` is what the **kubelet
  enforces at runtime**. A container over its memory limit is OOM-killed; a container over
  its CPU limit is only throttled. We set a memory limit but no CPU limit deliberately —
  CPU limits on a latency-sensitive API cause more incidents than they prevent.

Ask the API server what those fields mean, without leaving the terminal:

```bash
kubectl explain pod.spec.containers.resources
```

```text
KIND:       Pod
VERSION:    v1

FIELD: resources <ResourceRequirements>

DESCRIPTION:
    Compute Resources required by this container. Cannot be updated.
    ResourceRequirements describes the compute resource requirements.

FIELDS:
  claims        <[]ResourceClaim>
  limits        <map[string]Quantity>
    Limits describes the maximum amount of compute resources allowed. More info:
    https://kubernetes.io/docs/concepts/configuration/manage-compute-resources-container/
  requests      <map[string]Quantity>
    Requests describes the minimum amount of compute resources required. ...
```

`kubectl explain` reads the OpenAPI schema of *your* cluster, so it is always right for
the version you are running. `kubectl explain pod.spec --recursive` prints the whole tree.

Apply the manifest:

```bash
kubectl apply -f pod.yaml
kubectl get pod pinboard-api -L app.kubernetes.io/name,app.kubernetes.io/component
```

```text
pod/pinboard-api created
NAME           READY   STATUS    RESTARTS   AGE   NAME           COMPONENT
pinboard-api   1/1     Running   0          6s    pinboard-api   api
```

`apply` is *declarative*: run it again and nothing happens ("unchanged"), because the
cluster already matches the file. That idempotence is what makes the file the source of
truth, and what lets you keep it in git.

### Step 07: Read the object, read the events

`spec` is what you asked for; `status` is what the cluster made of it:

```bash
kubectl get pod pinboard-api -o yaml | sed -n '/^status:/,$p' | head -30
```

```text
status:
  conditions:
  - lastTransitionTime: "2026-05-04T10:09:31Z"
    status: "True"
    type: PodReadyToStartContainers
  - lastTransitionTime: "2026-05-04T10:09:30Z"
    status: "True"
    type: Initialized
  - lastTransitionTime: "2026-05-04T10:09:33Z"
    status: "True"
    type: Ready
  - lastTransitionTime: "2026-05-04T10:09:33Z"
    status: "True"
    type: ContainersReady
  - lastTransitionTime: "2026-05-04T10:09:30Z"
    status: "True"
    type: PodScheduled
  containerStatuses:
  - containerID: containerd://7c4a1e9b03d5b8f6a2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9
    image: docker.io/library/pinboard-api:1.0
    name: api
    ready: true
    restartCount: 0
    started: true
    state:
      running:
        startedAt: "2026-05-04T10:09:32Z"
  hostIP: 172.18.0.2
  phase: Running
  podIP: 10.244.1.4
```

The `conditions` list is the machine-readable version of the `READY` column, and it is
where you look when a Pod is "running but not working".

Events are the cluster's narration. Leave this running in a **second terminal** for the
rest of the lab:

```bash
kubectl get events --watch
```

```text
LAST SEEN   TYPE     REASON      OBJECT             MESSAGE
0s          Normal   Scheduled   pod/pinboard-api   Successfully assigned pinboard/pinboard-api to pinboard-worker
0s          Normal   Pulled      pod/pinboard-api   Container image "pinboard-api:1.0" already present on machine
0s          Normal   Created     pod/pinboard-api   Created container: api
0s          Normal   Started     pod/pinboard-api   Started container api
```

> **Note.** Events expire (one hour by default), so an empty list means "nothing happened
> recently", not "nothing ever happened". For post-mortems use
> `kubectl get events --sort-by=.lastTimestamp`.

### Step 08: Break it — a Pod that cannot pull

Every troubleshooting skill you will need in Lab 09 starts here. Create `pod-broken.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pinboard-api-broken
  namespace: pinboard
  labels:
    app.kubernetes.io/name: pinboard-api-broken
    app.kubernetes.io/component: api
    app.kubernetes.io/part-of: pinboard
spec:
  containers:
    - name: api
      image: pinboard-api:9.9
      imagePullPolicy: IfNotPresent
      ports:
        - name: http
          containerPort: 8080
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
        limits:
          memory: 64Mi
```

```bash
kubectl apply -f pod-broken.yaml
kubectl get pods -w
```

```text
NAME                  READY   STATUS         RESTARTS   AGE
pinboard-api          1/1     Running        0          4m
pinboard-api-broken   0/1     Pending        0          0s
pinboard-api-broken   0/1     ContainerCreating 0        1s
pinboard-api-broken   0/1     ErrImagePull   0          3s
pinboard-api-broken   0/1     ImagePullBackOff 0        16s
```

`Ctrl-C`, then ask *why*:

```bash
kubectl describe pod pinboard-api-broken | tail -12
```

```text
Events:
  Type     Reason     Age                From               Message
  ----     ------     ----               ----               -------
  Normal   Scheduled  38s                default-scheduler  Successfully assigned pinboard/pinboard-api-broken to pinboard-worker2
  Normal   Pulling    37s                kubelet            Pulling image "pinboard-api:9.9"
  Warning  Failed     35s                kubelet            Failed to pull image "pinboard-api:9.9": failed to pull and unpack image "docker.io/library/pinboard-api:9.9": failed to resolve reference "docker.io/library/pinboard-api:9.9": pull access denied, repository does not exist or may require authorization
  Warning  Failed     35s                kubelet            Error: ErrImagePull
  Normal   BackOff    9s (x3 over 34s)   kubelet            Back-off pulling image "pinboard-api:9.9"
  Warning  Failed     9s                 kubelet            Error: ImagePullBackOff
```

Read it carefully: the tag is not on the node, so despite `IfNotPresent` the kubelet
*must* try a registry — and Docker Hub has no `library/pinboard-api`. `BackOff` means the
kubelet is retrying with an exponentially growing delay (10 s, 20 s, 40 s … capped at
5 min), which is also why a fix can take a minute to take effect.

Fix it imperatively:

```bash
kubectl set image pod/pinboard-api-broken api=pinboard-api:1.0
kubectl get pod pinboard-api-broken
```

```text
pod/pinboard-api-broken image updated
NAME                  READY   STATUS    RESTARTS   AGE
pinboard-api-broken   1/1     Running   0          92s
```

> **Note.** The image is one of the very few Pod fields that can be changed in place.
> Try `kubectl set env pod/pinboard-api-broken APP_THEME=rose` and you get
> `Pod "pinboard-api-broken" is invalid: spec: Forbidden: pod updates may not change
> fields other than …`. Pods are almost immutable; to change one, you replace it. That
> restriction is exactly why you want a Deployment, which does the replacing for you.

The durable fix is in the file: edit `pod-broken.yaml` to use `pinboard-api:1.0` and
re-`apply` it, so that the manifest and the cluster agree again.

<details>
<summary><b>Check yourself:</b> the Pod status is <code>Pending</code> and there are no <code>Pulling</code> events at all. What is different?</summary>

`Pending` with no image events means the Pod has not been **scheduled** yet — no node was
chosen, so no kubelet has touched it. `kubectl describe` will show a `FailedScheduling`
event from `default-scheduler` explaining why: insufficient CPU/memory across all nodes,
a taint the Pod does not tolerate, a node selector matching nothing, or an unbound PVC.
`ImagePullBackOff` on the other hand means scheduling succeeded and the *node* failed.
Scheduling problems are cluster-level; image problems are node-level.
</details>

### Step 09: A multi-container Pod with a sidecar

> **Short on time?** This step is optional — nothing in later labs depends on it. Jump to
> [Step 10](#step-10-clean-up-the-pods-keep-the-cluster) and come back to it after class.

A Pod can hold several containers that share one network namespace (they reach each other
on `localhost`) and any volumes you define. Create `pod-sidecar.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pinboard-api-sidecar
  namespace: pinboard
  labels:
    app.kubernetes.io/name: pinboard-api-sidecar
    app.kubernetes.io/component: api
    app.kubernetes.io/part-of: pinboard
spec:
  initContainers:
    - name: heartbeat
      image: busybox:1.37
      restartPolicy: Always
      command:
        - sh
        - -c
        - 'while true; do echo "$(date +%T) heartbeat from $(hostname)" >> /shared/pinboard.log; sleep 5; done'
      volumeMounts:
        - name: shared
          mountPath: /shared
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 32Mi
    - name: logtail
      image: busybox:1.37
      restartPolicy: Always
      command: ["sh", "-c", "touch /shared/pinboard.log; tail -n +1 -F /shared/pinboard.log"]
      volumeMounts:
        - name: shared
          mountPath: /shared
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 32Mi
  containers:
    - name: api
      image: pinboard-api:1.0
      imagePullPolicy: IfNotPresent
      ports:
        - name: http
          containerPort: 8080
      env:
        - name: APP_THEME
          value: sky
      volumeMounts:
        - name: shared
          mountPath: /shared
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
        limits:
          memory: 64Mi
  volumes:
    - name: shared
      emptyDir: {}
```

The surprising part is that the sidecars are declared under `initContainers`. An init
container with `restartPolicy: Always` is a **native sidecar** (on by default since
Kubernetes 1.29, GA in 1.33): it starts *before* the main containers, keeps running alongside them, is restarted
if it dies, and is terminated *after* them. Before this existed, sidecars were ordinary
containers — which broke Jobs (the Pod never completed) and shut down in an unpredictable
order.

```bash
kubectl apply -f pod-sidecar.yaml
kubectl get pod pinboard-api-sidecar
```

```text
pod/pinboard-api-sidecar created
NAME                   READY   STATUS    RESTARTS   AGE
pinboard-api-sidecar   3/3     Running   0          18s
```

`3/3` — one Pod, three running containers. Logs are per container:

```bash
kubectl logs pinboard-api-sidecar -c logtail --tail=3
```

```text
10:21:44 heartbeat from pinboard-api-sidecar
10:21:49 heartbeat from pinboard-api-sidecar
10:21:54 heartbeat from pinboard-api-sidecar
```

`logtail` prints lines that `heartbeat` wrote: two containers, one `emptyDir` volume,
same files. Note `hostname` is the *Pod* name in both containers — the network namespace
is shared too, which is why the API is reachable on `localhost:8080` from either sidecar:

```bash
kubectl exec pinboard-api-sidecar -c logtail -- wget -qO- http://localhost:8080/api/info
```

```text
{"app":"pinboard-api","greeting":"Welcome to Pinboard","hostname":"pinboard-api-sidecar","store":"memory","theme":"sky","uptime":"55s","version":"1.0"}
```

That is the sidecar pattern in one command: the busybox container has a shell and
networking tools, the distroless API container has neither, and they share a network
namespace. Log shippers, proxies and metric exporters all work exactly this way.

> **Note.** `emptyDir` lives and dies with the Pod, on the node's disk. It is for sharing
> between containers and for scratch space — never for data you want to keep. Real
> persistence arrives in Lab 08 with PersistentVolumeClaims.

### Step 10: Clean up the Pods, keep the cluster

Delete the Pods, but **keep the cluster, the namespace and the loaded images** — Lab 06
starts from exactly this state:

```bash
kubectl delete -f pod.yaml -f pod-broken.yaml -f pod-sidecar.yaml
kubectl get pods
```

```text
pod "pinboard-api" deleted
pod "pinboard-api-broken" deleted
pod "pinboard-api-sidecar" deleted
No resources found in pinboard namespace.
```

(Skipped Step 09? Leave `-f pod-sidecar.yaml` out — `kubectl` refuses a file that does not exist.)

Confirm the cluster is still there and still your default context:

```bash
kubectl get nodes
kubectl config get-contexts
```

> **Warning.** Do **not** run `kind delete cluster`. Recreating the cluster costs two
> minutes plus another `kind load` of four images, and Labs 06–09 all build on this one.
> If you must stop for the day, `docker stop` the three kind containers (or just shut
> down); `docker start` brings the cluster back.

## Stretch goal

1. **Debug a distroless container.** Recreate the Pod (`kubectl apply -f pod.yaml`) and
   attach an ephemeral container that shares its process namespace:

   ```bash
   kubectl debug -it pinboard-api --image=busybox:1.37 --target=api -- sh
   ```

   Inside, run `wget -qO- localhost:8080/healthz` and `ps aux` — you can see and reach the
   API process even though its own image has no shell. `kubectl get pod pinboard-api -o
   jsonpath='{.spec.ephemeralContainers[*].name}'` shows what was attached; ephemeral
   containers can never be removed, only the Pod can.
2. **Read the schema instead of the docs.** Use `kubectl explain pod.spec.volumes.emptyDir`
   and `kubectl explain pod.spec --recursive | wc -l` to appreciate how much of the API you
   have *not* used yet.
3. **Make the scheduler refuse.** Copy `pod.yaml` to `pod-toobig.yaml`, set
   `requests.memory: 100Gi`, apply it, and read the `FailedScheduling` event. Then delete
   it. That is the `Pending` case from the Check-yourself box, seen for real.

## Conclusion

**What you have now**

- A three-node kind cluster called `pinboard` (control plane + 2 workers), with ports
  80/443 mapped to your laptop for Lab 07.
- All four Pinboard images loaded onto every node — no registry involved.
- A `pinboard` namespace that is the default for your kubectl context.
- `pod.yaml`, `pod-broken.yaml` and `pod-sidecar.yaml` in `~/pinboard-labs/lab05/`,
  and the reflexes for `get` → `describe` →
  `logs` → `events`.

**Kept for the next lab:** the cluster, the namespace and the loaded images. **Deleted:**
all the Pods — because you now know why nobody runs bare Pods in production. When a node
dies, or you delete a Pod, or a container exits for good, *nothing* brings it back.

Next: [Lab 06 – Make Pinboard API resilient](lab06.md), where a Deployment takes that job
over and gives you rolling updates and rollbacks for free.
