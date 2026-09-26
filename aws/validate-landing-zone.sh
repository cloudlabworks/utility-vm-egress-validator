#!/usr/bin/env bash
# validate-landing-zone.sh (AWS)
#
# Deploys a single-purpose "utility VM" (EC2 instance) into a target VPC
# subnet, runs an HTTPS reachability test from inside it via SSM Run Command
# (no SSH key, no security-group inbound rule needed), prints pass/fail, then
# terminates every resource it created.
#
# Requires: aws cli (configured), an SSM-enabled AMI (Amazon Linux 2023 ships
# the SSM agent by default), and an instance profile with the
# AmazonSSMManagedInstanceCore policy attached (pass via --instance-profile).
#
# Usage:
#   ./validate-landing-zone.sh \
#     --subnet-id subnet-0123456789abcdef0 \
#     --vpc-id vpc-0123456789abcdef0 \
#     --instance-profile nc2z-ssm-role \
#     --endpoint download.nutanix.com:443 \
#     --endpoint pulse.nutanix.com:443
#
set -euo pipefail
IFS=$'\n\t'

SUBNET_ID=""
VPC_ID=""
INSTANCE_PROFILE=""
REGION="${AWS_REGION:-$(aws configure get region)}"
ENDPOINTS=()
TAG_KEY="nc2z-utility-vm"
RUN_ID="$(date +%s)"
SG_NAME="nc2z-utility-${RUN_ID}"
INSTANCE_ID=""
SG_ID=""

usage() {
  echo "Usage: $0 --subnet-id SUBNET --vpc-id VPC --instance-profile NAME [--region REGION] --endpoint host:port [--endpoint host:port ...]" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --subnet-id) SUBNET_ID="$2"; shift 2 ;;
    --vpc-id) VPC_ID="$2"; shift 2 ;;
    --instance-profile) INSTANCE_PROFILE="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --endpoint) ENDPOINTS+=("$2"); shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

[ -n "$SUBNET_ID" ] && [ -n "$VPC_ID" ] && [ -n "$INSTANCE_PROFILE" ] && [ "${#ENDPOINTS[@]}" -gt 0 ] || usage

CREATED_SG=0
CREATED_INSTANCE=0

cleanup() {
  local rc=$?
  echo
  echo "== cleanup (exit code $rc) =="
  if [ "$CREATED_INSTANCE" -eq 1 ] && [ -n "$INSTANCE_ID" ]; then
    echo "-- terminating instance $INSTANCE_ID"
    aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" --output text >/dev/null || true
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID" || true
  fi
  if [ "$CREATED_SG" -eq 1 ] && [ -n "$SG_ID" ]; then
    echo "-- deleting security group $SG_ID"
    aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" || true
  fi
  echo "== cleanup complete =="
  exit "$rc"
}
trap cleanup EXIT INT TERM

echo "== creating scoped security group (egress 443 only, no inbound) =="
SG_ID="$(aws ec2 create-security-group --region "$REGION" \
  --group-name "$SG_NAME" --description "nc2z-scripts utility VM, run ${RUN_ID}" \
  --vpc-id "$VPC_ID" --query GroupId --output text)"
CREATED_SG=1
aws ec2 revoke-security-group-egress --region "$REGION" --group-id "$SG_ID" \
  --ip-permissions 'IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]' >/dev/null 2>&1 || true
aws ec2 authorize-security-group-egress --region "$REGION" --group-id "$SG_ID" \
  --ip-permissions 'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]' >/dev/null

echo "== resolving latest Amazon Linux 2023 AMI (SSM agent preinstalled) =="
AMI_ID="$(aws ec2 describe-images --region "$REGION" --owners amazon \
  --filters 'Name=name,Values=al2023-ami-*-x86_64' 'Name=state,Values=available' \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)"

echo "== launching utility VM (t3.micro, no public IP, no SSH key) =="
INSTANCE_ID="$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI_ID" --instance-type t3.micro \
  --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
  --no-associate-public-ip-address \
  --iam-instance-profile "Name=${INSTANCE_PROFILE}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=${TAG_KEY},Value=${RUN_ID}}]" \
  --query 'Instances[0].InstanceId' --output text)"
CREATED_INSTANCE=1

echo "== waiting for SSM registration (needs the instance profile + agent up) =="
for _ in $(seq 1 30); do
  STATE="$(aws ssm describe-instance-information --region "$REGION" \
    --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "None")"
  [ "$STATE" = "Online" ] && break
  sleep 10
done
[ "$STATE" = "Online" ] || { echo "instance never registered with SSM (check instance-profile has AmazonSSMManagedInstanceCore)" >&2; exit 1; }

echo "== running egress test via SSM Run Command =="
TEST_ARGS="${ENDPOINTS[*]}"
CMD_ID="$(aws ssm send-command --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"for ep in ${TEST_ARGS}; do host=\\\${ep%%:*}; port=\\\${ep##*:}; timeout 5 bash -c \\\"cat < /dev/null > /dev/tcp/\\\$host/\\\$port\\\" 2>/dev/null && echo PASS \\\$ep || echo FAIL \\\$ep; done\"]" \
  --query 'Command.CommandId' --output text)"

for _ in $(seq 1 15); do
  STATUS="$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query 'Status' --output text 2>/dev/null || echo "Pending")"
  case "$STATUS" in Success|Failed) break ;; esac
  sleep 4
done

RESULT="$(aws ssm get-command-invocation --region "$REGION" \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' --output text)"

echo "== results =="
echo "$RESULT" | grep -E '^(PASS|FAIL) ' || echo "(no PASS/FAIL lines — command status: $STATUS)"

if echo "$RESULT" | grep -q '^FAIL '; then
  echo "== one or more endpoints unreachable — landing zone egress is NOT ready =="
  false
else
  echo "== all endpoints reachable — landing zone egress looks ready =="
fi
