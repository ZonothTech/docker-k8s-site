# Lab 06 – Make Pinboard API resilient

## Table of Contents

- [Goals](#goals)
- [Pre-requisites](#pre-requisites)
- [Guide](#guide)
  - [Step 01: Prepare the lab folder and check the cluster](#step-01-prepare-the-lab-folder-and-check-the-cluster)
  - [Step 02: Write the Deployment](#step-02-write-the-deployment)
  - [Step 03: Deployment → ReplicaSet → Pods](#step-03-deployment--replicaset--pods)
  - [Step 04: Watch it serve while you change it](#step-04-watch-it-serve-while-you-change-it)
  - [Step 05: Roll out 1.1 imperatively, then in the file](#step-05-roll-out-11-imperatively-then-in-the-file)
  - [Step 06: Roll out a broken image and undo it](#step-06-roll-out-a-broken-image-and-undo-it)
  - [Step 07: Why the readiness probe is not optional](#step-07-why-the-readiness-probe-is-not-optional)
  - [Step 08: Scale and restart](#step-08-scale-and-restart)
  - [Step 09: Run-to-completion work: a Job and a CronJob](#step-09-run-to-completion-work-a-job-and-a-cronjob)
  - [Step 10: Clean up the batch objects, keep the Deployment](#step-10-clean-up-the-batch-objects-keep-the-deployment)
- [Stretch goal](#stretch-goal)
- [Conclusion](#conclusion)

## Goals

- Replace the bare Pod with a Deployment: 3 replicas, labels, probes, resources
- Understand the Deployment → ReplicaSet → Pod chain and read a rolling update as it happens
- Perform a rolling update both imperatively and declaratively, and record a change cause
- Recognise `CrashLoopBackOff` and recover with `kubectl rollout undo`
- Show that a rolling update without a readiness probe is an outage
- Scale, restart, and run one-off/scheduled work with Jobs and CronJobs

## Pre-requisites

- Have finished [Lab 05](lab05.md)
- The kind cluster `pinboard` running, kubectl context default namespace `pinboard`
- Images `pinboard-api:1.0`, `1.1` and `1.2-broken` loaded on the nodes
- Two terminals — one keeps a `curl` loop running through most of the lab
- Internet access for `busybox:1.37` and `postgres:17-alpine` in Step 09

Verify in one go:

```bash
kubectl config get-contexts
kubectl get nodes
docker exec pinboard-worker crictl images | grep pinboard-api
```

> **Continuity.** In Lab 05 you ran the API as a single Pod and then deleted it — and
> nothing brought it back. This lab hands that responsibility to a controller. By the end,
> three replicas of `pinboard-api:1.1` are running with liveness, readiness and startup
> probes, surviving deletions, updates and a deliberately broken release. That Deployment
> stays in the namespace: Lab 07 puts a Service in front of it.

## Guide

### Step 01: Prepare the lab folder and check the cluster

```bash
mkdir -p ~/pinboard-labs/lab06
cd ~/pinboard-labs/lab06
kubectl get all
```

```text
No resources found in pinboard namespace.
```

An empty namespace is the right starting point. If Pods from Lab 05 are still around,
delete them (`kubectl delete pod --all`).

### Step 02: Write the Deployment

Create `20-api-deployment.yaml`. The numeric prefix is a convention, not a requirement: it
makes `kubectl apply -f .` process a folder of manifests in a sensible order later. You will keep adding to this one file
until Lab 09.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pinboard-api
  namespace: pinboard
  labels:
    app.kubernetes.io/name: pinboard-api
    app.kubernetes.io/component: api
    app.kubernetes.io/part-of: pinboard
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1          # at most one extra Pod above `replicas`
      maxUnavailable: 0    # never drop below `replicas` ready Pods
  selector:
    matchLabels:
      app.kubernetes.io/name: pinboard-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: pinboard-api
        app.kubernetes.io/component: api
        app.kubernetes.io/part-of: pinboard
    spec:
      terminationGracePeriodSeconds: 15
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
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
            failureThreshold: 3
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 2
            failureThreshold: 30
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              memory: 64Mi
```

The parts that are new compared with the Pod of Lab 05:

- **`selector.matchLabels` and `template.metadata.labels` must agree.** The selector is
  how the Deployment finds the Pods it owns. It is immutable after creation — get it wrong
  and you delete and recreate the Deployment. Note that the selector uses only
  `app.kubernetes.io/name`: a selector should be the *minimum* stable set of labels.
- **`strategy`.** `maxUnavailable: 0` with `maxSurge: 1` means: start one new Pod, wait
  for it to be **ready**, then remove one old Pod, repeat. Capacity never dips. The other
  strategy, `Recreate`, kills everything first — right for a database, wrong for an API.
- **Three probes, three different questions.**
  - `startupProbe` — "has it finished booting?" While it runs, the other two are
    suspended. `2s × 30` gives a slow starter a whole minute without forcing a lazy
    liveness period on a healthy one.
  - `readinessProbe` → `/readyz` — "should this Pod get traffic *right now*?" Failing it
    removes the Pod from Service endpoints; it does **not** restart anything.
  - `livenessProbe` → `/healthz` — "is this process wedged?" Failing it **restarts the
    container**. Point it at something that cannot fail for an external reason: if you
    point liveness at a handler that checks the database, a database blip restarts every
    Pod you have — a self-inflicted outage.

> **Note.** `/readyz` in Pinboard pings its store, `/healthz` always answers 200 once the
> process is up. That split is the whole design.

### Step 03: Deployment → ReplicaSet → Pods

```bash
kubectl apply -f 20-api-deployment.yaml
kubectl rollout status deployment/pinboard-api
```

```text
deployment.apps/pinboard-api created
Waiting for deployment "pinboard-api" rollout to finish: 0 of 3 updated replicas are available...
Waiting for deployment "pinboard-api" rollout to finish: 1 of 3 updated replicas are available...
Waiting for deployment "pinboard-api" rollout to finish: 2 of 3 updated replicas are available...
deployment "pinboard-api" successfully rolled out
```

`rollout status` blocks until the Deployment reaches its desired state and exits non-zero
if it fails — the one command to put in a CI pipeline after `apply`.

```bash
kubectl get deploy,rs,pods -l app.kubernetes.io/name=pinboard-api
```

```text
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/pinboard-api   3/3     3            3           41s

NAME                                      DESIRED   CURRENT   READY   AGE
replicaset.apps/pinboard-api-7c9b6d4f85   3         3         3       41s

NAME                                READY   STATUS    RESTARTS   AGE
pod/pinboard-api-7c9b6d4f85-2xk4d   1/1     Running   0          41s
pod/pinboard-api-7c9b6d4f85-8ptz9   1/1     Running   0          41s
pod/pinboard-api-7c9b6d4f85-q6vhn   1/1     Running   0          41s
```

Three objects, one chain: **you** manage the Deployment, the Deployment manages
ReplicaSets, a ReplicaSet manages Pods. The hash `7c9b6d4f85` is derived from the Pod
template — change anything in `template:` and a *new* ReplicaSet with a new hash appears,
which is exactly how rollbacks are possible.

Prove that the controller is actually watching:

```bash
kubectl delete pod -l app.kubernetes.io/name=pinboard-api --wait=false
kubectl get pods -l app.kubernetes.io/name=pinboard-api
```

```text
pod "pinboard-api-7c9b6d4f85-2xk4d" deleted
pod "pinboard-api-7c9b6d4f85-8ptz9" deleted
pod "pinboard-api-7c9b6d4f85-q6vhn" deleted
NAME                            READY   STATUS        RESTARTS   AGE
pinboard-api-7c9b6d4f85-4wm2t   0/1     Running       0          2s
pinboard-api-7c9b6d4f85-8ptz9   1/1     Terminating   0          3m
pinboard-api-7c9b6d4f85-hd7bl   0/1     Running       0          2s
pinboard-api-7c9b6d4f85-lqx8f   0/1     Running       0          2s
```

Three replacements were created within a second of the deletion. This is the reconciliation
loop: observed state ≠ desired state → act. It is also why `kubectl delete pod` is never a
fix for anything — you are just asking for a fresh copy of the same problem.

<details>
<summary><b>Check yourself:</b> you edit <code>replicas: 3</code> to <code>replicas: 5</code> and <code>apply</code>. How many ReplicaSets exist afterwards?</summary>

Still one. `replicas` lives in the Deployment `spec`, not in the Pod `template`, so the
template hash does not change — the existing ReplicaSet is simply scaled to 5. A new
ReplicaSet appears only when the *template* changes (image, env, probes, resources,
labels…). That distinction is why scaling is instant and updates are gradual.
</details>

### Step 04: Watch it serve while you change it

There is no Service yet (Lab 07), so reach the Pods with `port-forward`. In a **second
terminal**:

```bash
kubectl port-forward deploy/pinboard-api 8080:8080
```

```text
Forwarding from 127.0.0.1:8080 -> 8080
Forwarding from [::1]:8080 -> 8080
```

In a **third terminal**, start the loop that stays up for the rest of the lab:

```bash
while true; do curl -s --max-time 2 localhost:8080/api/info || echo "REQUEST FAILED"; echo; sleep 0.5; done
```

```text
{"app":"pinboard-api","greeting":"Welcome to Pinboard","hostname":"pinboard-api-7c9b6d4f85-4wm2t","store":"memory","theme":"emerald","uptime":"3m10s","version":"1.0"}
{"app":"pinboard-api","greeting":"Welcome to Pinboard","hostname":"pinboard-api-7c9b6d4f85-4wm2t","store":"memory","theme":"emerald","uptime":"3m11s","version":"1.0"}
```

> **Warning.** `kubectl port-forward deploy/…` is **not** a load balancer. It picks *one*
> Pod that matches the Deployment's selector and tunnels to it — the `hostname` field
> never changes. When that Pod disappears during a rollout, the forward dies and you have
> to restart it:
> ```text
> E0504 11:04:22.118  portforward.go:351] error copying from local connection to remote stream: ...
> error: lost connection to pod
> ```
> Treat it as a debugging tunnel, not as traffic. Real client-side load balancing over all
> three replicas arrives with the Service in Lab 07.

### Step 05: Roll out 1.1 imperatively, then in the file

Two changes belong together: image `1.1` and `APP_THEME=amber`. Done naively they are two
separate rollouts — pause the Deployment, make both changes, resume:

```bash
kubectl rollout pause deployment/pinboard-api
kubectl set image deployment/pinboard-api api=pinboard-api:1.1
kubectl set env deployment/pinboard-api APP_THEME=amber
kubectl annotate deployment pinboard-api kubernetes.io/change-cause="1.1 + amber theme (kubectl set image/set env)" --overwrite
kubectl rollout resume deployment/pinboard-api
```

```text
deployment.apps/pinboard-api paused
deployment.apps/pinboard-api image updated
deployment.apps/pinboard-api env updated
deployment.apps/pinboard-api annotated
deployment.apps/pinboard-api resumed
```

> **Note.** The old `--record` flag is deprecated and does nothing useful. The change
> cause is just the annotation `kubernetes.io/change-cause` — set it yourself, and make it
> say *why*, not *what* (the diff already says what).

Watch the rollout:

```bash
kubectl rollout status deployment/pinboard-api --watch
```

```text
Waiting for deployment "pinboard-api" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "pinboard-api" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "pinboard-api" rollout to finish: 1 old replicas are pending termination...
deployment "pinboard-api" successfully rolled out
```

And the two ReplicaSets, old and new:

```bash
kubectl get rs -l app.kubernetes.io/name=pinboard-api
```

```text
NAME                      DESIRED   CURRENT   READY   AGE
pinboard-api-5d8c9f7b64   3         3         3       48s
pinboard-api-7c9b6d4f85   0         0         0       9m12s
```

The old ReplicaSet is kept at zero replicas — that is the rollback mechanism, not
bookkeeping. `revisionHistoryLimit: 5` caps how many are retained.

```bash
kubectl rollout history deployment/pinboard-api
```

```text
deployment.apps/pinboard-api
REVISION  CHANGE-CAUSE
1         <none>
2         1.1 + amber theme (kubectl set image/set env)
```

Your curl loop now shows `"version":"1.1"` and `"theme":"amber"` (restart the
`port-forward`, it died with its Pod).

**Now make the file tell the truth.** Imperative commands are for emergencies; the cluster
must not drift from git. Edit `20-api-deployment.yaml`:

```yaml
          image: pinboard-api:1.1
```

```yaml
          env:
            - name: APP_THEME
              value: amber
```

```bash
kubectl apply -f 20-api-deployment.yaml
kubectl rollout status deployment/pinboard-api
kubectl rollout history deployment/pinboard-api
```

```text
deployment.apps/pinboard-api configured
deployment "pinboard-api" successfully rolled out
deployment.apps/pinboard-api
REVISION  CHANGE-CAUSE
1         <none>
2         1.1 + amber theme (kubectl set image/set env)
```

"configured", and no new Pods: the template you just applied is byte-identical to what the
`set` commands produced, so no new ReplicaSet is needed and no revision is added. That is
declarative convergence working exactly as advertised — the file describes the end state,
and applying it when the cluster already matches is a no-op.

> **Note.** `kubernetes.io/change-cause` is an ordinary annotation, so it can also live in
> the manifest under `metadata.annotations`. Keep it out of the file for this course: with
> GitOps the commit message *is* the change cause, and an annotation in git that is edited
> on every release is one more thing to forget.

### Step 06: Roll out a broken image and undo it

`pinboard-api:1.2-broken` was built with `CRASH_ON_START=true` baked in — it logs and
exits 1 immediately. Ship it:

```bash
kubectl set image deployment/pinboard-api api=pinboard-api:1.2-broken
kubectl annotate deployment pinboard-api kubernetes.io/change-cause="1.2-broken (do not do this on Friday)" --overwrite
kubectl rollout status deployment/pinboard-api --timeout=60s
```

```text
Waiting for deployment "pinboard-api" rollout to finish: 1 out of 3 new replicas have been updated...
error: timed out waiting for the condition
```

```bash
kubectl get pods -l app.kubernetes.io/name=pinboard-api
```

```text
NAME                            READY   STATUS             RESTARTS      AGE
pinboard-api-5d8c9f7b64-6kd9m   1/1     Running            0             6m
pinboard-api-5d8c9f7b64-c2rvt   1/1     Running            0             6m
pinboard-api-5d8c9f7b64-w9fzq   1/1     Running            0             6m
pinboard-api-6b4f8d9c77-nl53x   0/1     CrashLoopBackOff   4 (28s ago)   84s
```

Read what happened, and what did **not**:

- The new Pod is in `CrashLoopBackOff` — the kubelet restarts it with a growing delay
  (10 s, 20 s, 40 s … capped at 5 min). `RESTARTS 4` is the counter.
- All **three old Pods are still serving**. `maxUnavailable: 0` means no old Pod is
  removed until a new one is ready, and no new one ever will be. The bad release is
  stuck, not deployed. Your curl loop never noticed.

```bash
kubectl logs -l app.kubernetes.io/name=pinboard-api --tail=2 --prefix | grep -i crash
kubectl describe pod -l app.kubernetes.io/name=pinboard-api | grep -A6 'Last State'
```

```text
[pod/pinboard-api-6b4f8d9c77-nl53x/api] time=2026-05-04T11:19:03.221Z level=ERROR msg="CRASH_ON_START is set — exiting with status 1 (this is on purpose)"
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
      Started:      Mon, 04 May 2026 11:19:03 +0000
      Finished:     Mon, 04 May 2026 11:19:03 +0000
    Ready:          False
    Restart Count:  4
```

`Exit Code: 1` from the container itself — the application refused to start. (Compare
`Exit Code: 137` = SIGKILL, usually `OOMKilled`, which you will meet in Lab 09.)

Undo:

```bash
kubectl rollout undo deployment/pinboard-api
kubectl rollout status deployment/pinboard-api
kubectl get pods -l app.kubernetes.io/name=pinboard-api
```

```text
deployment.apps/pinboard-api rolled back
deployment "pinboard-api" successfully rolled out
NAME                            READY   STATUS    RESTARTS   AGE
pinboard-api-5d8c9f7b64-6kd9m   1/1     Running   0          9m
pinboard-api-5d8c9f7b64-c2rvt   1/1     Running   0          9m
pinboard-api-5d8c9f7b64-w9fzq   1/1     Running   0          9m
```

`undo` scaled the crashing ReplicaSet back to 0 and re-pointed the Deployment at the
previous one — which never stopped running. Use `kubectl rollout undo --to-revision=N`
to go further back, and `kubectl rollout history --revision=3` to inspect a revision
before jumping to it.

> **Warning.** `rollout undo` changes the cluster but not your YAML file. The next
> `kubectl apply -f 20-api-deployment.yaml` re-applies whatever is in the file. After an
> emergency rollback, fix the file — that is the actual end of the incident.

<details>
<summary><b>Check yourself:</b> the API keeps a 30-second-long request queue after a database blip. Which probe do you point at the database check — liveness or readiness?</summary>

**Readiness, never liveness.** A failing readiness probe takes the Pod out of the Service
endpoints; when the database recovers, the probe passes and the Pod is back, with no
restart and no lost warm state. A failing *liveness* probe restarts the container — so a
30-second database blip would restart every replica simultaneously, throw away all
in-flight work, and hit the recovering database with a stampede of reconnecting Pods. The
rule: liveness answers "is this process wedged and unrecoverable?" and should depend on
nothing external. Everything about dependencies belongs in readiness.
</details>

### Step 07: Why the readiness probe is not optional

So far the probes did their job silently. Remove one and watch the safety net vanish.
Create `20-api-deployment-noready.yaml` as a copy of `20-api-deployment.yaml` with two changes:
the `readinessProbe` block deleted, and an env var that makes the API stop being ready
15 seconds after it starts:

```yaml
          env:
            - name: APP_THEME
              value: amber
            - name: FAIL_READY_AFTER
              value: "15"
```

```bash
kubectl apply -f 20-api-deployment-noready.yaml
kubectl rollout status deployment/pinboard-api
kubectl get pods -l app.kubernetes.io/name=pinboard-api
```

```text
deployment.apps/pinboard-api configured
deployment "pinboard-api" successfully rolled out
NAME                            READY   STATUS    RESTARTS   AGE
pinboard-api-84d7c5f9b6-4jgqn   1/1     Running   0          22s
pinboard-api-84d7c5f9b6-pk8rw   1/1     Running   0          18s
pinboard-api-84d7c5f9b6-t6vhc   1/1     Running   0          14s
```

The rollout "succeeded" in about 20 seconds, and every Pod reports `1/1 READY` — because
with no readiness probe, "the container is running" *is* the readiness definition. But the
application says otherwise. Restart the `port-forward` (it died with its Pod), wait 15
seconds, and ask the API itself:

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/readyz
curl -s localhost:8080/readyz
```

```text
503
not ready: FAIL_READY_AFTER elapsed
```

Three replicas, all "ready", none able to serve. Every old Pod was replaced. In Lab 07,
with a Service in front, this is a total outage with a green `rollout status`.

Now put the probe back:

```bash
kubectl apply -f 20-api-deployment.yaml
kubectl rollout status deployment/pinboard-api --timeout=45s
```

```text
deployment.apps/pinboard-api configured
Waiting for deployment "pinboard-api" rollout to finish: 1 out of 3 new replicas have been updated...
deployment "pinboard-api" successfully rolled out
```

That one goes through, because `20-api-deployment.yaml` has no `FAIL_READY_AFTER` — healthy
Pods pass `/readyz` and the rollout proceeds one Pod at a time.

**Optional (if you have time): watch readiness block a release.** Add the readiness probe
back to `20-api-deployment-noready.yaml`, change `FAIL_READY_AFTER` to `"1"` (the Pods are
never ready) and apply it: the first new Pod stays `0/1`, the rollout stalls at "1 out of 3
new replicas have been updated", and the old Pods keep serving. (With `"15"` the rollout
would still finish — each new Pod passes its first probes within seconds and only drops to
`0/1`, out of rotation, after 15 s. A probe judges *now*, not the future.)

```text
NAME                            READY   STATUS    RESTARTS   AGE
pinboard-api-5d8c9f7b64-6kd9m   1/1     Running   0          14m    ← old, still serving
pinboard-api-5d8c9f7b64-c2rvt   1/1     Running   0          14m
pinboard-api-5d8c9f7b64-w9fzq   1/1     Running   0          14m
pinboard-api-9f6c4b7d58-x2mtq   0/1     Running   0          52s    ← new, never ready
```

The lesson in one line: **`maxUnavailable: 0` is only a promise if something can tell
"running" from "working" — and that something is the readiness probe.**

Make sure you end this step on the good manifest:

```bash
kubectl apply -f 20-api-deployment.yaml
kubectl get pods -l app.kubernetes.io/name=pinboard-api
```

### Step 08: Scale and restart

```bash
kubectl scale deployment/pinboard-api --replicas=5
kubectl get pods -l app.kubernetes.io/name=pinboard-api
```

```text
deployment.apps/pinboard-api scaled
NAME                            READY   STATUS    RESTARTS   AGE
pinboard-api-5d8c9f7b64-6kd9m   1/1     Running   0          16m
pinboard-api-5d8c9f7b64-c2rvt   1/1     Running   0          16m
pinboard-api-5d8c9f7b64-w9fzq   1/1     Running   0          16m
pinboard-api-5d8c9f7b64-jr4dp   1/1     Running   0          4s
pinboard-api-5d8c9f7b64-zt7bk   1/1     Running   0          4s
```

No new ReplicaSet, no rolling update — the template did not change. Note that
`kubectl scale` leaves your file saying `replicas: 3`, so the next `apply` scales back
down; that is a classic surprise. Do it deliberately:

```bash
kubectl scale deployment/pinboard-api --replicas=3
```

Restarting every Pod without changing anything (the usual reason: a ConfigMap or Secret
changed, which you will do for real in Lab 08):

```bash
kubectl rollout restart deployment/pinboard-api
kubectl rollout status deployment/pinboard-api
```

```text
deployment.apps/pinboard-api restarted
Waiting for deployment "pinboard-api" rollout to finish: 1 out of 3 new replicas have been updated...
deployment "pinboard-api" successfully rolled out
```

`rollout restart` stamps `kubectl.kubernetes.io/restartedAt` into the Pod template, which
creates a new ReplicaSet and runs a normal rolling update — a graceful restart with the
same availability guarantees, not `delete pod --all`.

### Step 09: Run-to-completion work: a Job and a CronJob

Deployments are for processes that should never end. A **Job** is for work that must run
once and finish; a **CronJob** creates Jobs on a schedule. Create `job-migrate.yaml` —
a stand-in for the "run the database migrations" step of a release:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: pinboard-migrate
  namespace: pinboard
  labels:
    app.kubernetes.io/name: pinboard-migrate
    app.kubernetes.io/component: migration
    app.kubernetes.io/part-of: pinboard
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app.kubernetes.io/name: pinboard-migrate
        app.kubernetes.io/component: migration
        app.kubernetes.io/part-of: pinboard
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: postgres:17-alpine
          command:
            - sh
            - -c
            - 'echo "applying migrations..."; psql --version; sleep 2; echo "migrations done"'
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              memory: 64Mi
```

```bash
kubectl apply -f job-migrate.yaml
kubectl wait --for=condition=complete job/pinboard-migrate --timeout=120s
kubectl get job,pods -l app.kubernetes.io/name=pinboard-migrate
kubectl logs job/pinboard-migrate
```

```text
job.batch/pinboard-migrate created
job.batch/pinboard-migrate condition met
NAME                         STATUS     COMPLETIONS   DURATION   AGE
job.batch/pinboard-migrate   Complete   1/1           14s        21s

NAME                          READY   STATUS      RESTARTS   AGE
pod/pinboard-migrate-x7lqp    0/1     Completed   0          21s
applying migrations...
psql (PostgreSQL) 17.6
migrations done
```

Three fields carry the whole semantics:

- `restartPolicy: Never` (or `OnFailure`) — a Job Pod must be able to reach a terminal
  state. `Always` is rejected.
- `backoffLimit: 2` — how many failed Pods before the Job gives up and is marked `Failed`.
  Without it you would get six retries (the default) with exponential back-off.
- `ttlSecondsAfterFinished: 300` — the Job and its Pod are garbage-collected five minutes
  after finishing. Skip it and finished Jobs accumulate in the namespace forever; the
  `Completed` Pod above is kept only so you can read its logs.

> **Note.** `Completed` Pods consume no CPU or memory — they are dead containers whose
> metadata is retained. They are still objects in etcd, though, which is why the TTL
> matters on a busy cluster.

Now the scheduled version. Create `cronjob-heartbeat.yaml`:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pinboard-heartbeat
  namespace: pinboard
  labels:
    app.kubernetes.io/name: pinboard-heartbeat
    app.kubernetes.io/component: maintenance
    app.kubernetes.io/part-of: pinboard
spec:
  schedule: "* * * * *"        # every minute (cluster time zone = UTC on kind)
  concurrencyPolicy: Forbid    # never run two at once
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    metadata:
      labels:                    # copied onto every Job the CronJob creates
        app.kubernetes.io/name: pinboard-heartbeat
        app.kubernetes.io/part-of: pinboard
    spec:
      backoffLimit: 1
      ttlSecondsAfterFinished: 120
      template:
        metadata:
          labels:
            app.kubernetes.io/name: pinboard-heartbeat
            app.kubernetes.io/component: maintenance
            app.kubernetes.io/part-of: pinboard
        spec:
          restartPolicy: OnFailure
          containers:
            - name: heartbeat
              image: busybox:1.37
              command: ["sh", "-c", 'echo "$(date +%T) pinboard heartbeat"']
              resources:
                requests:
                  cpu: 10m
                  memory: 16Mi
                limits:
                  memory: 32Mi
```

```bash
kubectl apply -f cronjob-heartbeat.yaml
kubectl get cronjob
```

```text
cronjob.batch/pinboard-heartbeat created
NAME                 SCHEDULE    TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
pinboard-heartbeat   * * * * *   <none>     False     0        <none>          8s
```

Wait for the top of the next minute, then:

```bash
kubectl get jobs -l app.kubernetes.io/name=pinboard-heartbeat
kubectl logs -l app.kubernetes.io/name=pinboard-heartbeat --tail=1
```

```text
NAME                          STATUS     COMPLETIONS   DURATION   AGE
pinboard-heartbeat-29638920   Complete   1/1           3s         37s
11:41:00 pinboard heartbeat
```

The Job name ends in the scheduled minute (Unix minutes), which makes it easy to see
*which* run you are looking at. `concurrencyPolicy: Forbid` skips a run if the previous
one is still going — the alternatives are `Allow` (default, overlapping runs) and
`Replace`. Trigger one immediately without waiting for the schedule:

```bash
kubectl create job --from=cronjob/pinboard-heartbeat heartbeat-manual
kubectl logs job/heartbeat-manual
```

> **Note.** The obvious CronJob for Pinboard — "curl `/readyz` every minute and alert if
> it fails" — needs a stable address for the API. That is a Service, and it is the first
> thing you build in Lab 07.

### Step 10: Clean up the batch objects, keep the Deployment

Delete the batch objects (their TTLs would eventually do it, but be explicit) and stop the
`port-forward` and the curl loop:

```bash
kubectl delete -f cronjob-heartbeat.yaml
kubectl delete job pinboard-migrate heartbeat-manual --ignore-not-found
kubectl get all
```

```text
cronjob.batch "pinboard-heartbeat" deleted
job.batch "pinboard-migrate" deleted
job.batch "heartbeat-manual" deleted
NAME                                READY   STATUS    RESTARTS   AGE
pod/pinboard-api-6d5b8c94f7-4hd2s   1/1     Running   0          6m
pod/pinboard-api-6d5b8c94f7-nq8vw   1/1     Running   0          6m
pod/pinboard-api-6d5b8c94f7-tzr6c   1/1     Running   0          6m

NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/pinboard-api   3/3     3            3           38m

NAME                                      DESIRED   CURRENT   READY   AGE
replicaset.apps/pinboard-api-5d8c9f7b64   0         0         0       28m
replicaset.apps/pinboard-api-6d5b8c94f7   3         3         3       6m
replicaset.apps/pinboard-api-84d7c5f9b6   0         0         0       19m
replicaset.apps/pinboard-api-7c9b6d4f85   0         0         0       38m
```

> **Warning.** Leave the `pinboard-api` Deployment running. Lab 07 puts a Service in front
> of exactly these three Pods. The zero-replica ReplicaSets are your rollback history —
> harmless, and capped at 5 by `revisionHistoryLimit`.

## Stretch goal

1. **Prove `Recreate` is different.** Copy the Deployment to `20-api-deployment-recreate.yaml`
   with `strategy: {type: Recreate}` (delete the `rollingUpdate:` block), apply it, then
   change the image and watch `kubectl get pods -w`: every Pod is terminated *before* the
   first new one starts. Correct for something that cannot run two versions at once (a
   database with a schema migration), an outage for an API.
2. **Watch a graceful shutdown.** Run
   `kubectl logs -f -l app.kubernetes.io/name=pinboard-api --prefix` in one terminal and
   `kubectl rollout restart deployment/pinboard-api` in another. Look for
   `signal received, shutting down gracefully grace=10s` followed by `bye`. Then set
   `terminationGracePeriodSeconds: 2` and repeat: the kubelet SIGKILLs the process before
   it finishes draining. That number is a *deadline*, not a delay.
3. **Read the rollout as data.**
   `kubectl get deployment pinboard-api -o jsonpath='{.status.conditions[*].reason}'`
   prints `NewReplicaSetAvailable` on a healthy Deployment and
   `ProgressDeadlineExceeded` on a stuck one — that is what `rollout status` is watching,
   and what an alert would query.

## Conclusion

**What you have now**

- A `pinboard-api` Deployment: 3 replicas of `pinboard-api:1.1` with `APP_THEME=amber`,
  startup + readiness + liveness probes, requests and limits, `maxSurge: 1` /
  `maxUnavailable: 0`, and a recorded change cause.
- `20-api-deployment.yaml`, `20-api-deployment-noready.yaml`, `job-migrate.yaml` and
  `cronjob-heartbeat.yaml` in `~/pinboard-labs/lab06/`.
- First-hand evidence for four things: a controller replaces deleted Pods; a broken
  release with `maxUnavailable: 0` stalls instead of taking you down; `rollout undo` is
  seconds, not minutes; and a rolling update without readiness is an outage with a green
  status line.

**Kept for the next lab:** the cluster, the namespace, the loaded images, and the running
`pinboard-api` Deployment. **Removed:** the Job and CronJob.

Still missing: a stable address. Pod IPs change on every rollout, and `port-forward`
reaches exactly one Pod. Next: [Lab 07 – Expose Pinboard](lab07.md).
