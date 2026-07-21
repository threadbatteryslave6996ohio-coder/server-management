#!/usr/bin/env bash
#
# Create the control-plane and application VMs on the local libvirt host and
# write the resulting addresses into the Ansible inventory.
#
# After this runs, the two playbooks have everything they need:
#
#   ./provision-vms.sh
#   cd non-master-node
#   ansible-playbook bootstrap/arch/bootstrap-arch.yml -e ansible_user=<cloud user>
#   ansible-playbook site/arch/site-arch.yml
#   ansible-playbook site/control/site-control.yml
#
# Re-running is safe: existing domains are left alone unless --recreate is
# passed, and the inventory is rewritten from the current definitions either
# way.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR
readonly INVENTORY="${REPO_DIR}/non-master-node/inventory.ini"

# --- configuration ----------------------------------------------------------
# Each VM is "name:ip:mac:cloud-init user:vcpus:memory-MiB". The MACs are fixed
# so the DHCP reservations below always hand back the same address, which is
# what lets the inventory be written before the guests have booted.
readonly VMS=(
  "control-stg:192.168.123.234:52:54:00:c8:7d:b9:controlstg:2:4096"
  "app-stg:192.168.123.127:52:54:00:44:1b:71:appstg:2:4096"
)

# Which VM hosts the control plane. Must match a name above.
readonly CONTROL_VM="control-stg"

readonly LIBVIRT_NET="${LIBVIRT_NET:-default}"
readonly IMAGE_DIR="${IMAGE_DIR:-/var/lib/libvirt/images}"
readonly BASE_IMAGE="${BASE_IMAGE:-${IMAGE_DIR}/archlinux-cloudimg.qcow2}"
readonly DISK_SIZE="${DISK_SIZE:-20G}"
readonly SSH_KEY="${SSH_KEY:-${HOME}/.ssh/ansible-stg}"

RECREATE=false
[[ "${1:-}" == "--recreate" ]] && RECREATE=true

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# Fields are colon-separated but the MAC contains colons too, so pull the
# fixed-position fields from the ends rather than splitting naively.
vm_field() {
  local spec="$1" field="$2"
  case "$field" in
    name) cut -d: -f1 <<<"$spec" ;;
    ip)   cut -d: -f2 <<<"$spec" ;;
    mac)  cut -d: -f3-8 <<<"$spec" ;;
    user) cut -d: -f9 <<<"$spec" ;;
    cpus) cut -d: -f10 <<<"$spec" ;;
    mem)  cut -d: -f11 <<<"$spec" ;;
  esac
}

