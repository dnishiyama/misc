#!/usr/bin/env bash
# Scan enabled AWS regions for Bedrock resources (models, guardrails, agents, KBs, etc.).
#
# Usage:
#   AWS_PROFILE=<profile> ./aws-iam/scan-bedrock-regions.sh
#   VERBOSE=1 AWS_PROFILE=<profile> ./aws-iam/scan-bedrock-regions.sh   # print resource names/ARNs
#   REGIONS="us-east-1 us-west-2" AWS_PROFILE=<profile> ./aws-iam/scan-bedrock-regions.sh
#
# Notes:
# - Skips list-foundation-models (available in every Bedrock region; not "your" resources).
# - Inference profiles include AWS-managed profiles; see VERBOSE output to distinguish TYPE.
# - Some APIs return AccessDenied in regions without Bedrock — counted as 0, not an error row.

set -uo pipefail

PROFILE="${AWS_PROFILE:-default}"
export AWS_PROFILE="$PROFILE"
export AWS_MAX_ATTEMPTS=1
export AWS_RETRY_MODE=standard
AWS_OPTS=(--cli-read-timeout 8 --cli-connect-timeout 3 --no-cli-pager)
VERBOSE="${VERBOSE:-0}"

echo "Caller:"
aws sts get-caller-identity --output table
echo ""

if [ -n "${REGIONS:-}" ]; then
  REGIONS="$REGIONS"
else
  REGIONS=$(aws ec2 describe-regions --region us-east-1 \
    --query 'Regions[?OptInStatus!=`not-opted-in`].RegionName' --output text)
fi
n=$(echo "$REGIONS" | wc -w | tr -d ' ')
echo "Regions to scan: ${n}"
echo ""

TMP=$(mktemp)
DETAIL=$(mktemp)
trap 'rm -f "$TMP" "$DETAIL"' EXIT

# count_safe <jmespath-query> <aws subcommand...>
# Prints item count, or 0 on failure / empty.
# Uses JSON output so paginated list calls return one number (text output can emit one per page).
count_safe() {
  local q="$1"
  shift
  local out
  out=$("$@" --query "$q" --output json "${AWS_OPTS[@]}" 2>/dev/null) || { echo 0; return; }
  if [ -z "$out" ] || [ "$out" = "null" ] || [ "$out" = "None" ]; then
    echo 0
  else
    # Defensive: strip whitespace; should already be a single JSON integer.
    printf '%s' "$out" | tr -d '[:space:]'
  fi
}

# detail_safe <region> <label> <jq-query> <aws subcommand...>
detail_safe() {
  [ "$VERBOSE" = "1" ] || return 0
  local region="$1" label="$2" q="$3"
  shift 3
  local out
  out=$("$@" --query "$q" --output text "${AWS_OPTS[@]}" 2>/dev/null) || return 0
  [ -z "$out" ] || [ "$out" = "None" ] && return 0
  {
    echo "  [$region] $label"
    echo "$out" | tr '\t' '\n' | sed 's/^/    /'
  } >> "$DETAIL"
}

