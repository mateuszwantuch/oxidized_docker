# Oxidized — Offline Install on Rocky Linux 9.8 (Podman) with nginx Authentication

A step-by-step runbook for deploying **Oxidized** in a container on an **air-gapped Rocky Linux 9.8** machine (Podman only), fronted by an **nginx reverse proxy with username/password authentication**, and migrating data from an existing **bare-metal** Oxidized instance.

## Overview

- **Online machine** — Rocky 9.8 with internet. Used only to download the container images and export them to tarballs.
- **Offline machine** — Rocky 9.8, air-gapped, Podman already installed, nothing else.
- **Auth** — Oxidized's web UI has *no* built-in login. We put an nginx reverse proxy in front of it for HTTP Basic Auth. Oxidized itself is reachable only on a private container network.
- **Migration** — copy the existing bare-metal instance's `config`, `router.db` (CSV source) and the bare git repo (output/history) into the new instance.

> **Note:** The `username`/`password` fields inside Oxidized's own config are the credentials Oxidized uses to **log into your network devices** — they are *not* web-UI logins. Web-UI authentication is provided entirely by the nginx proxy (Part 6).

## Architecture

```
            user ─HTTP(8888)─► [ nginx proxy ]  (Basic Auth)
                                     │  http://oxidized:8888
                                     ▼
                               [ oxidized ]      (private podman network, no host port)
                                     │
                                     ▼
                          ~/oxidized/config  (config, router.db, oxidized.git)
```

---

# Part 1 — Prepare images on the ONLINE machine

### 1.1 Install Podman (skip if Docker is present — commands are identical, swap `podman`→`docker`)
```bash
sudo dnf install -y podman
```

### 1.2 Pull both images
```bash
podman pull docker.io/oxidized/oxidized:latest
podman pull docker.io/library/nginx:alpine
```

> For a reproducible offline box, record the digests so you can pull the exact same image again later:
> ```bash
> podman images --digests | grep -E 'oxidized|nginx'
> ```

### 1.3 Export images to tarballs
```bash
podman save docker.io/oxidized/oxidized:latest | gzip > oxidized-image.tar.gz
podman save docker.io/library/nginx:alpine     | gzip > nginx-image.tar.gz

sha256sum oxidized-image.tar.gz nginx-image.tar.gz   # record these
ls -lh *.tar.gz
```

> **Architecture check:** run `uname -m` on both machines — they must match (almost certainly `x86_64`).

---

# Part 2 — Transfer to the OFFLINE machine

Move both `.tar.gz` files across the air gap (USB, scp over isolated link, etc.), then on the offline machine:

```bash
# verify integrity (must match Part 1.3)
sha256sum oxidized-image.tar.gz nginx-image.tar.gz

# load both images
gunzip -c oxidized-image.tar.gz | podman load
gunzip -c nginx-image.tar.gz    | podman load

podman images | grep -E 'oxidized|nginx'   # confirm both present
```

---

# Part 3 — First run / smoke test (OFFLINE machine)

Run **rootless** (as a normal user, not root). Ports above 1024 work fine rootless.

### 3.1 Create the config directory
```bash
mkdir -p ~/oxidized/config
```

### 3.2 Determine the container's runtime user (needed for permissions)
```bash
podman run --rm --entrypoint sh docker.io/oxidized/oxidized:latest \
  -c 'id; echo "HOME=$HOME"'
```
- **uid=0 (root)** → under rootless Podman this maps to *your* host user; files you create work as-is.
- **non-root uid** (e.g. 1000) → note it; you'll run a `podman unshare chown` step later.

The printed `HOME` is the config mount path. This guide assumes **`/home/oxidized/.config/oxidized`**. If it printed something else (older images used `/root/.config/oxidized`), substitute that path everywhere below.

### 3.3 Starter config (skip if you are migrating — see Part 5)
Create `~/oxidized/config/config`:
```yaml
---
username: admin
password: admin
model: ios
resolve_dns: true
interval: 3600
use_syslog: false
debug: false
threads: 30
timeout: 20
retries: 3
prompt: !ruby/regexp /^([\w.@-]+[#>]\s?)$/
rest: 0.0.0.0:8888          # MUST be 0.0.0.0 to be reachable from the proxy

input:
  default: ssh, telnet
  ssh:
    secure: false

output:
  default: git
  git:
    user: Oxidized
    email: oxidized@example.com
    repo: "/home/oxidized/.config/oxidized/oxidized.git"

source:
  default: csv
  csv:
    file: "/home/oxidized/.config/oxidized/router.db"
    delimiter: !ruby/regexp /:/
    map:
      name: 0
      model: 1
      username: 2
      password: 3
```

Create `~/oxidized/config/router.db` (one device per line):
```
router1.example.com:ios:user:pass
switch1.example.com:ios:user:pass
```

