#!/usr/bin/env bash
# Scan all enabled regions for active resources to inform a region allowlist.
# Usage: AWS_PROFILE=<profile> ./aws-iam/scan-regions.sh

set -uo pipefail

PROFILE="${AWS_PROFILE:-default}"
export AWS_PROFILE="$PROFILE"
# No retries, short timeouts — we want fast scans, not durable ones.
export AWS_MAX_ATTEMPTS=1
export AWS_RETRY_MODE=standard
AWS_OPTS="--cli-read-timeout 6 --cli-connect-timeout 3 --no-cli-pager"

echo "Caller:"
aws sts get-caller-identity --output table
echo ""

REGIONS=$(aws ec2 describe-regions --region us-east-1 \
  --query 'Regions[?OptInStatus!=`not-opted-in`].RegionName' --output text)
n=$(echo "$REGIONS" | wc -w | tr -d ' ')
echo "Enabled regions: ${n}"
echo ""

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# Returns "0" on any failure (auth, timeout, etc.) so we don't hang.
count_safe() {
  local q="$1"; shift
  local out
  out=$("$@" --query "$q" --output text $AWS_OPTS 2>/dev/null)
  if [ -z "$out" ] || [ "$out" = "None" ]; then
    echo 0
  else
    echo "$out"
  fi
}

scan_region() {
  local r="$1"

  local ec2 rds lambdas ecs cfn ddb efs sm sfn elbv2 vpcs nat eks
  ec2=$(count_safe     'length(Reservations[].Instances[])'                      aws ec2 describe-instances --region "$r")
  rds=$(count_safe     'length(DBInstances)'                                     aws rds describe-db-instances --region "$r")
  lambdas=$(count_safe 'length(Functions)'                                       aws lambda list-functions --region "$r")
  ecs=$(count_safe     'length(clusterArns)'                                     aws ecs list-clusters --region "$r")
  cfn=$(count_safe     'length(StackSummaries[?StackStatus!=`DELETE_COMPLETE`])' aws cloudformation list-stacks --region "$r")
  ddb=$(count_safe     'length(TableNames)'                                      aws dynamodb list-tables --region "$r")
  efs=$(count_safe     'length(FileSystems)'                                     aws efs describe-file-systems --region "$r")
  sm=$(count_safe      'length(SecretList)'                                      aws secretsmanager list-secrets --region "$r")
  sfn=$(count_safe     'length(stateMachines)'                                   aws stepfunctions list-state-machines --region "$r")
  elbv2=$(count_safe   'length(LoadBalancers)'                                   aws elbv2 describe-load-balancers --region "$r")
  vpcs=$(count_safe    'length(Vpcs[?IsDefault==`false`])'                       aws ec2 describe-vpcs --region "$r")
  nat=$(count_safe     'length(NatGateways[?State==`available`])'                aws ec2 describe-nat-gateways --region "$r")
  eks=$(count_safe     'length(clusters)'                                        aws eks list-clusters --region "$r")

  local total=$((ec2 + rds + lambdas + ecs + cfn + ddb + efs + sm + sfn + elbv2 + vpcs + nat + eks))
  printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n" \
    "$r" "$total" "$ec2" "$rds" "$lambdas" "$ecs" "$cfn" "$ddb" "$efs" "$sm" "$sfn" "$elbv2" "$vpcs" "$nat" "$eks" >> "$TMP"
}

echo "Scanning ${n} regions in parallel..."
for r in $REGIONS; do
  scan_region "$r" &
done
wait
echo "Done scanning."
echo ""

echo "S3 buckets by region:"
aws s3api list-buckets --query 'Buckets[].Name' --output text $AWS_OPTS 2>/dev/null | tr '\t' '\n' | while read -r b; do
  [ -z "$b" ] && continue
  loc=$(aws s3api get-bucket-location --bucket "$b" --query 'LocationConstraint' --output text $AWS_OPTS 2>/dev/null || echo "?")
  [ "$loc" = "None" ] && loc="us-east-1"
  echo "$loc"
done | sort | uniq -c | sort -rn

echo ""
echo "Regional resources (rows with at least one resource, sorted by total):"
printf "%-16s %-6s | %4s %4s %4s %4s %4s %4s %4s %4s %4s %4s %4s %4s %4s\n" \
  "REGION" "TOTAL" "EC2" "RDS" "LAM" "ECS" "CFN" "DDB" "EFS" "SM" "SFN" "ELB" "VPC" "NAT" "EKS"
sort -t$'\t' -k2 -n -r "$TMP" | awk -F'\t' '$2 > 0 {
  printf "%-16s %-6s | %4s %4s %4s %4s %4s %4s %4s %4s %4s %4s %4s %4s %4s\n",
    $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15
}'

echo ""
echo "Regions with zero detected resources:"
sort "$TMP" | awk -F'\t' '$2 == 0 { print "  " $1 }'
