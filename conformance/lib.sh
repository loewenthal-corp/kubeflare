# shellcheck shell=bash
# Shared helpers for the kubeflare conformance suite.
#
# Result model
#   PASS   expected to pass, passed
#   FAIL   expected to pass, failed                -> fatal, exit non-zero
#   XFAIL  expected to fail, failed as expected    -> fine, this is a known limitation
#   XPASS  expected to fail, but PASSED            -> notable: a limitation was fixed,
#                                                    docs/CONFORMANCE.md needs updating
#   SKIP   not applicable, or a prerequisite was missing
#
# A suite that goes green by omitting the hard cases is worthless, so every known
# limitation is encoded as an XFAIL rather than left out. If the platform improves,
# the XPASS count tells you exactly what to re-document.

# Deliberately NOT strict. Checks routinely pipe a command that is *expected* to fail
# into grep (e.g. asserting on a rejection message), so `pipefail` would turn correct
# assertions into false FAILs. `-u` is off too, for bash 3.2 empty-array compatibility.
set +o pipefail
set +u

: "${NS:=kubeflare-conformance}"
: "${QNS:=kubeflare-conformance-quota}"
# Cluster-scoped objects must be uniquely named so a stray run never collides with
# anything real. RUN_ID is stable per invocation and is cleaned up at the end.
: "${RUN_ID:=cf$(date +%s)}"
: "${KEEP:=0}"
: "${VERBOSE:=0}"

# A literal single quote, for embedding inside the single-quoted check snippets
# (YAML and CEL both need real quotes that bash would otherwise swallow).
SQ="'"

: "${IMG_BUSYBOX:=busybox:1.36}"
: "${IMG_NGINX:=nginx:1.27-alpine}"
: "${IMG_AGNHOST:=registry.k8s.io/e2e-test-images/agnhost:2.47}"

: "${WAKE_URL:=https://kubeflare.the-loewenthal-corporation.workers.dev/healthz}"

PASS_N=0; FAIL_N=0; XFAIL_N=0; XPASS_N=0; SKIP_N=0
FAILED_CHECKS=(); XPASSED_CHECKS=()
LOGDIR="${LOGDIR:-$(mktemp -d)}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_PASS=$'\033[32m'; C_FAIL=$'\033[31m'; C_XFAIL=$'\033[33m'
  C_XPASS=$'\033[35m'; C_SKIP=$'\033[90m'; C_HEAD=$'\033[1;36m'; C_OFF=$'\033[0m'
else
  C_PASS=; C_FAIL=; C_XFAIL=; C_XPASS=; C_SKIP=; C_HEAD=; C_OFF=
fi

# ---------------------------------------------------------------- kubectl wrappers

# Every kubectl call is time-bounded. The cluster is a single Cloudflare Container
# that may be asleep, restarting, or mid-rollout, so a hang is a real failure mode.
k()  { timeout "${KTIMEOUT:-120}" kubectl "$@"; }
kn() { timeout "${KTIMEOUT:-120}" kubectl -n "$NS" "$@"; }

# Exec into the long-lived busybox client pod.
kx() { timeout "${KTIMEOUT:-60}" kubectl -n "$NS" exec client -- sh -c "$1" 2>&1; }

# NOTE: `kubectl get --raw <path>` DISCARDS the /k8s path prefix in the kubeconfig
# server URL and lands on the Worker's dashboard, which answers 200 + HTML. Always
# spell the prefix. See docs/CONFORMANCE.md, "kubectl get --raw".
kraw() { timeout "${KTIMEOUT:-60}" kubectl get --raw "/k8s$1"; }

# ---------------------------------------------------------------- reporting

group() { printf '\n%s== %s ==%s\n' "$C_HEAD" "$1" "$C_OFF"; }

_emit() { # _emit <colour> <tag> <label> [detail]
  printf '%s%-6s%s %s' "$1" "$2" "$C_OFF" "$3"
  [ -n "${4:-}" ] && printf '  %s(%s)%s' "$C_SKIP" "$4" "$C_OFF"
  printf '\n'
}

