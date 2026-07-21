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

Clone with submodules, provision the VMs, run the playbooks:

```bash
git clone --recurse-submodules <this repo>
cd server-management

# 1. create the VMs and generate the staging inventory
./provision-vms.sh                  # --env <name> for another environment

# 2. fill in that environment's configuration and secrets
cd non-master-node
ansible-galaxy collection install -r requirements.yml
$EDITOR inventories/stg/group_vars/all/arch.yml      # ansible_admin_authorized_key
$EDITOR inventories/stg/group_vars/all/control.yml   # control_repo_owner
$EDITOR inventories/stg/group_vars/all/secrets.yml   # Splunk/Grafana secrets
                                    # control_plane_host is set by the script

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

## Provisioning script

`provision-vms.sh` creates the guests on the local libvirt host and writes
`non-master-node/inventories/<env>/hosts.ini` from the same definitions it
builds them with, so the inventory always matches reality.

```bash
./provision-vms.sh              # create anything missing, leave the rest alone
./provision-vms.sh --recreate   # destroy and rebuild both guests from scratch
./provision-vms.sh --env stg    # which environment to build (default: stg)
```

Only `stg` has VM definitions, because only the staging guests were created by
this script. Asking for another environment fails rather than overwriting its
inventory with an empty one.

It pins a DHCP reservation per guest, so addresses are known before the guests
boot, generates an SSH keypair at `~/.ssh/ansible-<env>` if one does not exist,
and writes `control_plane_host` into that environment's
`group_vars/all/common.yml` so the agents know where to ship. The VM list,
sizes and addresses are the `VMS` array at the top of the script.

Requires `virsh`, `virt-install`, `qemu-img` and `xorriso`, plus an Arch cloud
image at `/var/lib/libvirt/images/archlinux-cloudimg.qcow2` (override with
`BASE_IMAGE`).

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
