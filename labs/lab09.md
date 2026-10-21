# Lab 09 – Operate Pinboard

## Table of Contents

- [Goals](#goals)
- [Pre-requisites](#pre-requisites)
- [Guide](#guide)
  - [Step 01: Prepare the lab folder](#step-01-prepare-the-lab-folder)
  - [Step 02: Install metrics-server and use `kubectl top`](#step-02-install-metrics-server-and-use-kubectl-top)
  - [Step 03: Add a HorizontalPodAutoscaler](#step-03-add-a-horizontalpodautoscaler)
  - [Step 04: Generate load and watch it scale](#step-04-generate-load-and-watch-it-scale)
  - [Step 05: Drill A — CrashLoopBackOff](#step-05-drill-a--crashloopbackoff)
  - [Step 06: Drill B — OOMKilled](#step-06-drill-b--oomkilled)
  - [Step 07: Drill C — debugging a distroless container and a node](#step-07-drill-c--debugging-a-distroless-container-and-a-node)
  - [Step 08: A PodDisruptionBudget and a node drain](#step-08-a-poddisruptionbudget-and-a-node-drain)
  - [Step 09: Lock the namespace down with Pod Security Admission](#step-09-lock-the-namespace-down-with-pod-security-admission)
- [Stretch goal](#stretch-goal)
- [Conclusion](#conclusion)

## Goals

- Install metrics-server on kind and read resource usage with `kubectl top`
- Autoscale `pinboard-api` with a HorizontalPodAutoscaler under real CPU load
- Practise the troubleshooting method **get → describe → logs → events → exec/debug**
  on three broken states you create on purpose
- Debug a distroless container with `kubectl debug` ephemeral containers
- Protect the API with a PodDisruptionBudget during a node drain, and enforce the
  `restricted` Pod Security Standard on the namespace

## Pre-requisites

- Have finished [Lab 08](lab08.md)
- The kind cluster `pinboard` running, `pinboard` as your current namespace
- `curl` and `docker` available on the host

> **Continuity.** After Lab 08, Pinboard is complete and stateful: ConfigMap and
> Secret, a `pinboard-db` StatefulSet with a 1 Gi PVC, three `pinboard-api`
> replicas reading `DATABASE_URL` from the Secret, `pinboard-web`, and an Ingress on
> <http://localhost>. Everything you need is declared in `~/pinboard-labs/lab08/`.
> This lab does not add features — it makes the same application **operable**:
> measured, autoscaled, debuggable, disruption-aware and security-constrained.

## Guide

### Step 01: Prepare the lab folder

```bash
mkdir -p ~/pinboard-labs/lab09
cd ~/pinboard-labs/lab09
cp ~/pinboard-labs/lab08/*.yaml .
rm -f configmap-volume-pod.yaml
kubectl config set-context --current --namespace=pinboard
kubectl get deploy,sts
```

```text
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/pinboard-api   3/3     3            3           2h11m
deployment.apps/pinboard-web   2/2     2            2           1h52m

NAME                           READY   AGE
statefulset.apps/pinboard-db   1/1     38m
```

### Step 02: Install metrics-server and use `kubectl top`

`kubectl top` does not talk to the kubelet directly — it reads the
`metrics.k8s.io` API, which nothing serves until you install **metrics-server**.
That is why a fresh cluster answers `error: Metrics API not available`. Install it:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

```text
serviceaccount/metrics-server created
clusterrole.rbac.authorization.k8s.io/system:aggregated-metrics-reader created
clusterrole.rbac.authorization.k8s.io/system:metrics-server created
rolebinding.rbac.authorization.k8s.io/metrics-server-auth-reader created
clusterrolebinding.rbac.authorization.k8s.io/metrics-server:system:auth-delegator created
clusterrolebinding.rbac.authorization.k8s.io/system:metrics-server created
service/metrics-server created
deployment.apps/metrics-server created
apiservice.apiregistration.k8s.io/v1beta1.metrics.k8s.io created
```

On kind it will not become ready: the kubelets serve their metrics endpoint with a
self-signed certificate that metrics-server refuses. Tell it to skip that check —
acceptable on a throwaway cluster, **never** in production, where you fix the
kubelet certificates instead:

```bash
kubectl patch -n kube-system deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deployment/metrics-server
```

```text
deployment.apps/metrics-server patched
Waiting for deployment "metrics-server" rollout to finish: 1 old replicas are pending termination...
deployment "metrics-server" successfully rolled out
```

Metrics are scraped every 15 seconds and the first window needs to fill, so give it
half a minute:

```bash
sleep 45
kubectl top nodes
```

```text
NAME                     CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
pinboard-control-plane   214m         5%       1284Mi          16%
pinboard-worker          63m          1%       612Mi           7%
pinboard-worker2         41m          1%       498Mi           6%
```

```bash
kubectl top pods
```

```text
NAME                            CPU(cores)   MEMORY(bytes)
pinboard-api-58c7d9f4b6-hn9lm   1m           9Mi
pinboard-api-58c7d9f4b6-lq2vp   1m           9Mi
pinboard-api-58c7d9f4b6-t7rzc   1m           8Mi
pinboard-db-0                   6m           38Mi
pinboard-web-7d9b5c6f8b-4nkzq   1m           4Mi
pinboard-web-7d9b5c6f8b-x8slt   1m           4Mi
```

> **Note.** `kubectl top` shows *live usage*; `kubectl describe node` shows
> *requests and limits*. They answer different questions: usage tells you whether
> the app is busy, requests tell you why the scheduler did or did not place a Pod.
> metrics-server keeps only a short in-memory window — it feeds the HPA and `top`,
> it is **not** a monitoring system. For history you want Prometheus, and for
> dashboards Grafana.

### Step 03: Add a HorizontalPodAutoscaler

Now that CPU numbers exist, the HPA can act on them. Append this to your
`20-api-deployment.yaml` (after the Service — one file may hold several objects
separated by `---`):

```yaml
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: pinboard-api
  namespace: pinboard
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: pinboard-api
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 60
```

Read it as the controller does: `averageUtilization: 50` means "keep average CPU
usage at 50 % **of the CPU request**". Your API requests `50m`, so the target is
`25m` per Pod, and the controller computes

```text
desiredReplicas = ceil( currentReplicas × currentUtilization / targetUtilization )
```

every 15 seconds, clamped to `minReplicas`/`maxReplicas`.

> **Warning.** An HPA on CPU **requires** `resources.requests.cpu` on the container.
> Without a request there is no denominator, the HPA reports
> `<unknown>/50%` and never scales. This is the most common HPA bug in the wild.

```bash
kubectl apply -f 20-api-deployment.yaml
kubectl get hpa
```

```text
deployment.apps/pinboard-api configured
service/pinboard-api unchanged
horizontalpodautoscaler.autoscaling/pinboard-api created

NAME           REFERENCE                 TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
pinboard-api   Deployment/pinboard-api   cpu: 2%/50%   2         6         3          18s
```

> **Note.** From now on the HPA owns `spec.replicas` of that Deployment. Leaving
> `replicas: 3` in the manifest is tolerable (a later `kubectl apply` resets the count
> to 3 and the HPA corrects it again within a minute — remove the field once an HPA owns
> the Deployment), but never `kubectl scale` a Deployment that has an HPA — the
> controller will just undo you within 15 seconds.

### Step 04: Generate load and watch it scale

The API has an endpoint built for this: `GET /api/burn?ms=300` keeps a CPU busy for
300 ms. Create `90-load-generator.yaml`:

```yaml
# Throwaway load generator — deleted at the end of this step.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pinboard-load
  namespace: pinboard
  labels:
    app.kubernetes.io/name: pinboard-load
    app.kubernetes.io/part-of: pinboard
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: pinboard-load
  template:
    metadata:
      labels:
        app.kubernetes.io/name: pinboard-load
        app.kubernetes.io/part-of: pinboard
    spec:
      containers:
        - name: load
          image: busybox:1.37
          command:
            - sh
            - -c
            - "while true; do wget -qO- http://pinboard-api:8080/api/burn?ms=300 >/dev/null; done"
          resources:
            requests:
              cpu: 20m
              memory: 16Mi
            limits:
              memory: 32Mi
```

Start it and watch the HPA in a loop:

```bash
kubectl apply -f 90-load-generator.yaml
kubectl get hpa --watch
```

```text
NAME           REFERENCE                 TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
pinboard-api   Deployment/pinboard-api   cpu: 2%/50%     2         6         3          3m
pinboard-api   Deployment/pinboard-api   cpu: 318%/50%   2         6         3          3m15s
pinboard-api   Deployment/pinboard-api   cpu: 318%/50%   2         6         6          3m30s
pinboard-api   Deployment/pinboard-api   cpu: 189%/50%   2         6         6          4m15s
pinboard-api   Deployment/pinboard-api   cpu: 154%/50%   2         6         6          5m0s
```

Three replicas at 318 % against a 50 % target → `ceil(3 × 318 / 50) = ceil(19.08) = 20`,
clamped to `maxReplicas: 6`.
Leave the watch running for a minute or two, then `Ctrl-C` and confirm:

```bash
kubectl get pods -l app.kubernetes.io/name=pinboard-api
kubectl top pods -l app.kubernetes.io/name=pinboard-api
```

```text
NAME                            READY   STATUS    RESTARTS   AGE
pinboard-api-58c7d9f4b6-4wq9x   1/1     Running   0          92s
pinboard-api-58c7d9f4b6-hn9lm   1/1     Running   0          21m
pinboard-api-58c7d9f4b6-lq2vp   1/1     Running   0          21m
pinboard-api-58c7d9f4b6-t7rzc   1/1     Running   0          21m
pinboard-api-58c7d9f4b6-vc6dm   1/1     Running   0          92s
pinboard-api-58c7d9f4b6-zt8kb   1/1     Running   0          92s

NAME                            CPU(cores)   MEMORY(bytes)
pinboard-api-58c7d9f4b6-4wq9x   79m          11Mi
pinboard-api-58c7d9f4b6-hn9lm   77m          12Mi
pinboard-api-58c7d9f4b6-zt8kb   74m          11Mi
...
```

`kubectl describe hpa pinboard-api` shows the decisions in plain English:

```text
Events:
  Type    Reason             Age    From                       Message
  ----    ------             ----   ----                       -------
  Normal  SuccessfulRescale  2m11s  horizontal-pod-autoscaler  New size: 6; reason: cpu resource utilization (percentage of request) above target
```

Now remove the load and watch the other direction:

```bash
kubectl delete -f 90-load-generator.yaml
kubectl get hpa --watch
```

```text
deployment.apps "pinboard-load" deleted
NAME           REFERENCE                 TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
pinboard-api   Deployment/pinboard-api   cpu: 154%/50%   2         6         6          7m30s
pinboard-api   Deployment/pinboard-api   cpu: 6%/50%     2         6         6          7m45s
pinboard-api   Deployment/pinboard-api   cpu: 2%/50%     2         6         6          8m0s
pinboard-api   Deployment/pinboard-api   cpu: 2%/50%     2         6         2          8m45s
```

Scaling down took about a minute longer than the metric dropped: that is the
`stabilizationWindowSeconds: 60` you configured. The controller takes the **highest**
recommendation from the window, so a brief dip cannot shrink your service just
before the next traffic spike. Scale-up has no such window by default — being late
to add capacity is worse than being late to remove it.

`Ctrl-C` out of the watch. Note the Deployment now sits at **2** replicas
(`minReplicas`), not 3.

<details>
<summary><strong>Check yourself:</strong> the load generator ran two Pods, yet the API scaled to six. Would ten load Pods have scaled it to sixty?</summary>

No — `maxReplicas: 6` is a hard ceiling, and it exists precisely so that a runaway
client (or a metrics glitch) cannot consume the whole cluster. More load would simply
make each API Pod slower and the target utilisation permanently exceeded. Capacity
planning does not disappear with autoscaling; the HPA only automates the range you
decided is safe.
</details>

### Step 05: Drill A — CrashLoopBackOff

The rest of this lab is deliberate breakage. Use the same method every time:

```text
kubectl get      → what state is it in?
kubectl describe → what does the kubelet/scheduler say? (Events, Last State)
kubectl logs     → what did the application say? (--previous for a dead container)
kubectl get events --sort-by=.lastTimestamp → what happened around it, cluster-wide?
kubectl exec / kubectl debug → go inside and look
```

Break it — the API exits immediately when `CRASH_ON_START=true`:

```bash
kubectl set env deployment/pinboard-api CRASH_ON_START=true
sleep 45
kubectl get pods -l app.kubernetes.io/name=pinboard-api
```

```text
deployment.apps/pinboard-api env updated

NAME                            READY   STATUS             RESTARTS      AGE
pinboard-api-58c7d9f4b6-hn9lm   1/1     Running            0             24m
pinboard-api-58c7d9f4b6-lq2vp   1/1     Running            0             24m
pinboard-api-6b7c4d8f9c-9vk2r   0/1     CrashLoopBackOff   3 (18s ago)   52s
```

**get** tells you the state and that it has restarted three times. Keep the name of the
broken Pod — it is the newest one — so the next commands look at it and not at the
healthy ones:

```bash
BAD=$(kubectl get pods -l app.kubernetes.io/name=pinboard-api \
  --sort-by=.metadata.creationTimestamp -o name | tail -1)
echo "$BAD"
```

**describe** tells you why the kubelet is waiting:

```bash
kubectl describe "$BAD" | sed -n '/^Containers:/,/^Conditions:/p'
```

```text
Containers:
  api:
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
      Started:      Thu, 20 Aug 2026 10:12:41 +0000
      Finished:     Thu, 20 Aug 2026 10:12:41 +0000
    Ready:          False
    Restart Count:  3
```

`CrashLoopBackOff` is not an error, it is the kubelet's **back-off timer** between
restarts (10s, 20s, 40s … up to 5 min). The real error is in `Last State`. The
container is dead right now, so ask for the *previous* container's logs:

```bash
kubectl logs "$BAD" --previous --tail=3
```

```text
{"time":"2026-08-20T10:12:41.508Z","level":"ERROR","msg":"CRASH_ON_START is set — exiting with status 1 (this is on purpose)"}
```

> **Note.** `--previous` always means "the last container that died". Without it you
> get the *current* instance: while the Pod sits in back-off kubectl falls back to the
> dead one, but the moment the kubelet restarts it you are reading a fresh container
> that has not crashed yet — and its logs may well look healthy. Also, `--previous`
> with `-l` would fail on the healthy Pods (they have no previous container), which is
> why we picked the broken Pod by name.

Also note that the rollout protected you: `maxUnavailable: 0` plus a readiness probe
means the two healthy old Pods are still serving. Check:

```bash
kubectl rollout status deployment/pinboard-api --timeout=10s
curl -s http://localhost/api/info | head -c 60; echo
```

```text
Waiting for deployment "pinboard-api" rollout to finish: 1 out of 2 new replicas have been updated...
error: timed out waiting for the condition
{"app":"pinboard-api","greeting":"Welcome to Pinboard on Kub
```

Fix it. The trailing `-` in `kubectl set env` **removes** a variable:

```bash
kubectl set env deployment/pinboard-api CRASH_ON_START-
kubectl rollout status deployment/pinboard-api
```

```text
deployment.apps/pinboard-api env updated
deployment "pinboard-api" successfully rolled out
```

### Step 06: Drill B — OOMKilled

Memory limits are enforced by the kernel's cgroup OOM killer, not by Kubernetes.
Squeeze the API into 16 Mi. The request has to come down too — Kubernetes rejects a
container whose memory request (32 Mi in your manifest) is larger than its limit:

```bash
kubectl set resources deployment/pinboard-api --requests=memory=16Mi --limits=memory=16Mi
sleep 30
kubectl get pods -l app.kubernetes.io/name=pinboard-api
```

```text
deployment.apps/pinboard-api resource requirements updated

NAME                            READY   STATUS             RESTARTS      AGE
pinboard-api-58c7d9f4b6-hn9lm   1/1     Running            0             31m
pinboard-api-58c7d9f4b6-lq2vp   1/1     Running            0             31m
pinboard-api-7f8d6c5b49-mn4xt   0/1     CrashLoopBackOff   2 (12s ago)   34s
```

> **Note.** The Go runtime's footprint varies a little between machines. If the new Pod
> is still `Running` after a minute, squeeze harder:
> `kubectl set resources deployment/pinboard-api --requests=memory=8Mi --limits=memory=8Mi`.

Same symptom as Drill A — **different cause**, and only `describe` distinguishes
them:

```bash
BAD=$(kubectl get pods -l app.kubernetes.io/name=pinboard-api \
  --sort-by=.metadata.creationTimestamp -o name | tail -1)
kubectl describe "$BAD" | sed -n '/Last State/,/Restart Count/p'
```

```text
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Thu, 20 Aug 2026 10:19:02 +0000
      Finished:     Thu, 20 Aug 2026 10:19:03 +0000
    Restart Count:  2
```

`Reason: OOMKilled`, exit code `137` = 128 + 9 (SIGKILL). The application logs are
useless here — the process was shot, it never got a chance to complain. That is the
signature: **empty/normal logs + exit 137 = the memory limit is too low** (or you
have a leak).

```bash
kubectl logs "$BAD" --previous --tail=3
```

```text
{"time":"2026-08-20T10:19:02.771Z","level":"INFO","msg":"pinboard-api starting","version":"1.1","theme":"emerald","store":"postgres","addr":":8080","hostname":"pinboard-api-7f8d6c5b49-mn4xt"}
```

Put the limit back where the manifest says it should be:

```bash
kubectl apply -f 20-api-deployment.yaml
kubectl rollout status deployment/pinboard-api
```

```text
deployment.apps/pinboard-api configured
deployment "pinboard-api" successfully rolled out
```

> **Note.** Re-applying the manifest undoes both drills at once, because the file is
> the source of truth and `kubectl set env` / `set resources` only patched the live
> object. Getting used to "fix the file, apply the file" is the whole point of
> declarative configuration — imperative patches are for experiments, not for
> repairs you want to keep.

> **Warning.** CPU and memory limits are not symmetric. Exceeding a **CPU** limit
> throttles the process (slow, alive); exceeding a **memory** limit kills it
> instantly. That is why the Pinboard manifests set memory limits but leave CPU
> limits off: a CPU limit on a bursty API mostly buys you latency.

### Step 07: Drill C — debugging a distroless container and a node

The API image is `gcr.io/distroless/static-debian12:nonroot`: no shell, no `ps`, no
`wget`. `kubectl exec` is useless:

```bash
API_POD=$(kubectl get pod -l app.kubernetes.io/name=pinboard-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it "$API_POD" -- sh
```

```text
OCI runtime exec failed: exec failed: unable to start container process: exec: "sh": executable file not found in $PATH: unknown
```

This is a feature — an attacker who lands in that container has no tools either. To
debug it, attach an **ephemeral container**: a second container injected into the
running Pod, sharing its network namespace and (with `--target`) its process
namespace:

```bash
kubectl debug -it "$API_POD" --image=busybox:1.37 --target=api -- sh
```

```text
Targeting container "api". If you don't see processes from this container it may be because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-8vq7z.
If you don't see a command prompt, try pressing enter.
/ #
```

Inside, you can see the API process and talk to it over `localhost`:

```bash
ps -o pid,args
wget -qO- localhost:8080/readyz
wget -qO- localhost:8080/api/info
nslookup pinboard-db
exit
```

```text
PID   COMMAND
    1 /pinboard-api
   14 sh
   22 ps -o pid,args

ready
{"app":"pinboard-api","greeting":"Welcome to Pinboard on Kubernetes","hostname":"pinboard-api-58c7d9f4b6-hn9lm","store":"postgres","theme":"emerald","uptime":"6m11s","version":"1.1"}

Server:    10.96.0.10
Address:   10.96.0.10:53
Name:      pinboard-db.pinboard.svc.cluster.local
Address:   10.244.1.12
```

Being able to curl `localhost:8080/readyz` from inside the Pod is the fastest way to
separate "the app is broken" from "the Service/Ingress does not reach the app".

> **Note.** The ephemeral container is added to the Pod permanently (you can see it
> in `kubectl get pod -o yaml` under `ephemeralContainers`) and cannot be removed —
> deleting the Pod is the cleanup. It does not restart the Pod and it does not
> count against the Deployment's containers.

**Optional if you are short on time** (Step 08 matters more): the same command can
open a shell on a **node**, which on kind is a Docker container:

```bash
kubectl debug node/pinboard-worker -it --image=busybox:1.37
```

```text
Creating debugging pod node-debugger-pinboard-worker-x4k9d with container debugger on node pinboard-worker.
If you don't see a command prompt, try pressing enter.
/ #
```

That Pod runs with the host's PID and network namespaces and mounts the node's root
filesystem at `/host`:

```bash
chroot /host df -h /var/lib/containerd | tail -1
ls /host/var/local-path-provisioner
exit
```

```text
overlay         59G   14G   43G  25% /var/lib/containerd
pvc-6f0c1b9e-25a4-4c7c-9a0f-1c0f3a8b7d21_pinboard_data-pinboard-db-0
```

Clean the debug Pod up (`kubectl debug node/...` leaves it behind):

```bash
kubectl delete pod -l '!app.kubernetes.io/name' --field-selector=status.phase=Succeeded 2>/dev/null
kubectl get pods | grep node-debugger
kubectl delete pod <node-debugger-name>
```

Finally, the cluster-wide view. Events are the audit trail of the last hour and
they are **not** sorted by default:

```bash
kubectl get events --sort-by=.lastTimestamp | tail -12
```

```text
LAST SEEN   TYPE      REASON              OBJECT                               MESSAGE
5m12s       Warning   BackOff             pod/pinboard-api-7f8d6c5b49-mn4xt    Back-off restarting failed container api in pod pinboard-api-7f8d6c5b49-mn4xt_pinboard
4m58s       Normal    Killing             pod/pinboard-api-7f8d6c5b49-mn4xt    Stopping container api
4m51s       Normal    ScalingReplicaSet   deployment/pinboard-api              Scaled down replica set pinboard-api-7f8d6c5b49 to 0 from 1
3m20s       Normal    Scheduled           pod/pinboard-api-58c7d9f4b6-4wq9x    Successfully assigned pinboard/pinboard-api-58c7d9f4b6-4wq9x to pinboard-worker2
3m19s       Normal    Pulled              pod/pinboard-api-58c7d9f4b6-4wq9x    Container image "pinboard-api:1.1" already present on machine
3m18s       Normal    Started             pod/pinboard-api-58c7d9f4b6-4wq9x    Started container api
```

> **Warning.** Events expire (one hour by default) and are stored in etcd, not in a
> log system. If an incident is older than an hour, the events are simply gone —
> another argument for shipping events and logs to a central stack.

**Optional: k9s.** If `k9s` is installed (Lab 00 installs it), run `k9s -n pinboard`
for a terminal UI over everything you just did: `:pods` to list, `l` for logs,
`d` for describe, `s` for a shell, `Ctrl-D` to delete, `:hpa`, `:events`, `?` for
help, `:q` to quit. Same API calls, fewer keystrokes — but learn the `kubectl` form
first, because that is what you will paste into a runbook.

### Step 08: A PodDisruptionBudget and a node drain

Everything so far was an *involuntary* disruption (a crash). A **PodDisruptionBudget**
protects you from *voluntary* ones — node drains, cluster upgrades, autoscaler
consolidation. Append to `20-api-deployment.yaml`, before the HPA:

```yaml
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pinboard-api
  namespace: pinboard
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: pinboard-api
```

```bash
kubectl apply -f 20-api-deployment.yaml
kubectl get pdb
```

```text
poddisruptionbudget.policy/pinboard-api created

NAME           MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
pinboard-api   2               N/A               0                     5s
```

`ALLOWED DISRUPTIONS: 0` — the HPA scaled the Deployment down to its minimum of 2,
so evicting even one Pod would violate the budget. Scale the *floor* up so there is
slack, and check where the Pods live:

```bash
kubectl patch hpa pinboard-api --type merge -p '{"spec":{"minReplicas":3}}'
sleep 20
kubectl get pods -o wide -l app.kubernetes.io/name=pinboard-api
kubectl get pdb
```

```text
NAME                            READY   STATUS    RESTARTS   AGE   IP            NODE
pinboard-api-58c7d9f4b6-4wq9x   1/1     Running   0          9m    10.244.1.13   pinboard-worker
pinboard-api-58c7d9f4b6-hn9lm   1/1     Running   0          46m   10.244.1.11   pinboard-worker
pinboard-api-58c7d9f4b6-lq2vp   1/1     Running   0          46m   10.244.2.7    pinboard-worker2

NAME           MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
pinboard-api   2               N/A               1                     97s
```

> **Warning.** Before you drain: `pinboard-db-0` uses a **local-path** volume that is
> pinned to one node (Lab 08, Stretch goal). If it happens to live on the node you
> drain, it will be evicted and stay `Pending` until you `uncordon`. That is not a
> bug in the lab — it is what node-local storage means, and it is exactly the
> conversation to have before running a database on `hostPath`-style volumes.

Drain the worker that runs **two** of the API Pods — `pinboard-worker` in the output
above; look at your own `NODE` column and use that name in the drain and uncordon
commands below. (Drain a node with only one API Pod and the eviction is simply
allowed: `ALLOWED DISRUPTIONS` is 1.) `--ignore-daemonsets` is needed because
DaemonSet Pods (kube-proxy, the CNI) are not evictable, and `--delete-emptydir-data`
because Pods with an `emptyDir` would otherwise block the drain:

```bash
kubectl drain pinboard-worker --ignore-daemonsets --delete-emptydir-data
```

```text
node/pinboard-worker cordoned
Warning: ignoring DaemonSet-managed Pods: kube-system/kindnet-8n7lp, kube-system/kube-proxy-r2mtq
evicting pod pinboard/pinboard-db-0
evicting pod pinboard/pinboard-api-58c7d9f4b6-hn9lm
evicting pod pinboard/pinboard-api-58c7d9f4b6-4wq9x
evicting pod pinboard/pinboard-web-7d9b5c6f8b-4nkzq
error when evicting pods/"pinboard-api-58c7d9f4b6-4wq9x" -n "pinboard" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
pod/pinboard-web-7d9b5c6f8b-4nkzq evicted
pod/pinboard-db-0 evicted
pod/pinboard-api-58c7d9f4b6-hn9lm evicted
evicting pod pinboard/pinboard-api-58c7d9f4b6-4wq9x
pod/pinboard-api-58c7d9f4b6-4wq9x evicted
node/pinboard-worker drained
```

Read the interesting line: the second API eviction was **refused** by the API server
because it would have left fewer than 2 API Pods available. `kubectl drain` retried
until the replacement Pod on the other worker became Ready, and only then was the
eviction allowed. Without the PDB, both would have gone at once.

Look at the damage and then undo it:

```bash
kubectl get pods -o wide
```

```text
NAME                            READY   STATUS    RESTARTS   AGE     IP           NODE
pinboard-api-58c7d9f4b6-k8f5n   1/1     Running   0          58s     10.244.2.15  pinboard-worker2
pinboard-api-58c7d9f4b6-lq2vp   1/1     Running   0          49m     10.244.2.7   pinboard-worker2
pinboard-api-58c7d9f4b6-w2ph8   1/1     Running   0          73s     10.244.2.14  pinboard-worker2
pinboard-db-0                   0/1     Pending   0          70s     <none>       <none>
pinboard-web-7d9b5c6f8b-jt6zr   1/1     Running   0          72s     10.244.2.13  pinboard-worker2
pinboard-web-7d9b5c6f8b-x8slt   1/1     Running   0          49m     10.244.2.8   pinboard-worker2
```

```bash
kubectl describe pod pinboard-db-0 | tail -4
```

```text
Events:
  Type     Reason            Age   From               Message
  ----     ----------------  ----  ----               -------
  Warning  FailedScheduling  63s   default-scheduler  0/3 nodes are available: 1 node(s) had untolerated taint {node.kubernetes.io/unschedulable: }, 2 node(s) had volume node affinity conflict. preemption: 0/3 nodes are available.
```

"volume node affinity conflict" in one line: the PV can only be used on
`pinboard-worker`, and `pinboard-worker` is cordoned. Bring the node back:

```bash
kubectl uncordon pinboard-worker
kubectl wait --for=condition=Ready pod/pinboard-db-0 --timeout=180s
curl -s http://localhost/api/notes | head -c 80; echo
```

```text
node/pinboard-worker uncordoned
pod/pinboard-db-0 condition met
[{"id":3,"text":"Secrets are only base64","author":"lab08","createdAt":"2026-08-20T09:3
```

The database came back with all its notes. Put the HPA floor back to 2:

```bash
kubectl apply -f 20-api-deployment.yaml
```

<details>
<summary><strong>Check yourself:</strong> a PDB with <code>minAvailable: 2</code> and a Deployment with <code>replicas: 2</code> — what happens during a cluster upgrade?</summary>

Nothing good: `ALLOWED DISRUPTIONS` is 0, so no Pod can ever be evicted and the node
drain hangs forever (many upgrade tools give up after a timeout and force the node
away, which is worse). A PDB must always leave slack — express it as
`maxUnavailable: 1`, or keep `minAvailable` strictly below the replica count, or use
a percentage (`minAvailable: 50%`). And remember a PDB does **not** protect against
crashes or node failures; it only gates the eviction API.
</details>

### Step 09: Lock the namespace down with Pod Security Admission

Every Pinboard workload already declares a `securityContext`: `runAsNonRoot`,
`allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`,
`capabilities.drop: ["ALL"]`, `seccompProfile: RuntimeDefault`. That is the
`restricted` Pod Security Standard — but nothing *enforces* it, so the next person
can happily deploy a privileged root container next to yours.

**Pod Security Admission** is a built-in admission controller driven entirely by
namespace labels. Add them to `00-namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: pinboard
  labels:
    app.kubernetes.io/part-of: pinboard
    # Pod Security Admission (Lab 09): refuse Pods that are not "restricted".
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
```

```bash
kubectl apply -f 00-namespace.yaml
kubectl get ns pinboard --show-labels
```

```text
namespace/pinboard configured

NAME       STATUS   AGE    LABELS
pinboard   Active   3h1m   app.kubernetes.io/part-of=pinboard,kubernetes.io/metadata.name=pinboard,pod-security.kubernetes.io/enforce=restricted,pod-security.kubernetes.io/warn=restricted
```

Nothing broke: your Pods keep running and, because they were already compliant, the
next rollout is accepted too. Now try to deploy something that is not:

```bash
kubectl run root-test --image=busybox -- sleep 1
```

```text
Error from server (Forbidden): pods "root-test" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "root-test" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "root-test" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "root-test" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "root-test" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

The rejection message is a checklist of everything that is missing — read it as
documentation. Three levels exist:

| Level | Blocks | Typical use |
|---|---|---|
| `privileged` | nothing | system namespaces, CNI, storage drivers |
| `baseline` | the obviously dangerous (host namespaces, privileged, hostPath, most capabilities) | shared platforms migrating gradually |
| `restricted` | also root, privilege escalation, all capabilities, non-default seccomp | application namespaces — this is where you want to be |

and three modes: `enforce` (reject), `audit` (annotate the audit log), `warn` (print
a warning to the client). The migration path in a real cluster is
`warn` + `audit` first, fix what shows up, then `enforce`.

> **Note.** This also explains the ordering of this lab: the load generator in Step 04
> and the `kubectl debug` containers in Step 07 are plain `busybox` with no
> `securityContext` and would now be **rejected**. If you want to re-run them,
> either add a compliant `securityContext` (see the Stretch goal) or use a
> different namespace. `kubectl debug` on the *node* always needs a privileged
> namespace such as `default`.

```bash
kubectl delete pod root-test --ignore-not-found
```

## Stretch goal

**1. Make the load generator `restricted`-compliant** and re-run Step 04 under
enforcement. Add to the Pod spec of `90-load-generator.yaml`:

```yaml
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: load
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

This is exactly the boilerplate the capstone expects you to know by heart. Delete
the generator again when you are done.

**2. ResourceQuota and LimitRange.** A quota caps what a namespace may consume in
total; a LimitRange supplies defaults and bounds for individual containers. Create
`03-quota-limitrange.yaml`:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: pinboard-quota
  namespace: pinboard
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.memory: 4Gi
    pods: "20"
    persistentvolumeclaims: "4"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: pinboard-defaults
  namespace: pinboard
spec:
  limits:
    - type: Container
      default:
        memory: 128Mi
      defaultRequest:
        cpu: 50m
        memory: 32Mi
      max:
        memory: 1Gi
      min:
        memory: 8Mi
```

```bash
kubectl apply -f 03-quota-limitrange.yaml
kubectl describe resourcequota pinboard-quota
```

```text
Name:                   pinboard-quota
Namespace:              pinboard
Resource                Used   Hard
--------                ----   ----
limits.memory           832Mi  4Gi
persistentvolumeclaims  1      4
pods                    5      20
requests.cpu            220m   2
requests.memory         256Mi  2Gi
```

> **Warning.** If a quota constrains `requests.cpu`, then **every** container in
> the namespace must declare a CPU request or its Pod is rejected. That is why the
> quota above deliberately does not constrain `limits.cpu` (the API sets no CPU
> limit) and why the LimitRange provides defaults for anything you forget.

**3. Watch a rollout with `kubectl events`.** Kubernetes 1.33 has a dedicated
command with better ordering and filtering than `kubectl get events`:

```bash
kubectl events --for deployment/pinboard-api --watch
```

## Conclusion

**What you have now:** the same Pinboard, operated like a service rather than a
demo.

- metrics-server installed; `kubectl top nodes` / `top pods` work
- an HPA that scales `pinboard-api` between 2 and 6 replicas on CPU, with a
  60-second scale-down stabilisation window
- a PodDisruptionBudget that made a real node drain wait for a replacement
- muscle memory for **get → describe → logs (`--previous`) → events → debug**, and
  the ability to tell `CrashLoopBackOff` (exit 1, read the logs) from `OOMKilled`
  (exit 137, raise the limit)
- `kubectl debug` for distroless containers and for nodes
- the namespace enforcing the `restricted` Pod Security Standard

Your `~/pinboard-labs/lab09/` folder is now the canonical end state of the course:
`00-namespace.yaml`, `01-db-secret.yaml`, `02-api-configmap.yaml`,
`10-db-statefulset.yaml`, `20-api-deployment.yaml` (Deployment + Service + PDB +
HPA), `30-web-deployment.yaml` and `40-ingress.yaml`.

**Cleanup: none.** Keep the cluster and the namespace — Lab 10 builds a *second*,
production-shaped namespace next to this one and you will want these files as your
reference while you write the new ones from scratch. Only the throwaway load
generator should be gone:

```bash
kubectl get deploy pinboard-load
```

```text
Error from server (NotFound): deployments.apps "pinboard-load" not found
```

Next: [Lab 10 – Capstone: ship Pinboard like production](lab10.md).