### 3.4 Test in the foreground
```bash
podman run --rm -it \
  -v ~/oxidized/config:/home/oxidized/.config/oxidized:Z \
  -p 8888:8888 \
  docker.io/oxidized/oxidized:latest
```
- The **`:Z`** suffix relabels the volume for SELinux (enforcing by default on Rocky). Omitting it causes phantom "permission denied" errors.
- Browse to `http://<offline-host>:8888/`. Confirm it polls devices and the UI loads, then `Ctrl-C`.

### 3.5 Permissions fix (only if 3.2 showed a non-root uid)
```bash
podman unshare chown -R 1000:1000 ~/oxidized/config   # use the uid from 3.2
```

---

# Part 4 — Run Oxidized as a service (Quadlet + systemd, rootless)

> The port published here is **temporary** for testing. Part 6 removes it so only the nginx proxy is exposed. If you are going straight to authenticated setup, you can skip ahead and let Part 6.4 define the final unit.

Create `~/.config/containers/systemd/oxidized.container`:
```ini
[Unit]
Description=Oxidized network config backup
After=network-online.target

[Container]
Image=docker.io/oxidized/oxidized:latest
ContainerName=oxidized
PublishPort=8888:8888
Volume=%h/oxidized/config:/home/oxidized/.config/oxidized:Z
AutoUpdate=disabled

[Service]
Restart=always

[Install]
WantedBy=default.target
```

Enable boot-time start (lingering) and launch:
```bash
loginctl enable-linger $USER
systemctl --user daemon-reload
systemctl --user start oxidized.service
systemctl --user status oxidized.service
journalctl --user -u oxidized.service -f      # watch logs
```
Restart after config changes: `systemctl --user restart oxidized.service`

---

# Part 5 — Migrate data from the existing BARE-METAL instance

The data to move lives together in Oxidized's config dir:
1. `config` — main config file
2. `router.db` — CSV device list (source)
3. the bare git repo (e.g. `oxidized.git`) — accumulated config history (output)

### 5.1 Locate the data on the old machine
```bash
# which user does the daemon run as?
systemctl cat oxidized 2>/dev/null | grep -iE 'User=|ExecStart='
ps -ef | grep -i oxidized | grep -v grep
```
Common locations: `/home/oxidized/.config/oxidized/`, `/var/lib/oxidized/.config/oxidized/`, or `~/.config/oxidized/`.

Read the authoritative paths from the old config:
```bash
grep -E 'repo:|file:' /home/oxidized/.config/oxidized/config
ls -la /home/oxidized/.config/oxidized/   # expect: config, router.db, *.git/
```

### 5.2 Stop the old daemon and archive (consistent snapshot)
```bash
sudo systemctl stop oxidized            # or however it is managed
cd /home/oxidized/.config               # the dir CONTAINING oxidized/
sudo tar czf /tmp/oxidized-data.tgz oxidized/
sha256sum /tmp/oxidized-data.tgz
```
> Use `tar`, not `git clone` — it preserves the bare repo's full history, refs and packed objects exactly. Treat the `.git` repo as opaque files.

### 5.3 Transfer `oxidized-data.tgz` across the air gap (same method as Part 2).

### 5.4 Restore into the new instance (OFFLINE machine)
```bash
systemctl --user stop oxidized.service 2>/dev/null

sha256sum oxidized-data.tgz             # confirm match
mkdir -p ~/tmp-restore
tar xzf oxidized-data.tgz -C ~/tmp-restore
cp -a ~/tmp-restore/oxidized/. ~/oxidized/config/
ls -la ~/oxidized/config/               # expect: config, router.db, oxidized.git/
```

### 5.5 Rewrite paths in the migrated config (MANDATORY for bare-metal source)
Bare-metal configs use absolute, machine-specific paths that don't exist in the container. Edit `~/oxidized/config/config`:
```yaml
output:
  git:
    repo: "/home/oxidized/.config/oxidized/oxidized.git"   # match your actual repo dir name

source:
  csv:
    file: "/home/oxidized/.config/oxidized/router.db"

rest: 0.0.0.0:8888    # ensure this is 0.0.0.0 (old one may bind 127.0.0.1)
```
- Leave any `!ruby/regexp` tags (in `prompt:` / `delimiter:`) intact — the containerized Oxidized parses them identically.
- If the config references an SSH key file, copy that key into `~/oxidized/config/` and update its path to the container path.

### 5.6 Fix ownership (only if 3.2 showed a non-root uid)
```bash
podman unshare chown -R 1000:1000 ~/oxidized/config   # use the uid from 3.2
```

