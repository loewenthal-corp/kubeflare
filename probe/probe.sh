#!/bin/bash
# kubeflare Phase 0 probe matrix — capture kernel/platform capabilities
# relevant to running Kubernetes (k3s rootless) on Cloudflare Containers.

section() {
  echo ""
  echo "############################################################"
  echo "## $*"
  echo "############################################################"
}

run() {
  echo ""
  echo "----- \$ $*"
  timeout 20 bash -c "$*" 2>&1
  echo "[exit=$?]"
}

echo "PROBE RUN START $(date -u +%FT%TZ)"

section "P1: kernel + OS"
run "uname -a"
run "cat /proc/version"
run "grep PRETTY /etc/os-release"
run "cat /proc/uptime"

section "P2: identity, capabilities, seccomp"
run "id"
run "grep -E 'Uid|Gid|Groups|CapInh|CapPrm|CapEff|CapBnd|CapAmb|NoNewPrivs|Seccomp' /proc/self/status"
run "capsh --decode=\$(grep CapEff /proc/self/status | awk '{print \$2}')"
run "cat /proc/self/uid_map /proc/self/gid_map"

section "P3: unprivileged user namespaces"
run "unshare -U -r true && echo USERNS_OK"
run "cat /proc/sys/user/max_user_namespaces"
run "cat /proc/sys/kernel/unprivileged_userns_clone"
run "unshare -U -r sh -c 'id; cat /proc/self/uid_map'"

section "P4: newuidmap/newgidmap + subuid ranges"
run "which newuidmap newgidmap"
run "ls -l /usr/bin/newuidmap /usr/bin/newgidmap"
run "getcap /usr/bin/newuidmap /usr/bin/newgidmap"
run "cat /etc/subuid /etc/subgid"

section "P5: cgroup v2"
run "mount | grep cgroup"
run "cat /sys/fs/cgroup/cgroup.controllers"
run "cat /proc/self/cgroup"

section "P6: cgroup delegation (mkdir + move procs + enable controllers)"
run "cat /sys/fs/cgroup/cgroup.subtree_control"
run "mkdir /sys/fs/cgroup/probe-init && echo MKDIR_INIT_OK"
run "for p in \$(cat /sys/fs/cgroup/cgroup.procs); do echo \$p > /sys/fs/cgroup/probe-init/cgroup.procs 2>/dev/null; done; echo MOVED; head /sys/fs/cgroup/probe-init/cgroup.procs"
run "for c in cpu memory pids io cpuset; do echo \"+\$c\" > /sys/fs/cgroup/cgroup.subtree_control 2>&1 && echo \"ENABLE_\$c OK\" || echo \"ENABLE_\$c FAILED\"; done"
run "cat /sys/fs/cgroup/cgroup.subtree_control"
run "mkdir /sys/fs/cgroup/probe-child && cat /sys/fs/cgroup/probe-child/cgroup.controllers"

section "P7: /dev/net/tun"
run "ls -l /dev/net/tun"
run "python3 -c \"import os; fd=os.open('/dev/net/tun', os.O_RDWR); print('TUN_OPEN_OK')\""

section "P8: /dev/kmsg"
run "ls -l /dev/kmsg"
run "timeout 3 head -c 300 /dev/kmsg"

section "P9: overlayfs / tmpfs / fuse-overlayfs inside userns"
run "stat -f -c '%T' / /tmp /var/lib 2>&1"
# Direct test: lower/upper/work on the container's own filesystem. Fails spuriously if that
# filesystem is itself overlayfs (overlay-on-overlay is unsupported), hence the tmpfs variant below.
run "mkdir -p /tmp/ov/l /tmp/ov/u /tmp/ov/w /tmp/ov/m && unshare -Urm sh -c 'mount -t overlay overlay -o lowerdir=/tmp/ov/l,upperdir=/tmp/ov/u,workdir=/tmp/ov/w /tmp/ov/m && echo OVERLAY_USERNS_OK && touch /tmp/ov/m/x && ls /tmp/ov/u'"
# Isolating variant: everything on a fresh tmpfs inside the userns, so the only question asked is
# "can an unprivileged user namespace mount overlayfs at all" (kernel >= 5.11).
run "unshare -Urm sh -c 'mount -t tmpfs tmpfs /mnt && mkdir -p /mnt/l /mnt/u /mnt/w /mnt/m && mount -t overlay overlay -o lowerdir=/mnt/l,upperdir=/mnt/u,workdir=/mnt/w /mnt/m && echo OVERLAY_USERNS_TMPFS_OK && touch /mnt/m/x && ls /mnt/u'"
run "unshare -Urm sh -c 'mount -t tmpfs tmpfs /mnt && echo TMPFS_USERNS_OK'"
run "ls -l /dev/fuse"
run "fuse-overlayfs --version 2>&1 | head -2"
run "mkdir -p /tmp/fo/l /tmp/fo/u /tmp/fo/w /tmp/fo/m && unshare -Urm sh -c 'fuse-overlayfs -o lowerdir=/tmp/fo/l,upperdir=/tmp/fo/u,workdir=/tmp/fo/w /tmp/fo/m && echo FUSE_OVERLAYFS_USERNS_OK && touch /tmp/fo/m/x && ls /tmp/fo/u'"

section "P10: netfilter (expected to fail — record exactly how)"
run "iptables -L -n 2>&1 | head -5"
run "unshare -Urn sh -c 'iptables -t filter -A OUTPUT -j ACCEPT && echo IPTABLES_USERNS_OK'"
run "unshare -Urn sh -c 'iptables-legacy -t filter -A OUTPUT -j ACCEPT && echo IPTABLES_LEGACY_USERNS_OK'"
run "unshare -Urn sh -c 'nft add table ip probe && echo NFT_USERNS_OK && nft list tables'"

