#!/usr/bin/env bash
# validate-landing-zone.sh (Google Cloud)
#
# Deploys a single-purpose "utility VM" into a target VPC subnet, runs an
# HTTPS reachability test from inside it via a startup-script (results read
# back from the serial console — no SSH key or inbound firewall rule
# needed), prints pass/fail, then deletes every resource it created.
#
# Requires: gcloud cli (authenticated, default project set or --project passed).
#
# Usage:
#   ./validate-landing-zone.sh \
#     --project my-nc2-project \
#     --network my-nc2-vpc \
#     --subnet nc2-subnet \
#     --zone us-central1-a \
#     --endpoint download.nutanix.com:443 \
#     --endpoint pulse.nutanix.com:443
#
set -euo pipefail
IFS=$'\n\t'

PROJECT=""
NETWORK=""
SUBNET=""
ZONE=""
ENDPOINTS=()
RUN_ID="$(date +%s)"
VM_NAME="nc2z-utility-${RUN_ID}"
FW_RULE="nc2z-utility-egress-${RUN_ID}"
FW_DENY_RULE="nc2z-utility-deny-inbound-${RUN_ID}"

usage() {
  echo "Usage: $0 --project PROJECT --network NETWORK --subnet SUBNET --zone ZONE --endpoint host:port [--endpoint host:port ...]" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --network) NETWORK="$2"; shift 2 ;;
    --subnet) SUBNET="$2"; shift 2 ;;
    --zone) ZONE="$2"; shift 2 ;;
    --endpoint) ENDPOINTS+=("$2"); shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

[ -n "$PROJECT" ] && [ -n "$NETWORK" ] && [ -n "$SUBNET" ] && [ -n "$ZONE" ] && [ "${#ENDPOINTS[@]}" -gt 0 ] || usage

CREATED_FW=0
CREATED_DENY_FW=0
CREATED_VM=0

cleanup() {
  local rc=$?
  echo
  echo "== cleanup (exit code $rc) =="
  if [ "$CREATED_VM" -eq 1 ]; then
    echo "-- deleting instance $VM_NAME"
    gcloud compute instances delete "$VM_NAME" --project "$PROJECT" --zone "$ZONE" --quiet || true
  fi
  if [ "$CREATED_FW" -eq 1 ]; then
    echo "-- deleting firewall rule $FW_RULE"
    gcloud compute firewall-rules delete "$FW_RULE" --project "$PROJECT" --quiet || true
  fi
  if [ "$CREATED_DENY_FW" -eq 1 ]; then
    echo "-- deleting firewall rule $FW_DENY_RULE"
    gcloud compute firewall-rules delete "$FW_DENY_RULE" --project "$PROJECT" --quiet || true
  fi
  echo "== cleanup complete =="
  exit "$rc"
}
trap cleanup EXIT INT TERM

echo "== creating scoped firewall rules (egress 443 only, deny inbound), tagged nc2z-utility =="
gcloud compute firewall-rules create "$FW_RULE" --project "$PROJECT" \
  --network "$NETWORK" --direction=EGRESS --action=ALLOW \
  --rules=tcp:443 --target-tags=nc2z-utility --destination-ranges=0.0.0.0/0 -q
CREATED_FW=1
gcloud compute firewall-rules create "$FW_DENY_RULE" --project "$PROJECT" \
  --network "$NETWORK" --direction=INGRESS --action=DENY \
  --rules=all --target-tags=nc2z-utility --source-ranges=0.0.0.0/0 --priority=100 -q
CREATED_DENY_FW=1

echo "== building startup script (writes PASS/FAIL lines to serial console) =="
STARTUP_SCRIPT="$(mktemp)"
{
  echo '#!/usr/bin/env bash'
  echo "ENDPOINTS=(${ENDPOINTS[*]})"
  cat <<'EOS'
for ep in "${ENDPOINTS[@]}"; do
  host="${ep%%:*}"
  port="${ep##*:}"
  if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" 2>/dev/null; then
    echo "NC2Z-RESULT: PASS ${ep}"
  else
    echo "NC2Z-RESULT: FAIL ${ep}"
  fi
done
echo "NC2Z-RESULT: DONE"
EOS
} > "$STARTUP_SCRIPT"

echo "== creating utility VM $VM_NAME (e2-micro, no external IP, no SSH key) =="
gcloud compute instances create "$VM_NAME" --project "$PROJECT" --zone "$ZONE" \
  --machine-type=e2-micro \
  --network="$NETWORK" --subnet="$SUBNET" --no-address \
  --tags=nc2z-utility \
  --image-family=debian-12 --image-project=debian-cloud \
  --metadata-from-file=startup-script="$STARTUP_SCRIPT" \
  -q
CREATED_VM=1
rm -f "$STARTUP_SCRIPT"

echo "== waiting for startup-script to finish (polling serial console) =="
RESULT=""
for _ in $(seq 1 30); do
  CONSOLE="$(gcloud compute instances get-serial-port-output "$VM_NAME" \
    --project "$PROJECT" --zone "$ZONE" 2>/dev/null || true)"
  if echo "$CONSOLE" | grep -q 'NC2Z-RESULT: DONE'; then
    RESULT="$(echo "$CONSOLE" | grep 'NC2Z-RESULT:' | sed 's/.*NC2Z-RESULT: //')"
    break
  fi
  sleep 5
done

echo "== results =="
echo "$RESULT" | grep -E '^(PASS|FAIL) ' || echo "(no PASS/FAIL lines — startup-script may not have completed in time)"

if echo "$RESULT" | grep -q '^FAIL '; then
  echo "== one or more endpoints unreachable — landing zone egress is NOT ready =="
  false
else
  echo "== all endpoints reachable — landing zone egress looks ready =="
fi
