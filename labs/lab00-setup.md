# Lab 00 – Course setup (before Session 01)

## Table of Contents

- [Goals](#goals)
- [Pre-requisites](#pre-requisites)
- [Guide](#guide)
  - [Step 01: Check the lab machine](#step-01-check-the-lab-machine)
  - [Step 02: Clone the course repository](#step-02-clone-the-course-repository)
  - [Step 03: The fast path — `labs/setup.sh`](#step-03-the-fast-path--labssetupsh)
  - [Step 04: Install Docker Engine 28+](#step-04-install-docker-engine-28)
  - [Step 05: Run Docker without `sudo`](#step-05-run-docker-without-sudo)
  - [Step 06: Install kubectl](#step-06-install-kubectl)
  - [Step 07: Install kind](#step-07-install-kind)
  - [Step 08: Install helm (and k9s)](#step-08-install-helm-and-k9s)
  - [Step 09: Install VS Code and the extensions (optional)](#step-09-install-vs-code-and-the-extensions-optional)
  - [Step 10: Verify everything](#step-10-verify-everything)
- [Stretch goal](#stretch-goal)
- [Conclusion](#conclusion)

## Goals

- Get a Linux lab machine ready for all ten sessions: Docker Engine 28+, kubectl, kind, helm.
- Run Docker as your normal user, without `sudo`.
- Clone the course repository so every lab can reference `~/docker-kubernetes-training/src/...`.
- Know the one command that re-runs the whole install (`labs/setup.sh`) if your machine is rebuilt.
- Verify the toolchain with a single block of commands, so Session 01 starts with everyone working.

## Pre-requisites

- A Linux machine you have `sudo` on: **Ubuntu 22.04 / 24.04** (or Debian 12, or any
  close derivative). A VM is fine; WSL2 works but is not what the instructor tests on.
- **x86-64 (`amd64`) or ARM64 (`arm64`)**, 2 CPUs minimum (4 recommended), 8 GB RAM,
  and **20 GB of free disk** — the kind cluster and the course images need room.
- Outbound HTTPS to `download.docker.com`, `pkgs.k8s.io`, `github.com`,
  `registry.k8s.io` and `docker.io`. If your network filters these, tell the
  instructor **before** Session 01 — there is an offline image bundle.
- About 20 minutes, and a coffee while apt does its thing.

> **Continuity.** This is where the Pinboard project starts. Nothing is built yet:
> this lab only prepares the machine and puts the course sources on disk at
> `~/docker-kubernetes-training`. From Lab 01 onwards you build the Pinboard
> application — database, API and web — one layer at a time, and every later lab
> assumes the tools installed here.

## Guide

### Step 01: Check the lab machine

> **Did you receive an Azure lab VM from the instructor?** Then everything in this
> lab is already installed. Connect with the SSH line you were sent
> (`ssh student@<prefix>-<you>.westeurope.cloudapp.azure.com` + password), read the
> login banner — it must say `status : READY` — and jump straight to
> [Step 02](#step-02-clone-the-course-repository) to confirm the repo is there, then
> [Step 10](#step-10-verify-everything). Two things differ on a remote VM:
>
> - Wherever a lab says "open <http://localhost:8080>", either forward the port when
>   you connect — `ssh -L 8080:localhost:8080 -L 80:localhost:80 student@<host>` — and
>   open it on your laptop, or use the VM's public name directly:
>   `http://<prefix>-<you>.westeurope.cloudapp.azure.com:8080` (port 80 works from Lab 07 on).
> - The VM shuts down every evening at 21:00 (Lisbon). Ask the instructor to start it
>   if you want to work late.
>
> If the banner says `RUNNING: …`, wait a few minutes; if it says `FAILED: …`, tell the
> instructor (they can re-run `sudo /usr/local/sbin/lab-setup.sh`).

Confirm the distribution and the architecture. Every command in this course is
Linux/bash; the architecture matters because kind and k9s are downloaded as
release binaries.

```bash
cat /etc/os-release | head -3
dpkg --print-architecture
free -h | head -2
df -h /var/lib | tail -1
```

```text
PRETTY_NAME="Ubuntu 24.04.3 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
amd64
               total        used        free      shared  buff/cache   available
Mem:            15Gi       1.2Gi        12Gi        12Mi       2.1Gi        14Gi
/dev/sda1        79G        12G        64G  16% /
```

Install the handful of base packages the rest of this lab needs:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git jq
```

> **Note.** `docker` also exists in Ubuntu's own repositories as `docker.io`. Do
> **not** use it: it lags several minor versions behind, and this course needs
> Docker Engine 28+ with the Compose v2 and Buildx plugins. Steps 03/04 install
> the packages from Docker's official repository instead.

### Step 02: Clone the course repository

Every lab refers to files under `~/docker-kubernetes-training/src/...`, so clone it
into your home directory with exactly that name.

```bash
git clone https://github.com/zonoth/docker-kubernetes-training.git ~/docker-kubernetes-training
```

```text
Cloning into '/home/student/docker-kubernetes-training'...
remote: Enumerating objects: 412, done.
remote: Counting objects: 100% (412/412), done.
remote: Compressing objects: 100% (238/238), done.
Receiving objects: 100% (412/412), 1.84 MiB | 6.10 MiB/s, done.
Resolving deltas: 100% (121/121), done.
```

> **Note.** The URL above is a placeholder. **The instructor gives you the real
> clone URL** (it may be a different host, or an HTTPS URL with a token) at the
> start of Session 01 — use that one and keep the target folder name
> `~/docker-kubernetes-training`.

Have a quick look at what you just cloned:

```bash
ls ~/docker-kubernetes-training
```

```text
README.md  decks  demos  docs  labs  landing  slides  src
```

### Step 03: The fast path — `labs/setup.sh`

The repository ships a script that performs **everything** in Steps 04 to 09 on
Debian/Ubuntu. It is idempotent — safe to run again after a failure, after a
partial install, or on a rebuilt machine.

```bash
bash ~/docker-kubernetes-training/labs/setup.sh
```

```text
==> Lab machine setup
    distribution : Ubuntu 24.04.3 LTS  (ubuntu/noble)
    architecture : amd64
    user         : student
    options      : k9s=yes vscode=no kubectl=v1.37 kind=v0.33.0 helm=4

==> 1/7 Base packages (git, curl, jq, …)
==> 2/7 Docker Engine
    adding Docker's GPG key
    writing /etc/apt/sources.list.d/docker.list
    adding student to the 'docker' group
==> 3/7 kubectl (v1.37 stable channel)
==> 4/7 kind v0.33.0
    installing kind v0.33.0 (linux/amd64)
==> 5/7 helm 4
    running the official get-helm-4 script
==> 6/7 k9s (optional)
    installing k9s v0.50.9 (Linux_x86_64)
==> 7/7 Visual Studio Code (optional)
    skipped (set INSTALL_VSCODE=yes to install it)

==> Installed versions
Docker version 28.3.2, build 578ccf6
Docker Compose version v2.39.1
github.com/docker/buildx v0.26.1
  gitVersion: v1.37.1
  kustomizeVersion: v5.8.1
kind v0.33.0 go1.26.7 linux/amd64
v4.3.1+gc0d08d0
git version 2.43.0

==> Done
    student was added to the 'docker' group. Group membership is only
    picked up by NEW logins, so do one of these before running docker commands:

        newgrp docker      # applies to the current shell only
        # or log out and back in (best), or reboot the VM

    Next: verify with 'docker run --rm hello-world', then open labs/lab01.md
```

Two switches are available if you want them:

```bash
INSTALL_VSCODE=yes bash ~/docker-kubernetes-training/labs/setup.sh   # also install VS Code + extensions
INSTALL_K9S=no     bash ~/docker-kubernetes-training/labs/setup.sh   # skip k9s
```

> **Warning.** Run the script as **your own user**, not with `sudo bash setup.sh`.
> It calls `sudo` itself where it needs root, and it must know your real user name
> to add it to the `docker` group.

If the script finished without errors, **jump to [Step 10](#step-10-verify-everything)**
(after `newgrp docker` or a re-login). Steps 04–09 below are the same install done
by hand — read them anyway if you like to know what a script is doing to your machine,
and use them if the script fails on your distribution.

### Step 04: Install Docker Engine 28+

Add Docker's official apt repository, then install the engine plus the CLI plugins.
`docker-buildx-plugin` gives you BuildKit features used in Session 02;
`docker-compose-plugin` gives you `docker compose` (v2, no hyphen) used in Session 04.

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

```text
Setting up containerd.io (1.7.28-1) ...
Setting up docker-ce-cli (5:28.3.2-1~ubuntu.24.04~noble) ...
Setting up docker-buildx-plugin (0.26.1-1~ubuntu.24.04~noble) ...
Setting up docker-compose-plugin (2.39.1-1~ubuntu.24.04~noble) ...
Setting up docker-ce (5:28.3.2-1~ubuntu.24.04~noble) ...
Created symlink /etc/systemd/system/multi-user.target.wants/docker.service → /usr/lib/systemd/system/docker.service.
```

> **Note.** On **Debian** replace both occurrences of `ubuntu` in the URLs with
> `debian`. The `$(. /etc/os-release && …)` part resolves your codename
> (`noble`, `jammy`, `bookworm`, …) automatically.

The engine should already be running under systemd:

```bash
sudo systemctl enable --now docker
systemctl is-active docker
```

```text
active
```

### Step 05: Run Docker without `sudo`

The Docker CLI talks to `dockerd` over the socket `/var/run/docker.sock`, which is
owned by `root:docker`. Adding yourself to the `docker` group means you never type
`sudo docker` in this course.

```bash
sudo usermod -aG docker $USER
newgrp docker           # apply the new group to THIS shell (or log out and back in)
```

> **Warning.** Membership of the `docker` group is equivalent to root on the host —
> anyone in it can start a privileged container that mounts `/`. That is fine on a
> disposable lab VM; on a shared or production machine, prefer rootless Docker or
> `sudo`. We call this out again in Session 09 (security basics).

Check it works and that you get the same answer as root:

```bash
docker run --rm hello-world
```

```text
Unable to find image 'hello-world:latest' locally
latest: Pulling from library/hello-world
17eec7bbc9d7: Pull complete
Digest: sha256:940c619fbd418f9b2b1b63e25d8861f9cc1b46e3fc8b018ccfe8b78f19b8cc4f
Status: Downloaded newer image for hello-world:latest

Hello from Docker!
This message shows that your installation appears to be working correctly.
...
```

If you get `permission denied while trying to connect to the Docker daemon socket`,
your shell has not picked up the new group: run `newgrp docker`, or log out and back in.

### Step 06: Install kubectl

`kubectl` comes from the community package host `pkgs.k8s.io`, which is versioned
per **minor** release — you subscribe to a channel, here `v1.37` (the version our
kind cluster runs from Session 05 on). Keep the client within one minor version of
the cluster.

```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.37/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

sudo apt-get update
sudo apt-get install -y kubectl
```

```bash
kubectl version --client
```

```text
Client Version: v1.37.1
Kustomize Version: v5.8.1
```

> **Note.** There is no cluster yet, so plain `kubectl version` will end with
> `connection refused` — that is expected until Lab 05 creates the kind cluster.

### Step 07: Install kind

kind (**K**ubernetes **in** **D**ocker) runs a real Kubernetes cluster inside Docker
containers — one container per node. It is distributed as a single static binary
from GitHub Releases. We pin the release: each kind version runs a specific Kubernetes
version by default (v0.33.0 → Kubernetes 1.37), and kubectl must stay within one minor
version of it.

```bash
KIND_VERSION=v0.33.0
echo "installing kind ${KIND_VERSION} for linux/$(dpkg --print-architecture)"
curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-$(dpkg --print-architecture)"
sudo install -m 0755 /tmp/kind /usr/local/bin/kind && rm /tmp/kind
kind version
```

```text
installing kind v0.33.0 for linux/amd64
kind v0.33.0 go1.26.7 linux/amd64
```

Do **not** create a cluster yet — Lab 05 does that with `labs/kind-config.yaml`,
which adds the port mappings the Ingress lab needs.

### Step 08: Install helm (and k9s)

Helm is used in Session 10 (installing a chart and packaging Pinboard).
Its official installer script picks the right binary for your architecture.

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | sudo bash
helm version --short
```

```text
Downloading https://get.helm.sh/helm-v4.3.1-linux-amd64.tar.gz
Verifying checksum... Done.
Preparing to install helm into /usr/local/bin
helm installed into /usr/local/bin/helm
v4.3.1+gc0d08d0
```

**k9s (optional but recommended)** — a terminal UI for Kubernetes. We use it in
Session 09 instead of the retired Kubernetes Dashboard.

```bash
K9S_VERSION=$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest | jq -r .tag_name)
ARCH=$([ "$(dpkg --print-architecture)" = "amd64" ] && echo x86_64 || echo arm64)
curl -fsSL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${ARCH}.tar.gz" \
  | tar -xz -C /tmp k9s
sudo install -m 0755 /tmp/k9s /usr/local/bin/k9s && rm /tmp/k9s
k9s version -s
```

```text
Version:    v0.50.9
Commit:     2a5c2a8f0d6d6bd8c1b0e3b6d3d24f9b9a3a3f21
Date:       2026-05-14T09:12:44Z
```

### Step 09: Install VS Code and the extensions (optional)

Any editor works — if you are happy in vim or nano, skip this step. VS Code is what
the instructor demos with, and the Kubernetes extension makes YAML far less painful.

```bash
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
  | sudo gpg --dearmor -o /etc/apt/keyrings/packages.microsoft.gpg
sudo chmod a+r /etc/apt/keyrings/packages.microsoft.gpg

echo "deb [arch=amd64,arm64 signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
  | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null

sudo apt-get update
sudo apt-get install -y code
```

Then add the three extensions used through the course:

```bash
code --install-extension ms-azuretools.vscode-docker
code --install-extension ms-kubernetes-tools.vscode-kubernetes-tools
code --install-extension redhat.vscode-yaml
```

```text
Installing extensions...
Extension 'ms-azuretools.vscode-docker' v2.0.0 was successfully installed.
Extension 'ms-kubernetes-tools.vscode-kubernetes-tools' v1.3.28 was successfully installed.
Extension 'redhat.vscode-yaml' v1.18.0 was successfully installed.
```

Open the course repo with `code ~/docker-kubernetes-training`.

### Step 10: Verify everything

Run this block as-is. Every line must print a version; nothing should say
`command not found` or `permission denied`.

```bash
docker --version
docker compose version
docker buildx version
kubectl version --client
kind version
helm version --short
git --version
docker run --rm hello-world | head -2
docker info --format 'Server {{.ServerVersion}} · runtime {{.DefaultRuntime}} · storage {{.Driver}} · cgroups v{{.CgroupVersion}}'
```

```text
Docker version 28.3.2, build 578ccf6
Docker Compose version v2.39.1
github.com/docker/buildx v0.26.1 fa0e0e5b1d2b3c9e0f2a1e0b0f9a2f36f5f0b1a2
Client Version: v1.37.1
Kustomize Version: v5.8.1
kind v0.33.0 go1.26.7 linux/amd64
v4.3.1+gc0d08d0
git version 2.43.0

Hello from Docker!
Server 28.3.2 · runtime runc · storage overlay2 · cgroups v2
```

The last line is worth a look: the CLI you type talks to **dockerd 28.3.2**, which
delegates to **containerd** and finally **runc**, on an **overlay2** union
filesystem with **cgroup v2** limits. Session 01 explains every word of that
sentence — you now have the machine that proves it.

> **Note (Docker Hub account — optional).** Everything in this course builds
> locally and, from Session 05, is loaded into kind with `kind load docker-image`;
> no registry is required. **Only the last, optional step of Lab 02** pushes an
> image to Docker Hub. If you want to do it, create a free account at
> <https://hub.docker.com> now and remember your Docker ID — you will run
> `docker login` in that step.

<details>
<summary><strong>Check yourself:</strong> you ran <code>sudo usermod -aG docker $USER</code> but <code>docker ps</code> still says "permission denied". Why?</summary>

Group membership is evaluated when a **login session** is created, not when the
`/etc/group` file changes. Your current shell still carries the old group set (check
with `id -nG`). Fix it with `newgrp docker` for this shell, or log out and back in
(or reboot the VM) for every shell. Using `sudo docker ps` would also work, but then
the images you build as root are invisible to your user later — don't mix the two.
</details>

## Stretch goal

- **Shell completion.** Add it once and enjoy it for ten sessions:

  ```bash
  echo 'source <(kubectl completion bash)' >> ~/.bashrc
  echo 'alias k=kubectl; complete -o default -F __start_kubectl k' >> ~/.bashrc
  echo 'source <(kind completion bash)' >> ~/.bashrc
  echo 'source <(helm completion bash)' >> ~/.bashrc
  source ~/.bashrc
  ```

- **Warm the image cache.** The lab network is slowest when 15 students pull at
  once. Pre-pull the images the first three labs need:

  ```bash
  docker pull postgres:17-alpine
  docker pull nginx:1.28-alpine
  docker pull alpine:3.22
  docker pull busybox:1.37
  docker pull golang:1.25-alpine
  docker pull gcr.io/distroless/static-debian12:nonroot
  docker image ls
  ```

- **Read the app you are about to containerise.** Skim
  `~/docker-kubernetes-training/src/README.md` — one page describing the Pinboard
  API endpoints and its environment variables. You never have to write Go, but
  knowing that `DATABASE_URL` switches the store from memory to Postgres will make
  Labs 01–04 click much faster.

## Conclusion

**What you have now**

- Docker Engine 28+ with the Buildx and Compose v2 plugins, usable without `sudo`.
- kubectl v1.37, kind v0.33 (Kubernetes 1.37), and helm 4 on your `PATH` (plus k9s and VS Code if you took
  the optional steps).
- The course repository at `~/docker-kubernetes-training`, containing the Pinboard
  sources (`src/`), all labs (`labs/`) and the decks (`decks/`).
- A one-command way to rebuild this machine: `bash ~/docker-kubernetes-training/labs/setup.sh`.

**Nothing to clean up** — no containers were left running (`hello-world` used
`--rm`). Keep the images you pulled; the next labs reuse them.

If something here failed, fix it **before** Session 01 rather than during it: the
labs build on each other and there is no time budget for installs.

Next: **[Lab 01 – Run the Pinboard database tier](lab01.md)**.