section "P10b: network + mount primitives in userns (rootlesskit prerequisites)"
run "unshare -Urn sh -c 'ip link set lo up && echo NETNS_LO_OK && ip addr show lo | head -3'"
run "unshare -Urn sh -c 'ip link add v0 type veth peer name v1 && echo VETH_OK'"
run "unshare -Urm sh -c 'cd /tmp && mkdir -p pvt && mount -t tmpfs tmpfs pvt && cd pvt && mkdir old && pivot_root . old && echo PIVOT_ROOT_OK'"
run "unshare -Urm sh -c 'mount --bind /dev/null /tmp/bindtest 2>/dev/null; touch /tmp/bindtest; mount --bind /dev/null /tmp/bindtest && echo BIND_MOUNT_OK'"
run "unshare -Upfrm --mount-proc sh -c 'echo PIDNS_PROC_OK; ps aux | head -3'"
# If the runtime masks /proc subpaths with read-only binds (standard OCI hardening), those are
# "locked" mounts in a user namespace and mounting a fresh procfs over /proc is denied. This is
# what rootlesskit does during startup, so it is directly decision-relevant for rootless k3s.
run "grep ' /proc' /proc/self/mountinfo"
run "unshare -Upfr sh -c 'mount -t proc proc /proc && echo FRESH_PROC_OK'"

section "P11: limits, mounts, network, misc"
run "ulimit -a"
run "nproc"
run "free -m"
run "df -h"
run "cat /proc/sys/kernel/pid_max /proc/sys/kernel/threads-max"
run "cat /proc/sys/user/max_pid_namespaces /proc/sys/user/max_net_namespaces /proc/sys/user/max_mnt_namespaces"
run "cat /proc/sys/net/ipv4/ip_unprivileged_port_start"
run "cat /proc/sys/net/ipv4/ping_group_range"
run "sysctl net.ipv4.ip_forward 2>&1"
run "mount"
run "ls -la /dev /dev/net 2>&1"
run "ip addr"
run "ip route"
run "cat /etc/resolv.conf"
run "cat /etc/hosts"
run "hostname"
run "cat /proc/sys/kernel/random/entropy_avail 2>&1"
run "ls /lib/modules 2>&1 | head; head -30 /proc/modules"
run "grep -E 'model name|processor' /proc/cpuinfo | head -10"
run "env | sort | grep -viE 'token|secret|key|password'"
run "ps aux"

section "SUMMARY (machine-readable)"
# Re-run the decisive checks in isolation and emit one PASS/FAIL line each, so the
# dashboard and the report can be generated without parsing the full transcript.
verdict() {
  local name="$1"; shift
  if timeout 20 bash -c "$*" >/dev/null 2>&1; then
    echo "VERDICT ${name}=PASS"
  else
    echo "VERDICT ${name}=FAIL"
  fi
}
verdict userns_unshare              "unshare -U -r true"
verdict userns_full                 "unshare -Urm true"
verdict netns_userns                "unshare -Urn ip link set lo up"
verdict newuidmap_present           "command -v newuidmap && command -v newgidmap"
verdict subuid_configured           "test -s /etc/subuid && test -s /etc/subgid"
verdict cgroup2_mounted             "grep -q cgroup2 /proc/mounts"
verdict cgroup_subtree_writable     "test -w /sys/fs/cgroup/cgroup.subtree_control"
verdict cgroup_mkdir                "mkdir -p /sys/fs/cgroup/verdict-probe && rmdir /sys/fs/cgroup/verdict-probe"
verdict dev_net_tun                 "test -c /dev/net/tun"
verdict dev_net_tun_open            "python3 -c \"import os;os.open('/dev/net/tun',os.O_RDWR)\""
verdict dev_kmsg                    "test -c /dev/kmsg"
verdict dev_kmsg_read               "timeout 3 head -c 1 /dev/kmsg"
verdict dev_fuse                    "test -c /dev/fuse"
verdict overlay_userns_tmpfs        "unshare -Urm sh -c 'mount -t tmpfs tmpfs /mnt && mkdir -p /mnt/l /mnt/u /mnt/w /mnt/m && mount -t overlay overlay -o lowerdir=/mnt/l,upperdir=/mnt/u,workdir=/mnt/w /mnt/m'"
verdict fuse_overlayfs_userns       "unshare -Urm sh -c 'mkdir -p /tmp/fo2/{l,u,w,m} && fuse-overlayfs -o lowerdir=/tmp/fo2/l,upperdir=/tmp/fo2/u,workdir=/tmp/fo2/w /tmp/fo2/m'"
verdict pivot_root_userns           "unshare -Urm sh -c 'mkdir -p /tmp/pr && mount -t tmpfs tmpfs /tmp/pr && cd /tmp/pr && mkdir old && pivot_root . old'"
verdict pidns_userns                "unshare -Upfrm --mount-proc true"
verdict proc_submounts_masked       "test \$(grep -c ' /proc/' /proc/self/mountinfo) -gt 0"
verdict mount_fresh_proc_userns     "unshare -Upfr sh -c 'mount -t proc proc /proc'"
verdict iptables_userns             "unshare -Urn iptables -t filter -A OUTPUT -j ACCEPT"
verdict nft_userns                  "unshare -Urn nft add table ip probeverdict"
verdict outbound_dns                "getent hosts cloudflare.com"
verdict outbound_https              "curl -sS -m 10 -o /dev/null https://api.cloudflare.com/client/v4"
verdict outbound_tcp_7844           "timeout 8 bash -c '</dev/tcp/198.41.192.167/7844'"

echo ""
echo "PROBE RUN COMPLETE $(date -u +%FT%TZ)"