# check <label> <snippet>            -- expected to pass
# xcheck <label> <why> <snippet>     -- expected to FAIL (known limitation)
# skip <label> <why>                 -- not applicable / prerequisite missing
#
# The snippet is evaluated with `bash -c`; exit 0 means the behaviour is present.
_run_snippet() {
  local out
  out="$(eval "$1" 2>&1)"; local rc=$?
  LAST_OUT="$out"
  if [ "$VERBOSE" = 1 ] || { [ $rc -ne 0 ] && [ "${SHOW_ON_FAIL:-1}" = 1 ]; }; then
    printf '%s' "$out" > "$LOGDIR/last.log"
  fi
  return $rc
}

check() {
  local label="$1"; shift
  if _run_snippet "$*"; then
    PASS_N=$((PASS_N+1)); _emit "$C_PASS" PASS "$label"
  else
    FAIL_N=$((FAIL_N+1)); FAILED_CHECKS+=("$label")
    _emit "$C_FAIL" FAIL "$label"
    printf '%s       %s%s\n' "$C_SKIP" "$(printf '%s' "$LAST_OUT" | tail -3 | tr '\n' ' ')" "$C_OFF"
  fi
}

xcheck() {
  local label="$1" why="$2"; shift 2
  if _run_snippet "$*"; then
    XPASS_N=$((XPASS_N+1)); XPASSED_CHECKS+=("$label -- was: $why")
    _emit "$C_XPASS" XPASS "$label" "EXPECTED to fail but PASSED -- update docs/CONFORMANCE.md"
  else
    XFAIL_N=$((XFAIL_N+1)); _emit "$C_XFAIL" XFAIL "$label" "$why"
  fi
}

skip() { SKIP_N=$((SKIP_N+1)); _emit "$C_SKIP" SKIP "$1" "${2:-}"; }

# defect <label> <why> <snippet>
#
# For confirming that a known DEFECT is still present. Unlike xcheck, the snippet
# asserts the bad behaviour POSITIVELY, and it has a third outcome:
#   rc 0 -> the defect is still present            -> DEFECT (expected, like XFAIL)
#   rc 1 -> the defect is gone                     -> FIXED  (like XPASS, update the docs)
#   rc 2 -> the probe could not run at all         -> FAIL   (inconclusive, never "fixed")
#
# The third outcome exists because a negated probe ("! curl ...") silently reports
# success when its fixture is missing, which would announce a security hole as fixed on
# no evidence. Inconclusive must never be mistaken for good news.
defect() {
  local label="$1" why="$2"; shift 2
  _run_snippet "$*"; local rc=$?
  case $rc in
    0) XFAIL_N=$((XFAIL_N+1)); _emit "$C_XFAIL" DEFECT "$label" "$why" ;;
    1) XPASS_N=$((XPASS_N+1)); XPASSED_CHECKS+=("$label -- was: $why")
       _emit "$C_XPASS" FIXED "$label" "no longer reproducible -- update docs/CONFORMANCE.md" ;;
    *) FAIL_N=$((FAIL_N+1)); FAILED_CHECKS+=("$label (INCONCLUSIVE: probe could not run)")
       _emit "$C_FAIL" FAIL "$label" "INCONCLUSIVE: probe could not run, not evidence of a fix" ;;
  esac
}

# ---------------------------------------------------------------- waiting

# The cluster can restart under the suite (sleep, rollout, durability test), so
# readiness is polled rather than assumed.
wait_cluster() {
  local tries="${1:-40}" i
  for i in $(seq 1 "$tries"); do
    if [ "$(kraw /readyz 2>/dev/null)" = "ok" ]; then return 0; fi
    if [ "$i" = 1 ]; then
      printf 'apiserver not ready; waking the container...\n' >&2
      curl -s -m 150 "$WAKE_URL" >/dev/null 2>&1 || true
    fi
    sleep 6
  done
  return 1
}

# Retry a snippet while the apiserver is flaky. Only retries on failure.
retry() { # retry <tries> <sleep> <snippet>
  local tries="$1" nap="$2"; shift 2
  local i
  for i in $(seq 1 "$tries"); do
    if eval "$*" >/dev/null 2>&1; then return 0; fi
    sleep "$nap"
  done
  return 1
}

wait_ready()   { kn wait --for=condition=Ready "$1" --timeout="${2:-180s}" >/dev/null 2>&1; }
wait_rollout() { kn rollout status "$1" --timeout="${2:-180s}" >/dev/null 2>&1; }

