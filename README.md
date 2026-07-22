# server-management

Everything needed to stand up a small monitored fleet: a control plane running
Prometheus, Loki, Grafana and Splunk, and any number of managed hosts running
the agents that feed it.

The two halves live in their own repos, included here as submodules:

| Submodule | Repo | What it is |
| --- | --- | --- |
| `control-server/` | control-server-deployment | The control plane. Docker Compose stack behind an nginx reverse proxy. |
| `non-master-node/` | telegraf-setup-playbook | The Ansible playbooks that configure managed hosts *and* bring the control plane up. |

## Quick start

Clone with submodules, point the inventory at your hosts, run the playbooks:

```bash
git clone --recurse-submodules <this repo>
cd server-management

# 1. provision the VMs however you like and record them in the inventory
cd non-master-node
$EDITOR inventories/stg/hosts.ini                    # host names and addresses

# 2. fill in that environment's configuration and secrets
ansible-galaxy collection install -r requirements.yml
$EDITOR inventories/stg/group_vars/all/arch.yml      # ansible_admin_authorized_key
$EDITOR inventories/stg/group_vars/all/control.yml   # control_repo_owner
$EDITOR inventories/stg/group_vars/all/secrets.yml   # Splunk/Grafana secrets
$EDITOR inventories/stg/group_vars/all/common.yml    # control_plane_host

# 3. stage 1 -- create the `ansible` admin account, once per host,
#    connecting as the cloud-init user
ansible-playbook bootstrap/arch/bootstrap-arch.yml --limit control-stg -e ansible_user=controlstg
ansible-playbook bootstrap/arch/bootstrap-arch.yml --limit app-stg     -e ansible_user=appstg

# 4. stage 2 -- install the agents everywhere, then bring up the control plane
ansible-playbook site/arch/site-arch.yml
ansible-playbook site/control/site-control.yml

# later: pull new control-server code and restart, nothing else
ansible-playbook site/control/update-setup.yml
```

That is the whole flow. When it finishes, `http://<control-plane>/grafana/`
serves dashboards over both Prometheus and Loki, and `/splunk/` serves the
security events.

### About re-running

Every playbook is idempotent, so re-running is always safe and is sometimes
necessary. `site-arch.yml` runs a full `pacman -Syu` once a day per host; if
that upgrade replaces the kernel the play reboots the host and continues. A run
interrupted by a reboot picks up cleanly on the next invocation.

## How the pieces fit

```
                    ┌───────────── control plane ─────────────┐
   agents push ────▶│  nginx :80  -- the only published port   │
                    │    /prometheus/  /loki/  /grafana/       │
   Prometheus ◀─────│    /splunk/      /services/collector     │
   scrapes :9100    └─────────────────────────────────────────┘
                                     ▲
                      Tailscale      │  (transport encryption; no TLS beneath)
                                     ▼
        ┌──────────────── managed host ────────────────┐
        │  node-exporter :9100      <- scraped          │
        │  Fluent Bit  -> /loki/api/v1/push  (host logs)│
        │              -> /services/collector (security)│
        │  auditd, osquery, Tailscale, Docker           │
        └───────────────────────────────────────────────┘
```

The control plane exposes **one** port. Services are told apart by URL path, so
`loki_host` and `splunk_hec_host` are the same address — see
`control-server/README.md` under "Single ingress".

The control-plane host is itself a managed host: it appears in both
`[arch_hosts]` and `[control_hosts]`, so it runs the same agents as everything
else in addition to hosting the stack.

## Submodules

```bash
git submodule update --remote       # pull the latest of each
git commit -am "Bump submodules"
```

Work inside a submodule is committed and pushed in that submodule's own repo
first; the superproject then records the new commit.
