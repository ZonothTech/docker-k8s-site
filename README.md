<div align="center">

# Containers & Kubernetes Fundamentals

## A hands-on, project-based introduction to Docker and Kubernetes — from your first `docker run` to a production-shaped deployment on a local cluster.

### 20 hours · 10 live sessions of 2h · for engineers with zero container experience

![Duration](https://img.shields.io/badge/duration-20h-3ce8a6?style=flat-square&labelColor=12242a)
![Sessions](https://img.shields.io/badge/sessions-10%20%C3%97%202h-3ce8a6?style=flat-square&labelColor=12242a)
![Docker](https://img.shields.io/badge/Docker-Engine%2028%2B%20%2B%20Compose%20v2-12a85c?style=flat-square&labelColor=12242a)
![Kubernetes](https://img.shields.io/badge/Kubernetes-1.37%20on%20kind-12a85c?style=flat-square&labelColor=12242a)
![Level](https://img.shields.io/badge/level-beginner%20%E2%86%92%20practitioner-12a85c?style=flat-square&labelColor=12242a)

[**Setup guide**](./labs/lab00-setup.md) · [**Curriculum**](#curriculum) · [**Labs**](#labs) · [**Slides (PDF)**](#slides) · [**Sample app**](./src/README.md)

</div>

---

## About this repository

This is the **attendee repository** for the course. It holds everything you need during
and after the sessions:

- the **labs** — step-by-step, with the expected output of every command;
- the **slides** of every session, as PDF;
- the **Pinboard** sample application you build, ship and operate in every lab.

Clone it once before Session 01 (the [setup guide](./labs/lab00-setup.md) shows how) and
keep it — the labs reference its files constantly.

## Why this course

Most container courses hand you a different toy in every lab. This one is built around
a **single application you carry from session one to session ten**: *Pinboard*, a tiny
three-tier app (Go API, static web front-end on nginx, PostgreSQL). You run its database
in a container in the first hour; by the last session you deploy the whole thing into a
production-shaped namespace — probes, resources, security context, autoscaling,
disruption budgets, Ingress — from a blank folder, and a script grades it.

You learn the way you'll actually work: build the image, read the logs, write the
manifest, watch the rollout, break it, debug it, fix it.

> **The storyline.** Session 01: run Postgres in a container and lose your data. 02: build
> Pinboard's images properly (multi-stage, distroless, non-root). 03: wire the three tiers
> by hand with networks and volumes. 04: one `compose.yaml`. 05: a local Kubernetes cluster
> with kind and your first Pods. 06: Deployments, rolling updates and probes. 07: Services,
> DNS and Ingress. 08: ConfigMaps, Secrets and a StatefulSet database. 09: autoscaling,
> troubleshooting, Pod security. 10: the capstone.

## Who it's for

- **Software engineers** who want to ship their code as images and understand what the platform team means by "just add a readiness probe".
- **Infra / SysAdmin / DevOps** practitioners moving from VMs and scripts to containers and declarative orchestration.
- Anyone technical and comfortable in a Linux terminal — **no prior Docker or Kubernetes experience needed**.

## What you'll be able to do by the end

- Explain what a container is (namespaces, cgroups, layered filesystems, OCI) and how Docker, containerd and Kubernetes relate.
- Write small, safe, cacheable Dockerfiles; tag, publish and inspect images.
- Run multi-container applications with networks, volumes, limits and health checks — by hand and with Compose.
- Read a Kubernetes cluster: control plane, nodes, the API object model, `kubectl` and `kubectl explain`.
- Deploy workloads with Deployments, probes and resource requests; roll out and roll back safely.
- Expose applications with Services and Ingress; configure them with ConfigMaps and Secrets; persist data with PVCs and StatefulSets.
- Troubleshoot with a method (`get` → `describe` → `logs` → `events` → `debug`), autoscale with HPA, and apply baseline Pod security.

---

## Curriculum

Each 2-hour session runs the same rhythm: **50 min theory + demos · 10 min break · 20–30 min theory + demos · 30–40 min lab.**
Session 10 is 30 min theory + an 80 min capstone lab.

| # | Session | You'll learn | Slides | Lab |
|---|---------|--------------|:------:|:---:|
| 01 | **Containers & Docker: the mental model** | Why containers, namespaces/cgroups/overlayfs, OCI, Docker architecture, images vs containers vs registries, the everyday CLI | [PDF](./decks/session-01.pdf) | [Lab 01](./labs/lab01.md) |
| 02 | **Building images** | Dockerfile, BuildKit layers & cache, multi-stage, base-image ladder, non-root, tags & digests, publishing, SBOM/provenance | [PDF](./decks/session-02.pdf) | [Lab 02](./labs/lab02.md) |
| 03 | **Running containers well** | ENV/ARG, CMD vs ENTRYPOINT, signals & PID 1, volumes/bind/tmpfs, networks & DNS, limits, restart policies, health checks | [PDF](./decks/session-03.pdf) | [Lab 03](./labs/lab03.md) |
| 04 | **Docker Compose** | The Compose Specification, healthchecks & `depends_on`, env files, `up --wait`, `watch`, scaling, overrides — and where Compose stops | [PDF](./decks/session-04.pdf) | [Lab 04](./labs/lab04.md) |
| 05 | **Kubernetes: architecture, kubectl, Pods** | Control plane & nodes, the API object model, desired state, kubeconfig, namespaces, Pods, init & sidecar containers, requests/limits | [PDF](./decks/session-05.pdf) | [Lab 05](./labs/lab05.md) |
| 06 | **Workloads, rollouts and probes** | Labels & selectors, ReplicaSets, Deployments, rolling updates & rollbacks, liveness/readiness/startup probes, Jobs & CronJobs | [PDF](./decks/session-06.pdf) | [Lab 06](./labs/lab06.md) |
| 07 | **Networking: Services, DNS, Ingress** | Pod network model, Service types, EndpointSlices, cluster DNS, Ingress & ingress-nginx, Gateway API, NetworkPolicy | [PDF](./decks/session-07.pdf) | [Lab 07](./labs/lab07.md) |
| 08 | **Configuration & storage** | ConfigMaps, Secrets (and why base64 isn't encryption), volumes, PV/PVC/StorageClass, StatefulSets, databases on Kubernetes | [PDF](./decks/session-08.pdf) | [Lab 08](./labs/lab08.md) |
| 09 | **Operating Kubernetes** | A troubleshooting method, `kubectl debug`, metrics-server, HPA v2, PDB, quotas, RBAC basics, securityContext & Pod Security Admission | [PDF](./decks/session-09.pdf) | [Lab 09](./labs/lab09.md) |
| 10 | **Capstone: ship Pinboard like production** | The production-ready checklist, Helm & Kustomize at a glance, GitOps, managed Kubernetes, what to learn next | [PDF](./decks/session-10.pdf) | [Lab 10](./labs/lab10.md) |

---

## Getting started

**Before Session 01** — about 20 minutes:

1. Get a Linux machine you have `sudo` on: Ubuntu 22.04/24.04 or Debian 12, `amd64` or `arm64`,
   2 CPUs (4 recommended), 8 GB RAM, 20 GB free disk. *Received an Azure lab VM from the
   instructor? Everything is pre-installed — jump to Step 10 of the setup guide.*
2. Clone this repository to the path every lab uses:

   ```bash
   git clone https://github.com/zonoth/docker-kubernetes-training.git ~/docker-kubernetes-training
   ```

3. Install the toolchain — Docker Engine 28+ (with Compose v2 and Buildx), kubectl, kind and
   helm — either step by step with [**Lab 00 – Course setup**](./labs/lab00-setup.md), or in one go:

   ```bash
   bash ~/docker-kubernetes-training/labs/setup.sh
   ```

4. Run the verification block at the end of Lab 00. If every tool prints a version, you're ready.

**During the course** — work each lab in its own folder, `~/pinboard-labs/labNN/`. Every lab
starts exactly where the previous one ended (its *Pre-requisites* section says what you should
have), so finish them in order; if you fall behind, catch up before the next session.

## Labs

| Lab | Session | What you'll do |
|-----|:-------:|----------------|
| [Lab 00 — Course setup](./labs/lab00-setup.md) | pre-work | Install Docker Engine, kubectl, kind and helm; clone the repo; verify the toolchain. |
| [Lab 01 — Run the Pinboard database tier](./labs/lab01.md) | 01 | Run PostgreSQL in a container, create the `notes` table, inspect/stop/start/remove it — and watch the data vanish. |
| [Lab 02 — Build the Pinboard images](./labs/lab02.md) | 02 | A naive Dockerfile, then the real multi-stage distroless one; build `1.0`, `1.1`, `1.2-broken` and the web image. |
| [Lab 03 — Wire Pinboard together by hand](./labs/lab03.md) | 03 | Network + volume, three containers finding each other by name, data that survives a DB restart, limits and health. |
| [Lab 04 — Pinboard in one file](./labs/lab04.md) | 04 | `compose.yaml` with healthchecks and `depends_on`, `.env`, `up --wait`, `watch`, `--scale`. |
| [Lab 05 — Pinboard meets Kubernetes](./labs/lab05.md) | 05 | Create the kind cluster, load the images, run the API as a Pod imperatively and from YAML, fix a broken Pod. |
| [Lab 06 — Make Pinboard API resilient](./labs/lab06.md) | 06 | A Deployment with probes and resources; roll 1.0 → 1.1 without errors, roll out a broken image and undo it. |
| [Lab 07 — Expose Pinboard](./labs/lab07.md) | 07 | ClusterIP Services, DNS from a debug Pod, the web tier, ingress-nginx and an Ingress on <http://localhost>. |
| [Lab 08 — Give Pinboard a real database](./labs/lab08.md) | 08 | Secret + ConfigMap, a PostgreSQL StatefulSet with a dynamically provisioned PVC, notes that survive a Pod deletion. |
| [Lab 09 — Operate Pinboard](./labs/lab09.md) | 09 | metrics-server, HPA under load, three break/fix drills with `kubectl debug`, a PDB and a node drain, Pod Security Admission. |
| [Lab 10 — Capstone](./labs/lab10.md) | 10 | Deploy the whole stack into `pinboard-prod` from a blank folder against the [checklist](./labs/capstone/CHECKLIST.md); [`verify.sh`](./labs/capstone/verify.sh) grades it. |

## The sample app — Pinboard

```
browser ──► pinboard-web (nginx :8080) ──/api/*──► pinboard-api (Go :8080) ──► postgres (:5432)
```

You never have to write Go: the app is small, configured entirely through environment
variables, and has a few built-in switches (`CRASH_ON_START`, `FAIL_READY_AFTER`,
`/api/burn`) that let the labs break it on purpose. Its full reference — endpoints,
variables, images — is in [`src/README.md`](./src/README.md).

Want to see it running before the course starts?

```bash
cd ~/docker-kubernetes-training/src
docker compose up -d --wait      # builds the images and starts db, api and web
# open http://localhost:8080
docker compose down -v           # stop and remove everything, data included
```

## Slides

The slides of every session are in [`decks/`](./decks/) as PDF (16:9, one page per slide):
[01](./decks/session-01.pdf) ·
[02](./decks/session-02.pdf) ·
[03](./decks/session-03.pdf) ·
[04](./decks/session-04.pdf) ·
[05](./decks/session-05.pdf) ·
[06](./decks/session-06.pdf) ·
[07](./decks/session-07.pdf) ·
[08](./decks/session-08.pdf) ·
[09](./decks/session-09.pdf) ·
[10](./decks/session-10.pdf).

## Repository structure

```
.
├── decks/                 Session slides as PDF (session-01.pdf … session-10.pdf)
├── labs/
│   ├── lab00-setup.md     Course setup — do it before Session 01
│   ├── lab01.md … lab10.md
│   ├── setup.sh           One-shot install of the toolchain (Debian/Ubuntu, amd64/arm64)
│   ├── kind-config.yaml   The 3-node kind cluster used from Lab 05 on (ports 80/443 → localhost)
│   └── capstone/          Lab 10 checklist + verify.sh scorecard
└── src/                   The Pinboard sample app
    ├── pinboard-api/      Go API — multi-stage, distroless, non-root image
    ├── pinboard-web/      Static UI on nginx, proxies /api/ to the API
    ├── db/init.sql        Optional PostgreSQL bootstrap
    └── compose.yaml       The whole stack with Docker Compose
```

## Getting help

- Every lab shows the **expected output** of each command — compare yours line by line first.
- From Session 09 on you have a method for this: `get` → `describe` → `logs` → `events` → `debug`. Use it on your own mistakes; that is the point.
- Still stuck? Ask the instructor — at the next session or on the course's communication channel — and include the lab step, the command and its full output.

## About

This course is designed and delivered by **Zonoth** (zonoth.tech) — cloud, Infrastructure as
Code and AI training and consultancy. Found a mistake in a lab or a slide? Open an issue
describing what you hit and where.

<div align="center">

**Zonoth** • Containers & Kubernetes Fundamentals

</div>