scan_region() {
  local r="$1"

  # bedrock control plane
  local custom imported guardrails infer prov prompt_routers
  local cust_jobs import_jobs copy_jobs eval_jobs invoke_jobs mkt_endpoints

  custom=$(count_safe 'length(modelSummaries)' \
    aws bedrock list-custom-models --region "$r")
  imported=$(count_safe 'length(modelSummaries)' \
    aws bedrock list-imported-models --region "$r")
  guardrails=$(count_safe 'length(guardrails)' \
    aws bedrock list-guardrails --region "$r")
  # APPLICATION = customer-created; SYSTEM profiles exist in every Bedrock region.
  infer=$(count_safe 'length(inferenceProfileSummaries[?type==`APPLICATION`])' \
    aws bedrock list-inference-profiles --region "$r")
  prov=$(count_safe 'length(provisionedModelSummaries)' \
    aws bedrock list-provisioned-model-throughputs --region "$r")
  prompt_routers=$(count_safe 'length(promptRouterSummaries)' \
    aws bedrock list-prompt-routers --region "$r")
  cust_jobs=$(count_safe 'length(modelCustomizationJobSummaries)' \
    aws bedrock list-model-customization-jobs --region "$r")
  import_jobs=$(count_safe 'length(modelImportJobSummaries)' \
    aws bedrock list-model-import-jobs --region "$r")
  copy_jobs=$(count_safe 'length(modelCopyJobSummaries)' \
    aws bedrock list-model-copy-jobs --region "$r")
  eval_jobs=$(count_safe 'length(jobSummaries)' \
    aws bedrock list-evaluation-jobs --region "$r")
  invoke_jobs=$(count_safe 'length(invocationJobSummaries)' \
    aws bedrock list-model-invocation-jobs --region "$r")
  mkt_endpoints=$(count_safe 'length(marketplaceModelEndpoints)' \
    aws bedrock list-marketplace-model-endpoints --region "$r")

  # bedrock agent
  local agents kbs flows prompts
  agents=$(count_safe 'length(agentSummaries)' \
    aws bedrock-agent list-agents --region "$r")
  kbs=$(count_safe 'length(knowledgeBaseSummaries)' \
    aws bedrock-agent list-knowledge-bases --region "$r")
  flows=$(count_safe 'length(flowSummaries)' \
    aws bedrock-agent list-flows --region "$r")
  prompts=$(count_safe 'length(promptSummaries)' \
    aws bedrock-agent list-prompts --region "$r")

  # bedrock data automation
  local bda_projects bda_blueprints
  bda_projects=$(count_safe 'length(projects)' \
    aws bedrock-data-automation list-data-automation-projects --region "$r")
  bda_blueprints=$(count_safe 'length(blueprints)' \
    aws bedrock-data-automation list-blueprints --region "$r")

  local total=$((custom + imported + guardrails + infer + prov + prompt_routers \
    + cust_jobs + import_jobs + copy_jobs + eval_jobs + invoke_jobs + mkt_endpoints \
    + agents + kbs + flows + prompts + bda_projects + bda_blueprints))

  printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n" \
    "$r" "$total" \
    "$custom" "$imported" "$guardrails" "$infer" "$prov" "$prompt_routers" \
    "$cust_jobs" "$import_jobs" "$copy_jobs" "$eval_jobs" "$invoke_jobs" "$mkt_endpoints" \
    "$agents" "$kbs" "$flows" "$prompts" "$bda_projects" "$bda_blueprints" >> "$TMP"

  if [ "$VERBOSE" = "1" ] && [ "$total" -gt 0 ]; then
    detail_safe "$r" "custom-models" 'modelSummaries[].{name:modelName,arn:modelArn,status:modelStatus}' \
      aws bedrock list-custom-models --region "$r"
    detail_safe "$r" "imported-models" 'modelSummaries[].{name:modelName,arn:modelArn}' \
      aws bedrock list-imported-models --region "$r"
    detail_safe "$r" "guardrails" 'guardrails[].{name:name,id:id,status:status}' \
      aws bedrock list-guardrails --region "$r"
    detail_safe "$r" "inference-profiles (APPLICATION)" \
      'inferenceProfileSummaries[?type==`APPLICATION`].{name:inferenceProfileName,type:type,arn:inferenceProfileArn}' \
      aws bedrock list-inference-profiles --region "$r"
    detail_safe "$r" "provisioned-throughput" 'provisionedModelSummaries[].{name:provisionedModelName,arn:provisionedModelArn,status:status}' \
      aws bedrock list-provisioned-model-throughputs --region "$r"
    detail_safe "$r" "prompt-routers" 'promptRouterSummaries[].{name:promptRouterName,arn:promptRouterArn,status:status}' \
      aws bedrock list-prompt-routers --region "$r"
    detail_safe "$r" "customization-jobs" 'modelCustomizationJobSummaries[].{name:jobName,arn:jobArn,status:status}' \
      aws bedrock list-model-customization-jobs --region "$r"
    detail_safe "$r" "import-jobs" 'modelImportJobSummaries[].{name:jobName,arn:jobArn,status:status}' \
      aws bedrock list-model-import-jobs --region "$r"
    detail_safe "$r" "agents" 'agentSummaries[].{name:agentName,id:agentId,status:agentStatus}' \
      aws bedrock-agent list-agents --region "$r"
    detail_safe "$r" "knowledge-bases" 'knowledgeBaseSummaries[].{name:name,id:knowledgeBaseId,status:status}' \
      aws bedrock-agent list-knowledge-bases --region "$r"
    detail_safe "$r" "flows" 'flowSummaries[].{name:name,id:id,status:status}' \
      aws bedrock-agent list-flows --region "$r"
    detail_safe "$r" "prompts" 'promptSummaries[].{name:name,id:id}' \
      aws bedrock-agent list-prompts --region "$r"
    detail_safe "$r" "data-automation-projects" 'projects[].{name:projectName,arn:projectArn,stage:projectStage}' \
      aws bedrock-data-automation list-data-automation-projects --region "$r"
    detail_safe "$r" "data-automation-blueprints" 'blueprints[].{name:blueprintName,arn:blueprintArn,stage:blueprintStage}' \
      aws bedrock-data-automation list-blueprints --region "$r"
  fi
}

echo "Scanning ${n} regions in parallel..."
for r in $REGIONS; do
  scan_region "$r" &
done
wait
echo "Done scanning."
echo ""

echo "Bedrock resources by region (non-zero rows, sorted by total):"
printf "%-16s %-5s | %3s %3s %3s %3s %3s %3s %3s %3s %3s %3s %3s %3s %3s %3s %3s %3s %3s %3s\n" \
  "REGION" "TOTAL" \
  "CUS" "IMP" "GRD" "INF" "PRV" "PRT" \
  "CJB" "IJB" "CPJ" "EVJ" "IVJ" "MKT" \
  "AGT" "KB" "FLW" "PRM" "BDA" "BDB"
printf "%-16s %-5s-+-------------------------------------------------------------------------------------------\n" "----------------" "-----"

sort -t$'\t' -k2 -n -r "$TMP" | awk -F'\t' '$2 > 0 {
  printf "%-16s %-5s | %3s %3s %3s %3s %3s %3s %3s %3s %3s %3s %3s %3s %3s %3s %3s %3s %3s %3s\n",
    $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20
}'

echo ""
echo "Column key:"
echo "  CUS=custom-models  IMP=imported-models  GRD=guardrails  INF=inference-profiles (APPLICATION only)"
echo "  PRV=provisioned-throughput  PRT=prompt-routers  CJB=customization-jobs  IJB=import-jobs"
echo "  CPJ=copy-jobs  EVJ=evaluation-jobs  IVJ=model-invocation-jobs  MKT=marketplace-endpoints"
echo "  AGT=agents  KB=knowledge-bases  FLW=flows  PRM=prompts"
echo "  BDA=data-automation-projects  BDB=data-automation-blueprints"
echo ""
echo "Regions with zero detected Bedrock resources:"
sort "$TMP" | awk -F'\t' '$2 == 0 { print "  " $1 }'

if [ "$VERBOSE" = "1" ] && [ -s "$DETAIL" ]; then
  echo ""
  echo "Resource details (VERBOSE=1):"
  cat "$DETAIL"
fi