### 5.7 Start and verify
```bash
systemctl --user start oxidized.service
journalctl --user -u oxidized.service -f
```
In the web UI, open a device and check its version/diff history — migrated git history confirms the bare repo came over intact. Confirm the device list matches the old `router.db`. You can then decommission the bare-metal instance.

---

# Part 6 — Expose with username/password via nginx (authentication)

This adds the auth proxy and makes nginx the **only** thing published to the host.

### 6.1 nginx image
Already loaded in Part 2. Confirm: `podman images | grep nginx`.

### 6.2 Create proxy config and password file
```bash
mkdir -p ~/oxidized/nginx
```

**Password file** (uses `openssl`, since `htpasswd` isn't available offline):
```bash
# one printf per user; it prompts for the password twice
printf "alice:%s\n" "$(openssl passwd -apr1)" >> ~/oxidized/nginx/.htpasswd
printf "bob:%s\n"   "$(openssl passwd -apr1)" >> ~/oxidized/nginx/.htpasswd

cat ~/oxidized/nginx/.htpasswd          # sanity check: user:$apr1$...
```

**Proxy server block** — create `~/oxidized/nginx/default.conf`:
```nginx
server {
    listen 8888;

    location / {
        auth_basic           "Oxidized - authorized users only";
        auth_basic_user_file /etc/nginx/.htpasswd;

        proxy_pass         http://oxidized:8888;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
}
```

### 6.3 Create the private network (Quadlet)
Create `~/.config/containers/systemd/oxidized.network`:
```ini
[Network]
NetworkName=oxidized-net
```

### 6.4 Update the Oxidized Quadlet — remove the host port, join the network
Replace `~/.config/containers/systemd/oxidized.container` with:
```ini
[Unit]
Description=Oxidized network config backup
After=network-online.target

[Container]
Image=docker.io/oxidized/oxidized:latest
ContainerName=oxidized
Network=oxidized.network
Volume=%h/oxidized/config:/home/oxidized/.config/oxidized:Z
AutoUpdate=disabled

[Service]
Restart=always

[Install]
WantedBy=default.target
```

### 6.5 Create the nginx Quadlet
Create `~/.config/containers/systemd/oxidized-proxy.container`:
```ini
[Unit]
Description=nginx auth proxy for Oxidized
After=oxidized.service
Requires=oxidized.service

[Container]
Image=docker.io/library/nginx:alpine
ContainerName=oxidized-proxy
Network=oxidized.network
PublishPort=8888:8888
Volume=%h/oxidized/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro,Z
Volume=%h/oxidized/nginx/.htpasswd:/etc/nginx/.htpasswd:ro,Z

[Service]
Restart=always

[Install]
WantedBy=default.target
```

### 6.6 Launch
```bash
loginctl enable-linger $USER            # if not already done
systemctl --user daemon-reload
systemctl --user start oxidized-proxy.service   # pulls in oxidized.service via Requires=
systemctl --user status oxidized.service oxidized-proxy.service
```

Browse to `http://<offline-host>:8888/` → you now get a username/password prompt, and only the users in `.htpasswd` reach Oxidized.

---

# Security notes

- **HTTP Basic Auth is cleartext** (Base64) on every request. On a trusted management network this is often accepted, but adding **TLS** (self-signed or internal-CA cert on the nginx container, listen on 443, redirect 80→443) is strongly recommended.
- **Only nginx is published.** Never add a `PublishPort` to the Oxidized container — the proxy must be the only door.
- `X-Forwarded-*` headers are set so Oxidized logs the real client IP, not the proxy's.

# Upgrades (offline)

`AutoUpdate=disabled` is intentional. To upgrade an image later: repeat Parts 1–2 with the new tag on the online machine, `podman load` on the offline machine, then `systemctl --user restart <service>`.

# Quick reference — file layout on the offline machine

```
~/oxidized/
├── config/                 # mounted into the oxidized container
│   ├── config              # main Oxidized config
│   ├── router.db           # CSV device list
│   └── oxidized.git/       # bare git repo (config history)
└── nginx/
    ├── default.conf        # reverse-proxy + basic auth
    └── .htpasswd           # user:hash entries

~/.config/containers/systemd/
├── oxidized.network        # private container network
├── oxidized.container      # Oxidized service (no host port)
└── oxidized-proxy.container# nginx auth proxy (publishes 8888)
```

# Common gotchas

- **SELinux + volumes** → always use `:Z` on mounts. #1 cause of "permission denied".
- **`rest: 0.0.0.0:8888`** required — `127.0.0.1` is unreachable from the proxy container.
- **Bare git repo is opaque** → move with `tar`, never reconstruct.
- **uid mapping** → resolve once via the Part 3.2 check + `podman unshare chown`.
- **Lingering** → `loginctl enable-linger $USER` so rootless services start at boot without an active login session.
