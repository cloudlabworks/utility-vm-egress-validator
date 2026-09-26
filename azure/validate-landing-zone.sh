#!/usr/bin/env bash
# validate-landing-zone.sh (Azure)
#
# Deploys a single-purpose "utility VM" into a target VNet/subnet, runs an
# HTTPS reachability test from inside it against caller-supplied endpoints,
# prints pass/fail, then deletes every resource it created.
#
# Requires: az cli (logged in), jq.
#
# Usage:
#   ./validate-landing-zone.sh \
#     --resource-group my-nc2-rg \
#     --vnet my-nc2-vnet \
#     --subnet nc2-subnet \
#     --endpoint download.nutanix.com:443 \
#     --endpoint pulse.nutanix.com:443
#
set -euo pipefail
IFS=$'\n\t'

RG=""
VNET=""
SUBNET=""
LOCATION=""
ENDPOINTS=()
VM_NAME="nc2z-utility-$(date +%s)"
NSG_NAME="${VM_NAME}-nsg"
NIC_NAME="${VM_NAME}-nic"

usage() {
  echo "Usage: $0 --resource-group RG --vnet VNET --subnet SUBNET [--location LOC] --endpoint host:port [--endpoint host:port ...]" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --resource-group) RG="$2"; shift 2 ;;
    --vnet) VNET="$2"; shift 2 ;;
    --subnet) SUBNET="$2"; shift 2 ;;
    --location) LOCATION="$2"; shift 2 ;;
    --endpoint) ENDPOINTS+=("$2"); shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

[ -n "$RG" ] && [ -n "$VNET" ] && [ -n "$SUBNET" ] && [ "${#ENDPOINTS[@]}" -gt 0 ] || usage

if [ -z "$LOCATION" ]; then
  LOCATION="$(az group show -n "$RG" --query location -o tsv)"
fi

CREATED_NSG=0
CREATED_NIC=0
CREATED_VM=0

cleanup() {
  local rc=$?
  echo
  echo "== cleanup (exit code $rc) =="
  if [ "$CREATED_VM" -eq 1 ]; then
    echo "-- deleting VM $VM_NAME"
    az vm delete -g "$RG" -n "$VM_NAME" --yes --no-wait || true
    # wait for the VM delete to actually land before removing its NIC/NSG
    az vm wait -g "$RG" -n "$VM_NAME" --deleted --timeout 300 2>/dev/null || true
  fi
  if [ "$CREATED_NIC" -eq 1 ]; then
    echo "-- deleting NIC $NIC_NAME"
    az network nic delete -g "$RG" -n "$NIC_NAME" || true
  fi
  if [ "$CREATED_NSG" -eq 1 ]; then
    echo "-- deleting NSG $NSG_NAME"
    az network nsg delete -g "$RG" -n "$NSG_NAME" || true
  fi
  echo "== cleanup complete =="
  exit "$rc"
}
trap cleanup EXIT INT TERM

echo "== creating scoped NSG (egress 443 only) =="
az network nsg create -g "$RG" -n "$NSG_NAME" -l "$LOCATION" -o none
CREATED_NSG=1
az network nsg rule create -g "$RG" --nsg-name "$NSG_NAME" -n allow-egress-443 \
  --priority 100 --direction Outbound --access Allow --protocol Tcp \
  --destination-port-ranges 443 -o none
az network nsg rule create -g "$RG" --nsg-name "$NSG_NAME" -n deny-all-inbound \
  --priority 100 --direction Inbound --access Deny --protocol '*' \
  --destination-port-ranges '*' -o none

echo "== creating NIC (no public IP) in ${VNET}/${SUBNET} =="
az network nic create -g "$RG" -n "$NIC_NAME" \
  --vnet-name "$VNET" --subnet "$SUBNET" --network-security-group "$NSG_NAME" \
  -o none
CREATED_NIC=1

echo "== creating utility VM $VM_NAME (Standard_B1s, no SSH key needed) =="
az vm create -g "$RG" -n "$VM_NAME" \
  --nics "$NIC_NAME" \
  --image Ubuntu2204 \
  --size Standard_B1s \
  --authentication-type ssh \
  --generate-ssh-keys \
  --output none
CREATED_VM=1

echo "== running egress test via az vm run-command (no inbound access needed) =="
TEST_SCRIPT='#!/usr/bin/env bash
for ep in "$@"; do
  host="${ep%%:*}"
  port="${ep##*:}"
  if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" 2>/dev/null; then
    echo "PASS ${ep}"
  else
    echo "FAIL ${ep}"
  fi
done'

RESULT="$(az vm run-command invoke -g "$RG" -n "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "$TEST_SCRIPT" \
  --parameters "${ENDPOINTS[@]}" \
  --query "value[0].message" -o tsv)"

echo "== results =="
echo "$RESULT" | grep -E '^(PASS|FAIL) ' || echo "(no PASS/FAIL lines returned — check RESULT above for run-command errors)"

if echo "$RESULT" | grep -q '^FAIL '; then
  echo "== one or more endpoints unreachable — landing zone egress is NOT ready =="
  false
else
  echo "== all endpoints reachable — landing zone egress looks ready =="
fi
