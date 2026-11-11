# Lab 07 – Expose Pinboard

## Table of Contents

- [Goals](#goals)
- [Pre-requisites](#pre-requisites)
- [Guide](#guide)
  - [Step 01: Prepare the lab folder and check the state](#step-01-prepare-the-lab-folder-and-check-the-state)
  - [Step 02: A ClusterIP Service for the API](#step-02-a-clusterip-service-for-the-api)
  - [Step 03: DNS and load balancing from a debug Pod](#step-03-dns-and-load-balancing-from-a-debug-pod)
  - [Step 04: Scale the Deployment and watch the EndpointSlice](#step-04-scale-the-deployment-and-watch-the-endpointslice)
  - [Step 05: Deploy the web front end and its Service](#step-05-deploy-the-web-front-end-and-its-service)
  - [Step 06: NodePort, and why it disappoints on kind](#step-06-nodeport-and-why-it-disappoints-on-kind)
  - [Step 07: Install the Traefik Ingress controller](#step-07-install-the-traefik-ingress-controller)
  - [Step 08: One Ingress for the whole app](#step-08-one-ingress-for-the-whole-app)
  - [Step 09: Open Pinboard in the browser](#step-09-open-pinboard-in-the-browser)
  - [Step 10: Leave it running](#step-10-leave-it-running)
- [Stretch goal](#stretch-goal)
- [Conclusion](#conclusion)

## Goals

- Put a ClusterIP Service in front of the API replicas and see requests balanced across them
- Resolve Service names with cluster DNS from a throwaway debug Pod
- Watch EndpointSlices follow the Deployment as it scales
- Deploy the web front end pointing at `http://pinboard-api:8080`
- Understand why NodePort is awkward on kind, install the Traefik Ingress controller, and
  route `/` and `/api` through one Ingress on `http://localhost`

## Pre-requisites

- Have finished [Lab 06](lab06.md)
- The `pinboard-api` Deployment running with 3 replicas in namespace `pinboard`
- The kind cluster created from `labs/kind-config.yaml`, i.e. with host ports 80/443 mapped
- The course repository in `~/docker-kubernetes-training` (Lab 00), which holds the
  Traefik manifest `labs/traefik-kind.yaml`
- Internet access — the Traefik image is pulled from Docker Hub

```bash
kubectl get deploy,pods -l app.kubernetes.io/name=pinboard-api
```

```text
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/pinboard-api   3/3     3            3           52m

NAME                                READY   STATUS    RESTARTS   AGE
pod/pinboard-api-6d5b8c94f7-4hd2s   1/1     Running   0          20m
pod/pinboard-api-6d5b8c94f7-nq8vw   1/1     Running   0          20m
pod/pinboard-api-6d5b8c94f7-tzr6c   1/1     Running   0          20m
```

> **Continuity.** The API is resilient but unreachable: every rollout gives the Pods new
> IPs and `kubectl port-forward` only ever talks to one of them. This lab gives Pinboard
> stable names inside the cluster (Services), brings back the nginx front end you last saw
> in Compose, and finally publishes the whole thing on `http://localhost` through an
> Ingress — the Kubernetes equivalent of Compose's `ports: "8080:8080"`, but for the whole
> application at once.

## Guide

### Step 01: Prepare the lab folder and check the state

This lab keeps growing the same set of manifests, so start by bringing the API Deployment
over from Lab 06:

```bash
mkdir -p ~/pinboard-labs/lab07
cd ~/pinboard-labs/lab07
cp ~/pinboard-labs/lab06/20-api-deployment.yaml .
```

Write down the namespace you created imperatively in Lab 05, so the folder describes the
whole application. Create `00-namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: pinboard
  labels:
    app.kubernetes.io/part-of: pinboard
```

```bash
kubectl apply -f 00-namespace.yaml
```

```text
namespace/pinboard configured
```

(You may also see a `Warning: resource namespaces/pinboard is missing the
kubectl.kubernetes.io/last-applied-configuration annotation` — expected for an object first
made with `kubectl create`; `kubectl apply` adds the annotation itself. Harmless.)

"configured", not "created" — applying a manifest for an object that already exists simply
adds the labels. From here on `kubectl apply -f .` in this folder builds Pinboard from
nothing, in filename order, which is why the files are numbered.

```bash
kubectl get pods -o wide -l app.kubernetes.io/name=pinboard-api
```

```text
NAME                            READY   STATUS    RESTARTS   AGE   IP            NODE               NOMINATED NODE   READINESS GATES
pinboard-api-6d5b8c94f7-4hd2s   1/1     Running   0          20m   10.244.1.7    pinboard-worker    <none>           <none>
pinboard-api-6d5b8c94f7-nq8vw   1/1     Running   0          20m   10.244.2.5    pinboard-worker2   <none>           <none>
pinboard-api-6d5b8c94f7-tzr6c   1/1     Running   0          20m   10.244.1.8    pinboard-worker    <none>           <none>
```

Three Pods, three IPs, two nodes, one flat network — any Pod can reach any other Pod's IP
directly, no NAT, no port mapping. That is the Kubernetes network model, implemented here
by kindnet. Write those IPs down; they are about to become endpoints.

### Step 02: A ClusterIP Service for the API

The Service belongs with the workload it fronts, so append it to
`20-api-deployment.yaml` — one file, two objects, separated by a `---` line:

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: pinboard-api
  namespace: pinboard
  labels:
    app.kubernetes.io/name: pinboard-api
    app.kubernetes.io/component: api
    app.kubernetes.io/part-of: pinboard
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: pinboard-api
  ports:
    - name: http
      port: 8080        # the port the Service listens on
      targetPort: http  # the *named* container port of the Pods
```

Two details that matter more than they look:

- The Service selects **Pods by label**, not a Deployment. It has no idea Deployments
  exist. Any Pod carrying `app.kubernetes.io/name: pinboard-api` becomes a backend — which
  is how canary deployments and blue/green work, and how a typo in a label silently
  produces a Service with no endpoints.
- `targetPort: http` refers to the container port *named* `http` in the Pod template.
  Names survive a port-number change; numbers do not.

```bash
kubectl apply -f 20-api-deployment.yaml
kubectl get svc pinboard-api
```

```text
deployment.apps/pinboard-api unchanged
service/pinboard-api created
NAME           TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
pinboard-api   ClusterIP   10.96.132.44    <none>        8080/TCP   6s
```

That `10.96.132.44` is a **virtual IP**: no interface owns it, nothing answers ARP for it.
`kube-proxy` programs every node so that packets to it are rewritten to one of the Pod
IPs. It is stable for the life of the Service, which is the entire point.

Who is behind it?

```bash
kubectl get endpointslices -l kubernetes.io/service-name=pinboard-api
kubectl describe endpointslice -l kubernetes.io/service-name=pinboard-api | head -24
```

```text
NAME                 ADDRESSTYPE   PORTS   ENDPOINTS                          AGE
pinboard-api-x7k2b   IPv4          8080    10.244.1.7,10.244.2.5,10.244.1.8   24s

Name:         pinboard-api-x7k2b
Namespace:    pinboard
Labels:       kubernetes.io/service-name=pinboard-api
AddressType:  IPv4
Ports:
  Name     Port  Protocol
  ----     ----  --------
  http     8080  TCP
Endpoints:
  - Addresses:  10.244.1.7
    Conditions:
      Ready:    true
    Hostname:   <unset>
    TargetRef:  Pod/pinboard-api-6d5b8c94f7-4hd2s
    NodeName:   pinboard-worker
```

Exactly the three Pod IPs from Step 01. The endpoints controller keeps this list in sync
with the label selector *and with readiness* — `Ready: true` is the readiness probe from
Lab 06 reappearing as a routing decision. A Pod that fails `/readyz` is taken out of this
list within seconds, and no traffic reaches it. That is the sentence to remember from the
whole session.

> **Note.** `kubectl get endpoints` still works but the `Endpoints` object is deprecated
> (it could not scale past ~1000 addresses and had no topology fields). EndpointSlices
> replaced it: many small objects instead of one huge one.

### Step 03: DNS and load balancing from a debug Pod

CoreDNS gives every Service a name. Start a throwaway busybox Pod — `--rm` deletes it on
exit, `--restart=Never` makes it a plain Pod rather than a Deployment:

```bash
kubectl run -it --rm debug --image=busybox:1.37 --restart=Never -- sh
```

Inside the Pod:

```sh
nslookup pinboard-api
```

```text
Server:		10.96.0.10
Address:	10.96.0.10:53

Name:	pinboard-api.pinboard.svc.cluster.local
Address: 10.96.132.44
```

(busybox also prints a few `*** Can't find …` lines for the other search domains it tries
first — harmless.) The full name is
`<service>.<namespace>.svc.cluster.local`; inside the same namespace `pinboard-api` is
enough, because `/etc/resolv.conf` in every Pod lists the search domains:

```sh
cat /etc/resolv.conf
```

```text
search pinboard.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

Now call the API through the Service, twelve times:

```sh
for i in $(seq 1 12); do wget -qO- http://pinboard-api:8080/api/info | sed 's/.*"hostname":"\([^"]*\)".*/\1/'; done
```

```text
pinboard-api-6d5b8c94f7-nq8vw
pinboard-api-6d5b8c94f7-tzr6c
pinboard-api-6d5b8c94f7-4hd2s
pinboard-api-6d5b8c94f7-tzr6c
pinboard-api-6d5b8c94f7-nq8vw
pinboard-api-6d5b8c94f7-4hd2s
pinboard-api-6d5b8c94f7-tzr6c
pinboard-api-6d5b8c94f7-4hd2s
pinboard-api-6d5b8c94f7-nq8vw
pinboard-api-6d5b8c94f7-tzr6c
pinboard-api-6d5b8c94f7-4hd2s
pinboard-api-6d5b8c94f7-nq8vw
```

All three Pod names appear, in no particular order. This is **per-connection** balancing
done in the kernel by kube-proxy — not DNS round-robin (DNS returned a single address, the
ClusterIP) and not the 10-second nginx cache you saw in Compose. Note the distribution is
random, not strictly round-robin, so counts are only roughly equal.

Leave the debug Pod running in this terminal — Step 04 uses it. If you already exited,
start it again with the same command.

<details>
<summary><b>Check yourself:</b> the Service exists, DNS resolves, but every request times out. What do you look at first?</summary>

`kubectl get endpointslices -l kubernetes.io/service-name=<svc>`. An empty `ENDPOINTS`
column means no Pod is both *selected* and *ready*, and the two causes look identical from
the client side:

1. **Selector mismatch** — `spec.selector` in the Service does not match the Pod labels
   (a typo, or you copied the Deployment's `matchLabels` incorrectly). `kubectl get pods
   -l <selector>` returns nothing.
2. **Nothing is ready** — the Pods exist and match, but their readiness probes fail, so the
   endpoints controller keeps them out. `kubectl get pods` shows `0/1` in READY.

If endpoints *are* listed, the problem is further down: wrong `targetPort`, the container
listening on 127.0.0.1 instead of 0.0.0.0, or a NetworkPolicy.
</details>

### Step 04: Scale the Deployment and watch the EndpointSlice

In a **second terminal**:

```bash
kubectl get endpointslices -l kubernetes.io/service-name=pinboard-api -w
```

In a **third terminal**:

```bash
kubectl scale deployment/pinboard-api --replicas=5
```

The watch reacts within a second or two:

```text
NAME                 ADDRESSTYPE   PORTS   ENDPOINTS                                      AGE
pinboard-api-x7k2b   IPv4          8080    10.244.1.7,10.244.2.5,10.244.1.8               4m
pinboard-api-x7k2b   IPv4          8080    10.244.1.7,10.244.2.5,10.244.1.8 + 1 more...   4m
pinboard-api-x7k2b   IPv4          8080    10.244.1.7,10.244.2.5,10.244.1.8 + 2 more...   4m
```

The `ENDPOINTS` column shows at most three addresses, then `+ N more...`. A new Pod is
added to the slice as soon as it has an IP, but marked **not ready** until its readiness
probe passes — and kube-proxy only sends traffic to ready endpoints. See the condition
per address:

```bash
kubectl get endpointslices -l kubernetes.io/service-name=pinboard-api \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"  ready="}{.conditions.ready}{"\n"}{end}'
```

```text
10.244.1.7  ready=true
10.244.2.5  ready=true
10.244.1.8  ready=true
10.244.2.6  ready=true
10.244.1.9  ready=true
```

Run it straight after a scale-up and you may catch a `ready=false`. Run the `wget` loop in
the debug Pod again and you will hit five hostnames.

Scale back down and watch the addresses leave:

```bash
kubectl scale deployment/pinboard-api --replicas=3
```

Stop the watch with `Ctrl-C`, and exit the debug Pod (`exit`) — it deletes itself.

### Step 05: Deploy the web front end and its Service

The nginx front end serves the static page and proxies `/api/` to whatever `API_URL`
points at. In Compose that was `http://api:8080`; here it is the Service name. Create
`30-web-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pinboard-web
  namespace: pinboard
  labels:
    app.kubernetes.io/name: pinboard-web
    app.kubernetes.io/component: web
    app.kubernetes.io/part-of: pinboard
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: pinboard-web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: pinboard-web
        app.kubernetes.io/component: web
        app.kubernetes.io/part-of: pinboard
    spec:
      containers:
        - name: web
          image: pinboard-web:1.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: API_URL
              value: http://pinboard-api:8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: pinboard-web
  namespace: pinboard
  labels:
    app.kubernetes.io/name: pinboard-web
    app.kubernetes.io/component: web
    app.kubernetes.io/part-of: pinboard
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: pinboard-web
  ports:
    - name: http
      port: 8080
      targetPort: http
```

Two objects in one file, separated by `---`. Grouping the workload with the Service that
fronts it is the usual convention — they change together.

```bash
kubectl apply -f 30-web-deployment.yaml
kubectl rollout status deployment/pinboard-web
kubectl get svc
```

```text
deployment.apps/pinboard-web created
service/pinboard-web created
deployment "pinboard-web" successfully rolled out
NAME           TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
pinboard-api   ClusterIP   10.96.132.44    <none>        8080/TCP   9m
pinboard-web   ClusterIP   10.96.201.17    <none>        8080/TCP   14s
```

Reach the *Service* (not a Pod) from your laptop:

```bash
kubectl port-forward svc/pinboard-web 8080:8080
```

In another terminal:

```bash
curl -s localhost:8080/api/info
```

```text
{"app":"pinboard-api","greeting":"Welcome to Pinboard","hostname":"pinboard-api-6d5b8c94f7-nq8vw","store":"memory","theme":"amber","uptime":"31m","version":"1.1"}
```

That request travelled: laptop → API server tunnel → a `pinboard-web` Pod → nginx proxy →
`pinboard-api` Service → one of three API Pods. The whole chain runs on names.

Open <http://localhost:8080> and pin a note. The header is **amber**, because the API is
version 1.1 from Lab 06 — the theme is served by the API and rendered by the web tier.

> **Warning.** Notes are still stored in memory, per Pod. Post a few and reload: the list
> changes depending on which API Pod answered, because each replica has its own store.
> That is not a Kubernetes bug, it is what a stateful app without shared state looks like
> behind a load balancer. Lab 08 gives them a shared PostgreSQL.

Stop the port-forward with `Ctrl-C`.

### Step 06: NodePort, and why it disappoints on kind

> **Optional.** If you are short on time, skip to Step 07 — the instructor demo showed
> this, and nothing later depends on it.

A ClusterIP is only reachable inside the cluster. `NodePort` opens the same Service on a
high port (30000–32767 by default) on **every node**:

```bash
kubectl expose deployment pinboard-web --name=pinboard-web-np --type=NodePort --port=8080 --target-port=http
kubectl get svc pinboard-web-np
```

```text
service/pinboard-web-np exposed
NAME              TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)          AGE
pinboard-web-np   NodePort   10.96.44.180    <none>        8080:31572/TCP   5s
```

Try it from your laptop (use *your* port number):

```bash
curl -sS --max-time 3 http://localhost:31572/healthz
```

```text
curl: (7) Failed to connect to localhost port 31572 after 0 ms: Could not connect to server
```

Nothing is wrong with the Service. The "nodes" are Docker containers, and only the ports
listed in `extraPortMappings` (80 and 443) are published to your laptop. Port 31572 is open
on the node containers' own addresses. Prove it from inside the cluster (use one of *your*
node IPs and *your* port):

```bash
kubectl get nodes -o wide | awk '{print $1, $6}'
kubectl run -it --rm np-test --image=busybox:1.37 --restart=Never -- wget -qO- http://172.18.0.2:31572/healthz
```

```text
NAME INTERNAL-IP
pinboard-control-plane 172.18.0.4
pinboard-worker 172.18.0.2
pinboard-worker2 172.18.0.3
ok
pod "np-test" deleted
```

It works on the node IP — and note that it works on *any* node IP, including nodes running
no `pinboard-web` Pod, because kube-proxy forwards internally.

This is why NodePort is rarely the answer in practice:

- The port is a cluster-wide number in an ugly range, on every node, with no name.
- Clients need a node address, and nodes come and go.
- On a cloud provider you would use `type: LoadBalancer`, which provisions a real load
  balancer and hides all of this. On kind, `LoadBalancer` Services stay `<pending>`
  forever unless you install something like `cloud-provider-kind` or MetalLB.

Delete it — the Ingress does this job properly:

```bash
kubectl delete svc pinboard-web-np
```

### Step 07: Install the Traefik Ingress controller

An Ingress object is only data; it does nothing until a controller reads it. The course
uses **Traefik**, a reverse proxy that watches the API for Ingress objects and turns them
into routes. The course repository has a ready manifest for kind:

```bash
kubectl apply -f ~/docker-kubernetes-training/labs/traefik-kind.yaml
```

```text
namespace/traefik created
serviceaccount/traefik created
clusterrole.rbac.authorization.k8s.io/traefik-traefik created
clusterrolebinding.rbac.authorization.k8s.io/traefik-traefik created
service/traefik created
deployment.apps/traefik created
ingressclass.networking.k8s.io/traefik created
```

Seven ordinary objects: a namespace, an identity allowed to read Ingresses, Services and
EndpointSlices across the cluster (and to write an Ingress's status — the `ADDRESS` you
will see in a minute), a Service, a Deployment, and an `IngressClass`. No admission
webhook, no setup Jobs. Wait for the Deployment:

```bash
kubectl -n traefik rollout status deploy/traefik --timeout=120s
```

```text
Waiting for deployment "traefik" rollout to finish: 0 of 1 updated replicas are available...
deployment "traefik" successfully rolled out
```

```bash
kubectl get pods,svc -n traefik -o wide
kubectl get ingressclass
```

```text
NAME                          READY   STATUS    RESTARTS   AGE   IP           NODE                     NOMINATED NODE   READINESS GATES
pod/traefik-6c8b9d7f4-x2lqp   1/1     Running   0          47s   10.244.0.5   pinboard-control-plane   <none>           <none>

NAME              TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)          AGE   SELECTOR
service/traefik   ClusterIP   10.96.88.12   <none>        80/TCP,443/TCP   47s   app.kubernetes.io/instance=traefik-traefik,app.kubernetes.io/name=traefik

NAME      CONTROLLER                      PARAMETERS   AGE
traefik   traefik.io/ingress-controller   <none>       47s
```

The controller is itself just a Deployment of Pods in a namespace. Note the `NODE`: the
manifest pins it to the node labelled `ingress-ready=true` — the control plane, as
`labs/kind-config.yaml` labelled it — and binds that node's ports 80/443 with `hostPort`.
Those are exactly the ports `kind-config.yaml` mapped to your laptop, which is the whole
trick that makes `http://localhost` work.

Nothing routes yet, but the controller already answers:

```bash
curl -s -w '%{http_code}\n' http://localhost/
```

```text
404 page not found
404
```

A `404` here is good news: the controller is up and no rule matched. (`000` instead
means nothing is listening yet — the Pod is not Ready.)

> **Note.** `labs/traefik-kind.yaml` is plain YAML rendered from Traefik's official Helm
> chart with the values in `labs/traefik-kind-values.yaml`. Read the values file: it is
> short, and every line says why it is there. Session 10 installs the same thing with Helm.

### Step 08: One Ingress for the whole app

Create `40-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pinboard
  namespace: pinboard
  labels:
    app.kubernetes.io/part-of: pinboard
spec:
  ingressClassName: traefik
  rules:
    - http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: pinboard-api
                port:
                  name: http
          - path: /
            pathType: Prefix
            backend:
              service:
                name: pinboard-web
                port:
                  name: http
```

- `ingressClassName: traefik` picks the controller — it is the `NAME` of the IngressClass
  you just listed. Traefik only serves Ingresses of its own class, and its class is not
  the cluster default, so an Ingress without this line is ignored. With several
  controllers in a cluster, this is what stops all of them from serving your rules.
- No `host:` means "any host header" — good for `localhost`, not something to do in
  production.
- Longest matching prefix wins, so `/api/info` goes to the API and everything else to the
  web tier. The backends are **Services**, referenced by port *name*.

```bash
kubectl apply -f 40-ingress.yaml
kubectl get ingress
```

```text
ingress.networking.k8s.io/pinboard created
NAME       CLASS     HOSTS   ADDRESS     PORTS   AGE
pinboard   traefik   *       localhost   80      18s
```

`ADDRESS` fills in a few seconds after creation, once the controller has accepted the
object. Now, with no port-forward running anywhere:

```bash
curl -s localhost/api/info
curl -si localhost/ | head -5
```

```text
{"app":"pinboard-api","greeting":"Welcome to Pinboard","hostname":"pinboard-api-6d5b8c94f7-tzr6c","store":"memory","theme":"amber","uptime":"44m","version":"1.1"}
HTTP/1.1 200 OK
Accept-Ranges: bytes
Content-Length: 992
Content-Type: text/html
Date: Mon, 04 May 2026 12:31:08 GMT
```

Port 80 on your laptop → the kind control-plane container → the Traefik Pod → the
`pinboard-web` or `pinboard-api` Service's endpoints → a Pod. Confirm the routing decision
in the controller's own access log:

```bash
kubectl -n traefik logs deploy/traefik --tail=2
```

```text
172.18.0.1 - - [04/May/2026:12:31:08 +0000] "GET /api/info HTTP/1.1" 200 168 "-" "-" 3 "pinboard-pinboard-api@kubernetes" "http://10.244.1.7:8080" 2ms
172.18.0.1 - - [04/May/2026:12:31:12 +0000] "GET / HTTP/1.1" 200 992 "-" "-" 4 "pinboard-pinboard@kubernetes" "http://10.244.2.9:8080" 1ms
```

After the status and size come the request count, the **router** — Traefik's name for one
rule of your Ingress, `<namespace>-<ingress>-<path>` — and the **backend**, the Pod IP it
picked. That log line answers most "why did my request go there?" questions.

When a rule matches but nothing can serve it, Traefik answers `503`. See it once — scale
the API to zero, ask, and scale it back:

```bash
kubectl scale deploy/pinboard-api --replicas=0
curl -s -w '%{http_code}\n' http://localhost/api/info
kubectl scale deploy/pinboard-api --replicas=3
kubectl rollout status deploy/pinboard-api
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/api/info
```

```text
deployment.apps/pinboard-api scaled
no available server
503
deployment.apps/pinboard-api scaled
deployment "pinboard-api" successfully rolled out
200
```

(Still `200` on the first `curl`? The old Pods take a few seconds to terminate — repeat it.)

> **When it does not work**
>
> - `000` (connection refused) — the controller is not Ready yet:
>   `kubectl -n traefik get pods -o wide` must show it `Running` on `pinboard-control-plane`.
> - `404` for everything, `ADDRESS` empty — wrong or missing `ingressClassName` (it must
>   be `traefik`); the controller ignores Ingresses of other classes.
> - `503` — a rule matched, but the Service has no ready Pods. Check
>   `kubectl get endpointslices` and the Pods' readiness.
> - Requests land on the wrong backend — a mistyped Service name does *not* give an error
>   page: Traefik drops that rule and logs `Cannot create service error="service not found"`,
>   so the request falls through to `/`. Read `kubectl -n traefik logs deploy/traefik`.
> - The kind cluster would not start because port 80 is in use on your laptop — find the
>   culprit with `sudo ss -ltnp | grep ':80 '`.

### Step 09: Open Pinboard in the browser

Open <http://localhost>. You should see the Pinboard page with an **amber** header, an
`api` field with the version, a `served by` field naming the API **Pod** that answered,
and a `web` field showing the address you typed (`localhost`). Pin a note, reload a few
times, and watch the `served by` name change as the Service balances you across replicas.

Make the whole chain visible in one action — roll the API back to the emerald 1.0 image
while the page is open:

```bash
kubectl set image deployment/pinboard-api api=pinboard-api:1.0
kubectl set env deployment/pinboard-api APP_THEME=emerald
kubectl rollout status deployment/pinboard-api
```

Refresh the browser: the header turns green as the new Pods take over, and requests never
fail because readiness gates the endpoints. Then put it back the way Lab 08 expects:

```bash
kubectl apply -f 20-api-deployment.yaml
kubectl rollout status deployment/pinboard-api
curl -s localhost/api/info
```

```text
{"app":"pinboard-api","greeting":"Welcome to Pinboard","hostname":"pinboard-api-6d5b8c94f7-9wcn4","store":"memory","theme":"amber","uptime":"12s","version":"1.1"}
```

### Step 10: Leave it running

```bash
kubectl get deploy,svc,ingress,pods
```

```text
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/pinboard-api   3/3     3            3           1h18m
deployment.apps/pinboard-web   2/2     2            2           26m

NAME                   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/pinboard-api   ClusterIP   10.96.132.44    <none>        8080/TCP   38m
service/pinboard-web   ClusterIP   10.96.201.17    <none>        8080/TCP   26m

NAME                                 CLASS     HOSTS   ADDRESS     PORTS   AGE
ingress.networking.k8s.io/pinboard   traefik   *       localhost   80      7m

NAME                                READY   STATUS    RESTARTS   AGE
pod/pinboard-api-6d5b8c94f7-9wcn4   1/1     Running   0          3m
pod/pinboard-api-6d5b8c94f7-jd52p   1/1     Running   0          3m
pod/pinboard-api-6d5b8c94f7-x8kqt   1/1     Running   0          3m
pod/pinboard-web-5f9c7b8d64-2lmvz   1/1     Running   0          26m
pod/pinboard-web-5f9c7b8d64-h4nrx   1/1     Running   0          26m
```

> **Warning.** Delete nothing. Lab 08 attaches a real PostgreSQL StatefulSet to this exact
> setup, and Lab 09 autoscales and breaks it on purpose. The `traefik` namespace must
> stay too — every later lab reaches Pinboard through it.

## Stretch goal

> **Optional — only if you finish early.** Nothing in Lab 08 depends on these exercises,
> so skip them freely. If you do one, follow its clean-up so the next lab starts from
> the expected state.

1. **Host-based routing.** `*.localtest.me` resolves to `127.0.0.1` in public DNS, so you
   can use a real host name with no `/etc/hosts` edit. Create `ingress-host.yaml`
   with `host: pinboard.localtest.me` (a ready-made copy is in
   `labs/extras/lab07/ingress-host.yaml`) and apply it, then:

   ```bash
   curl -s http://pinboard.localtest.me/api/info
   curl -sI http://localhost/ -H 'Host: nope.example.com' | head -1
   ```

   The first works; the second still hits the host-less `pinboard` Ingress. Delete the
   original Ingress and repeat to see a `404 Not Found` from the controller (body
   `404 page not found`: no rule matched) — proof that the host header is part of the
   routing key. Then put things back with `kubectl delete -f ingress-host.yaml` and
   `kubectl apply -f 40-ingress.yaml`: the capstone (Lab 10) claims
   `pinboard.localtest.me` for its own Ingress, and two Ingresses claiming the same host
   and path are both accepted without an error — one silently wins.
2. **Where does Traefik's configuration live?** Look at the controller's command line:

   ```bash
   kubectl -n traefik get deploy traefik -o yaml | grep -- '- --'
   ```

   A dozen flags: the ports it listens on (`--entryPoints.web.address=:8000/tcp` is what
   the `hostPort` 80 leads to), `--providers.kubernetesingress` (read Ingress objects),
   `--accesslog=true`. There is no config file with your routes in it — the routes *are*
   your Ingress objects, read live from the API. Then match one request to its route:
   `curl -s localhost/api/info >/dev/null; kubectl -n traefik logs deploy/traefik --tail=1`,
   and name the router (which Ingress rule matched) and the backend (which Pod served it).
   The controller is a translator, nothing more magical than that.
3. **Gateway API (read, do not install).** Ingress is frozen; the Gateway API is its
   successor, with `GatewayClass` / `Gateway` / `HTTPRoute` splitting cluster-operator
   concerns from application-team concerns. The CRDs install with:

   ```bash
   kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
   ```

   Read `labs/extras/lab07/gateway-httproute.yaml` to see Pinboard's routing expressed
   as an `HTTPRoute`. Traefik *can* implement the Gateway API, but our install leaves that
   provider **off** — after installing the CRDs, `kubectl get gatewayclass` still says
   `No resources found`, so nothing in our cluster would serve those objects. A Gateway
   implementation (Traefik with its Gateway API provider on, Envoy Gateway, Istio, Cilium,
   a cloud load balancer) would be needed. Do not set one up during the lab; compare the shapes
   instead: `parentRefs` replaces `ingressClassName`, `backendRefs` takes a port number,
   and matching is explicit rather than annotation-driven.

## Conclusion

**What you have now**

- `pinboard-api` and `pinboard-web` Services (ClusterIP), each with an EndpointSlice that
  tracks ready Pods automatically.
- A `pinboard-web` Deployment (2 replicas) talking to the API by DNS name
  `http://pinboard-api:8080` — the same wiring you did with Compose's service names, now
  done by CoreDNS and kube-proxy.
- The Traefik Ingress controller installed, and an Ingress routing `/api` → API and `/` → web on
  `http://localhost`.
- A folder `~/pinboard-labs/lab07/` that describes the whole application and can be
  applied to an empty cluster with `kubectl apply -f .`:

  | File | Contains |
  |---|---|
  | `00-namespace.yaml` | Namespace `pinboard` |
  | `20-api-deployment.yaml` | Deployment + Service `pinboard-api` |
  | `30-web-deployment.yaml` | Deployment + Service `pinboard-web` |
  | `40-ingress.yaml` | Ingress `pinboard` on <http://localhost> |

**Kept for the next lab:** everything — the cluster, the `pinboard` namespace with both
Deployments, both Services and the Ingress, plus the `traefik` namespace.

The remaining lie is the data. Every API replica keeps notes in its own memory, so what
you see depends on which Pod answered, and a rollout wipes the lot. Next:
[Lab 08 – Give Pinboard a real database](lab08.md), where a Secret, a ConfigMap and a
StatefulSet with a PersistentVolumeClaim fix that for good.