# --- preflight --------------------------------------------------------------
preflight() {
  local missing=()
  for tool in virsh virt-install qemu-img xorriso ssh-keygen; do
    command -v "$tool" >/dev/null || missing+=("$tool")
  done
  (( ${#missing[@]} == 0 )) || die "missing required tools: ${missing[*]}"

  [[ -f "$BASE_IMAGE" ]] || die "base image not found: ${BASE_IMAGE}
Download an Arch cloud image to that path, or set BASE_IMAGE."

  virsh net-info "$LIBVIRT_NET" >/dev/null 2>&1 \
    || die "libvirt network '${LIBVIRT_NET}' does not exist"

  if [[ "$(virsh net-info "$LIBVIRT_NET" | awk '/^Active/{print $2}')" != "yes" ]]; then
    log "starting libvirt network ${LIBVIRT_NET}"
    virsh net-start "$LIBVIRT_NET"
  fi

  # A thin overlay is small, but the guests grow into the same filesystem.
  local avail
  avail=$(df --output=avail -BG "$IMAGE_DIR" | tail -1 | tr -dc '0-9')
  (( avail >= 10 )) || warn "only ${avail}G free in ${IMAGE_DIR}; guests may fill it"
}

ensure_ssh_key() {
  if [[ ! -f "$SSH_KEY" ]]; then
    log "generating SSH key ${SSH_KEY}"
    ssh-keygen -t ed25519 -N '' -C 'ansible@provisioned' -f "$SSH_KEY" >/dev/null
  fi
  [[ -f "${SSH_KEY}.pub" ]] || die "public key missing: ${SSH_KEY}.pub"
}

# --- per-VM provisioning ----------------------------------------------------

# Pin the address so the inventory can be written before the guest boots.
ensure_dhcp_reservation() {
  local name="$1" ip="$2" mac="$3"
  if virsh net-dumpxml "$LIBVIRT_NET" | grep -q "mac='${mac}'"; then
    return 0
  fi
  log "  adding DHCP reservation ${mac} -> ${ip}"
  virsh net-update "$LIBVIRT_NET" add ip-dhcp-host \
    "<host mac='${mac}' name='${name}' ip='${ip}'/>" \
    --live --config
}

# NoCloud only reads files named exactly user-data and meta-data on the volume.
# Passing *.yaml filenames to xorriso yields an ISO cloud-init silently ignores,
# and the guest boots with no user and no key. Stage with the exact names.
build_seed_iso() {
  local name="$1" user="$2" iso="$3"
  local staging
  staging="$(mktemp -d)"
  trap 'rm -rf "$staging"' RETURN

  cat >"${staging}/meta-data" <<EOF
instance-id: ${name}-1
local-hostname: ${name}
EOF

  cat >"${staging}/user-data" <<EOF
#cloud-config
hostname: ${name}
manage_etc_hosts: true
ssh_pwauth: false
disable_root: true
users:
  - default
  - name: ${user}
    gecos: Cloud-init bootstrap user for ${name}
    groups: [wheel]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - $(cat "${SSH_KEY}.pub")
runcmd:
  - [ sh, -lc, "systemctl enable --now sshd || true" ]
EOF

  xorriso -as mkisofs -output "$iso" -volid cidata -joliet -rock \
    "${staging}/user-data" "${staging}/meta-data" >/dev/null 2>&1
}

create_vm() {
  local spec="$1"
  local name ip mac user cpus mem
  name=$(vm_field "$spec" name); ip=$(vm_field "$spec" ip)
  mac=$(vm_field "$spec" mac);  user=$(vm_field "$spec" user)
  cpus=$(vm_field "$spec" cpus); mem=$(vm_field "$spec" mem)

  local disk="${IMAGE_DIR}/${name}.qcow2"
  local seed="${IMAGE_DIR}/${name}-seed.iso"

  if virsh dominfo "$name" >/dev/null 2>&1; then
    if [[ "$RECREATE" == true ]]; then
      log "destroying existing ${name}"
      virsh destroy "$name" >/dev/null 2>&1 || true
      virsh undefine "$name" --nvram --remove-all-storage >/dev/null 2>&1 \
        || virsh undefine "$name" >/dev/null 2>&1 || true
      rm -f "$disk" "$seed"
    else
      log "${name} already defined; leaving it alone (use --recreate to rebuild)"
      virsh domstate "$name" | grep -q running || virsh start "$name" >/dev/null
      return 0
    fi
  fi

  ensure_dhcp_reservation "$name" "$ip" "$mac"

  log "creating ${name} (${ip}, ${cpus} vCPU, ${mem} MiB)"
  # Thin overlay: the guest writes only its own deltas against the base image.
  qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$disk" "$DISK_SIZE" >/dev/null
  build_seed_iso "$name" "$user" "$seed"

  virt-install \
    --name "$name" \
    --memory "$mem" \
    --vcpus "$cpus" \
    --import \
    --disk "path=${disk},format=qcow2,bus=virtio,discard=unmap" \
    --disk "path=${seed},device=cdrom" \
    --network "network=${LIBVIRT_NET},mac=${mac},model=virtio" \
    --os-variant archlinux \
    --graphics none \
    --noautoconsole \
    >/dev/null
}

wait_for_ssh() {
  local name="$1" ip="$2" user="$3" waited=0
  local timeout="${SSH_TIMEOUT:-300}"
  log "  waiting for ssh on ${name} (${ip})"
  while (( waited < timeout )); do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
           -o BatchMode=yes -i "$SSH_KEY" "${user}@${ip}" true 2>/dev/null; then
      log "  ${name} reachable after ${waited}s"
      return 0
    fi
    sleep 5; waited=$((waited + 5))
  done
  warn "${name} did not answer ssh within ${timeout}s; check 'virsh console ${name}'"
  return 1
}

# --- inventory --------------------------------------------------------------
# Written from the definitions above, so it always matches what was built.
write_inventory() {
  log "writing ${INVENTORY}"
  local control_ip=""

  {
    cat <<EOF
# Generated by provision-vms.sh -- edits will be overwritten.
#
# ansible_user is the steady-state \`ansible\` account the site playbooks use.
# The bootstrap stage runs once as the cloud-init user instead; override it per
# run, e.g.  -e ansible_user=controlstg

[arch_hosts]
EOF
    for spec in "${VMS[@]}"; do
      printf '%s ansible_host=%s ansible_ssh_private_key_file=%s\n' \
        "$(vm_field "$spec" name)" "$(vm_field "$spec" ip)" "$SSH_KEY"
    done

    cat <<EOF

[arch_hosts:vars]
ansible_user=ansible

# The control plane. Also a member of arch_hosts, so it runs the same agents as
# every other managed host in addition to hosting the stack.
[control_hosts]
EOF
    for spec in "${VMS[@]}"; do
      [[ "$(vm_field "$spec" name)" == "$CONTROL_VM" ]] || continue
      control_ip=$(vm_field "$spec" ip)
      printf '%s ansible_host=%s ansible_ssh_private_key_file=%s\n' \
        "$CONTROL_VM" "$control_ip" "$SSH_KEY"
    done

    cat <<EOF

[control_hosts:vars]
ansible_user=ansible

[ubuntu_hosts]

[ubuntu_hosts:vars]
ansible_user=ansible
EOF
  } >"$INVENTORY"

  # The agents ship to the control plane, so its address has to reach the vars
  # too. Everything else in vars/ is the operator's to fill in.
  local common="${REPO_DIR}/non-master-node/vars/common.yml"
  if [[ -f "$common" ]] && [[ -n "$control_ip" ]]; then
    if grep -q '^control_plane_host:' "$common"; then
      sed -i "s|^control_plane_host:.*|control_plane_host: \"${control_ip}\"|" "$common"
      log "set control_plane_host=${control_ip} in vars/common.yml"
    fi
  fi
}

main() {
  preflight
  ensure_ssh_key

  for spec in "${VMS[@]}"; do
    create_vm "$spec"
  done

  local failed=0
  for spec in "${VMS[@]}"; do
    wait_for_ssh "$(vm_field "$spec" name)" "$(vm_field "$spec" ip)" \
                 "$(vm_field "$spec" user)" || failed=1
  done

  write_inventory

  echo
  log "VMs ready. Next:"
  cat <<EOF

  cd ${REPO_DIR}/non-master-node
  cp vars/common.yml.example  vars/common.yml     # if not already done
  cp vars/arch.yml.example    vars/arch.yml
  cp vars/control.yml.example vars/control.yml
  cp vars/secrets.yml.example vars/secrets.yml    # then fill in the secrets

  # stage 1, once, as the cloud-init user (per host)
EOF
  for spec in "${VMS[@]}"; do
    printf '  ansible-playbook bootstrap/arch/bootstrap-arch.yml --limit %s -e ansible_user=%s\n' \
      "$(vm_field "$spec" name)" "$(vm_field "$spec" user)"
  done
  cat <<EOF

  # stage 2, as the ansible user
  ansible-playbook site/arch/site-arch.yml
  ansible-playbook site/control/site-control.yml

EOF
  return $failed
}

main "$@"