# Poll until a jsonpath query equals an expected value.
wait_jsonpath() { # wait_jsonpath <resource> <jsonpath> <want> [tries] [nap]
  local res="$1" jp="$2" want="$3" tries="${4:-40}" nap="${5:-3}" i got
  for i in $(seq 1 "$tries"); do
    got="$(kn get "$res" -o jsonpath="$jp" 2>/dev/null)"
    [ "$got" = "$want" ] && return 0
    sleep "$nap"
  done
  return 1
}

phase() { kn get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }

# Wait for a pod to settle into a phase, used for "should stay Pending" checks too.
wait_phase() { # wait_phase <pod> <phase> [tries]
  local i
  for i in $(seq 1 "${3:-40}"); do
    [ "$(phase "$1")" = "$2" ] && return 0
    sleep 3
  done
  return 1
}

# ---------------------------------------------------------------- cleanup

cleanup() {
  if [ "$KEEP" = 1 ]; then
    printf '\n%s--keep set: leaving namespaces %s / %s and cluster-scoped %s objects in place%s\n' \
      "$C_SKIP" "$NS" "$QNS" "$RUN_ID" "$C_OFF"
    return 0
  fi
  printf '\n%scleaning up...%s\n' "$C_SKIP" "$C_OFF"
  # Namespaced objects go with the namespaces.
  k delete ns "$NS" "$QNS" --wait=false --ignore-not-found >/dev/null 2>&1
  # Cluster-scoped objects are uniquely named per run and must be removed explicitly.
  k delete crd "widgets-$RUN_ID.conformance.kubeflare.test" --ignore-not-found >/dev/null 2>&1
  k delete validatingadmissionpolicybinding "vap-$RUN_ID" --ignore-not-found >/dev/null 2>&1
  k delete validatingadmissionpolicy "vap-$RUN_ID" --ignore-not-found >/dev/null 2>&1
  k delete validatingwebhookconfiguration "wh-$RUN_ID" "whmissing-$RUN_ID" --ignore-not-found >/dev/null 2>&1
  k delete apiservice "v1alpha1.agg-$RUN_ID.conformance.kubeflare.test" --ignore-not-found >/dev/null 2>&1
  k delete priorityclass "low-$RUN_ID" "high-$RUN_ID" --ignore-not-found >/dev/null 2>&1
  k delete clusterrole "cr-$RUN_ID" --ignore-not-found >/dev/null 2>&1
  k delete clusterrolebinding "crb-$RUN_ID" --ignore-not-found >/dev/null 2>&1
  # Defensive: never leave the single node tainted.
  k taint node "$NODE" "taint-$RUN_ID-" >/dev/null 2>&1
}

summary() {
  local total=$((PASS_N+FAIL_N+XFAIL_N+XPASS_N+SKIP_N))
  printf '\n%s== summary ==%s\n' "$C_HEAD" "$C_OFF"
  printf '  %sPASS  %3d%s  behaviour present and correct\n'        "$C_PASS"  "$PASS_N"  "$C_OFF"
  printf '  %sXFAIL %3d%s  known limitation, failed as expected\n' "$C_XFAIL" "$XFAIL_N" "$C_OFF"
  printf '  %sSKIP  %3d%s  not applicable here\n'                  "$C_SKIP"  "$SKIP_N"  "$C_OFF"
  printf '  %sXPASS %3d%s  known limitation that now WORKS\n'      "$C_XPASS" "$XPASS_N" "$C_OFF"
  printf '  %sFAIL  %3d%s  unexpected regression\n'                "$C_FAIL"  "$FAIL_N"  "$C_OFF"
  printf '  ----- %3d checks\n' "$total"

  if [ "${#XPASSED_CHECKS[@]}" -gt 0 ]; then
    printf '\n%sThese limitations appear to be FIXED -- update docs/CONFORMANCE.md:%s\n' "$C_XPASS" "$C_OFF"
    printf '  - %s\n' "${XPASSED_CHECKS[@]}"
  fi
  if [ "${#FAILED_CHECKS[@]}" -gt 0 ]; then
    printf '\n%sUnexpected failures:%s\n' "$C_FAIL" "$C_OFF"
    printf '  - %s\n' "${FAILED_CHECKS[@]}"
    return 1
  fi
  return 0
}
