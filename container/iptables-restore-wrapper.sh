#!/bin/sh
# Strip `-j NFLOG` rules on their way into iptables-restore.
#
# k3s's embedded kube-router puts an NFLOG rule in every per-pod chain, purely
# to log denied packets. This kernel has no xt_NFLOG, and iptables-restore is
# transactional — so that one cosmetic rule rejects the whole batch and NOT ONE
# policy rule is installed. NetworkPolicy objects are then accepted and silently
# enforce nothing, which is a far worse failure than an error.
#
# Installed as the /etc/alternatives target rather than just earlier in PATH:
# kube-router does not resolve the binary through PATH (measured — a wrapper in
# /usr/local/bin was first in `command -v` and still never ran), so the only
# reliable interception point is the symlink every caller ends up following.
#
# The real binary is xtables-nft-multi, which dispatches on argv[0]. It is
# therefore reached through a correctly-named symlink under /usr/local/libexec/xt
# rather than by path, or it would not recognise itself.
set -u
real="/usr/local/libexec/xt/$(basename "$0")"
[ -x "$real" ] || real="/usr/local/libexec/xt/iptables-restore"

# A file operand means this is not the piped form kube-router uses; hand it over
# untouched rather than silently half-handling it.
for a in "$@"; do
  case "$a" in
    -*) ;;
    *)  exec "$real" "$@" ;;
  esac
done

sed '/NFLOG/d' | "$real" "$@"
