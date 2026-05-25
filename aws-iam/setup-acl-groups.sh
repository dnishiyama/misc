#!/usr/bin/env bash
# Portable: run on any AWS account as root or a user with IAMFullAccess.
#   AWS_PROFILE=md-iam-admin ./aws-iam/setup-acl-groups.sh
#
# Creates if missing (idempotent):
#   Groups:   acl-admin-do-not-use, acl-iam-full-access, acl-power-users, acl-read-only
#   Policies: UserAdminsWriteList, UserAdminsDenyList, UserAdminsSelfServiceIAM
#
# Attaches the right policies to each group. Detaches legacy policies if found.
# Optionally creates IAM users (md-{identifier}-{role}) and prints CLI access keys.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "Caller:"
aws sts get-caller-identity --output table
echo ""

# ------------------------------------------------------------------------
# Region restriction — ask before any IAM changes
# Override: RESTRICT_REGIONS=yes|no ./setup-acl-groups.sh
# ------------------------------------------------------------------------
resolve_restrict_regions() {
  local ans old_stty
  if [ -n "${RESTRICT_REGIONS:-}" ]; then
    echo "Region restriction: RESTRICT_REGIONS=${RESTRICT_REGIONS}"
    restrict="${RESTRICT_REGIONS}"
    return
  fi

  echo "Region restriction"
  echo "  The policy UserAdminsDenyRegionsList limits acl-power-users to a hard-coded"
  echo "  region allowlist (see user-admins-deny-regions-list.json). Most accounts"
  echo "  should leave this OFF unless you have a strong reason."

  ans=""
  if [ -r /dev/tty ]; then
    # IDE terminals often send CR (^M) without LF; read -n 1 avoids needing Enter.
    old_stty=$(stty -g </dev/tty 2>/dev/null) || old_stty=""
    stty sane icrnl </dev/tty 2>/dev/null || true
    printf "  Attach region restriction to acl-power-users? [y/N] (press y or n): " >/dev/tty
    IFS= read -r -n 1 ans </dev/tty 2>/dev/null || ans=""
    printf "\n" >/dev/tty
    if [ -n "$old_stty" ]; then
      stty "$old_stty" </dev/tty 2>/dev/null || stty sane </dev/tty 2>/dev/null || true
    fi
  elif [ -t 0 ]; then
    stty sane icrnl 2>/dev/null || true
    IFS= read -r -n 1 -p "  Attach region restriction to acl-power-users? [y/N] (press y or n): " ans || ans=""
    echo ""
  else
    echo "  No TTY and RESTRICT_REGIONS unset — defaulting to no."
    echo "  Tip: RESTRICT_REGIONS=yes|no ./setup-acl-groups.sh"
    ans=""
  fi

  ans="${ans//$'\r'/}"
  ans="${ans//$'\n'/}"
  case "$ans" in
    y|Y) restrict="yes" ;;
    *)   restrict="no"  ;;
  esac
  echo "  → ${restrict}"
  echo ""
}

restrict=""
resolve_restrict_regions

# ------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------

ensure_group() {
  local name="$1"
  if aws iam get-group --group-name "$name" &>/dev/null; then
    echo "  Group exists: ${name}"
  else
    echo "  Create group: ${name}"
    aws iam create-group --group-name "$name" --path / >/dev/null
  fi
}

publish_policy() {
  local name="$1"
  local file="$2"
  local arn="arn:aws:iam::${ACCOUNT_ID}:policy/${name}"

  if aws iam get-policy --policy-arn "$arn" &>/dev/null; then
    # IAM caps managed policies at 5 versions. Drop oldest non-default if at limit.
    local non_default_count
    non_default_count=$(aws iam list-policy-versions --policy-arn "$arn" \
      --query 'length(Versions[?IsDefaultVersion==`false`])' --output text)
    if [ "$non_default_count" -ge 4 ]; then
      local oldest
      oldest=$(aws iam list-policy-versions --policy-arn "$arn" \
        --query 'Versions[?IsDefaultVersion==`false`] | sort_by(@, &CreateDate)[0].VersionId' \
        --output text)
      echo "  Prune oldest version of ${name}: ${oldest}"
      aws iam delete-policy-version --policy-arn "$arn" --version-id "$oldest"
    fi
    echo "  Update policy: ${name}"
    aws iam create-policy-version \
      --policy-arn "$arn" \
      --policy-document "file://${file}" \
      --set-as-default >/dev/null
  else
    echo "  Create policy: ${name}"
    aws iam create-policy \
      --policy-name "$name" \
      --policy-document "file://${file}" \
      --description "ACL: ${name}" >/dev/null
  fi
}

attach() {
  local group="$1"
  local arn="$2"
  if aws iam list-attached-group-policies --group-name "$group" \
    --query "AttachedPolicies[?PolicyArn=='${arn}'].PolicyArn" --output text | grep -q .; then
    echo "  [${group}] already attached: ${arn##*/}"
  else
    echo "  [${group}] attach: ${arn##*/}"
    aws iam attach-group-policy --group-name "$group" --policy-arn "$arn"
  fi
}

detach() {
  local group="$1"
  local arn="$2"
  if aws iam list-attached-group-policies --group-name "$group" \
    --query "AttachedPolicies[?PolicyArn=='${arn}'].PolicyArn" --output text | grep -q .; then
    echo "  [${group}] detach legacy: ${arn##*/}"
    aws iam detach-group-policy --group-name "$group" --policy-arn "$arn"
  fi
}

read_tty_char() {
  local prompt="$1"
  local old_stty ans=""

  if [ -r /dev/tty ]; then
    old_stty=$(stty -g </dev/tty 2>/dev/null) || old_stty=""
    stty sane icrnl </dev/tty 2>/dev/null || true
    printf "%s" "$prompt" >/dev/tty
    IFS= read -r -n 1 ans </dev/tty 2>/dev/null || ans=""
    printf "\n" >/dev/tty
    if [ -n "$old_stty" ]; then
      stty "$old_stty" </dev/tty 2>/dev/null || stty sane </dev/tty 2>/dev/null || true
    fi
  elif [ -t 0 ]; then
    stty sane icrnl 2>/dev/null || true
    IFS= read -r -n 1 -p "$prompt" ans || ans=""
    echo ""
  fi

  ans="${ans//$'\r'/}"
  ans="${ans//$'\n'/}"
  printf '%s' "$ans"
}

read_tty_line() {
  local prompt="$1"
  local old_stty line=""

  if [ -r /dev/tty ]; then
    old_stty=$(stty -g </dev/tty 2>/dev/null) || old_stty=""
    stty sane icrnl </dev/tty 2>/dev/null || true
    printf "%s" "$prompt" >/dev/tty
    IFS= read -r line </dev/tty 2>/dev/null || line=""
    if [ -n "$old_stty" ]; then
      stty "$old_stty" </dev/tty 2>/dev/null || stty sane </dev/tty 2>/dev/null || true
    fi
  elif [ -t 0 ]; then
    stty sane icrnl 2>/dev/null || true
    IFS= read -r -p "$prompt" line || line=""
  fi

  line="${line//$'\r'/}"
  printf '%s' "$line"
}

prompt_yes_no() {
  local prompt="$1"
  local default_no="${2:-yes}"
  local ans

  if [ "$default_no" = "yes" ]; then
    ans="$(read_tty_char "${prompt} [y/N]: ")"
    case "$ans" in
      y|Y) return 0 ;;
      *)   return 1 ;;
    esac
  fi

  ans="$(read_tty_char "${prompt} [Y/n]: ")"
  case "$ans" in
    n|N) return 1 ;;
    *)   return 0 ;;
  esac
}

role_to_group() {
  case "$1" in
    read-only)  printf '%s' "acl-read-only" ;;
    iam-admin)  printf '%s' "acl-iam-full-access" ;;
    power-user) printf '%s' "acl-power-users" ;;
    *)          return 1 ;;
  esac
}

prompt_user_role() {
  local choice role

  while true; do
    echo "  Role (username will be md-{identifier}-{role}):" >&2
    echo "    1) read-only   → acl-read-only" >&2
    echo "    2) iam-admin   → acl-iam-full-access" >&2
    echo "    3) power-user  → acl-power-users" >&2
    choice="$(read_tty_line "  Choice [1-3]: ")"
    case "$choice" in
      1|read-only)  role="read-only"; break ;;
      2|iam-admin)  role="iam-admin"; break ;;
      3|power-user) role="power-user"; break ;;
      *)
        echo "  Invalid choice — enter 1, 2, 3, or the role name." >&2
        ;;
    esac
  done

  printf '%s' "$role"
}

normalize_identifier() {
  local raw="$1"
  local role="$2"
  local identifier="$raw"
  local known_role

  identifier="$(printf '%s' "$identifier" | tr '[:upper:]' '[:lower:]')"
  identifier="${identifier// /-}"

  if [[ "$identifier" == md-* ]]; then
    identifier="${identifier#md-}"
  fi

  if [[ "$identifier" == *-"${role}" ]]; then
    identifier="${identifier%-${role}}"
  else
    for known_role in read-only iam-admin power-user; do
      if [[ "$identifier" == *-"${known_role}" ]]; then
        echo "  Note: input looks like md-{identifier}-${known_role}; using identifier \"${identifier%-${known_role}}\"." >&2
        identifier="${identifier%-${known_role}}"
        break
      fi
    done
  fi

  printf '%s' "$identifier"
}

prompt_user_identifier() {
  local role="$1"
  local raw identifier lower_raw

  while true; do
    raw="$(read_tty_line "  Identifier (e.g. declan, or full md-declan-${role}): ")"
    lower_raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    lower_raw="${lower_raw// /-}"
    identifier="$(normalize_identifier "$raw" "$role")"

    if [[ "$identifier" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$ ]]; then
      if [ "$lower_raw" != "$identifier" ]; then
        echo "  → parsed identifier: ${identifier}" >&2
      fi
      printf '%s' "$identifier"
      return 0
    fi

    echo "  Invalid identifier — use lowercase letters, numbers, and hyphens." >&2
    echo "  Tip: enter just the short name (e.g. declan), not the full username." >&2
  done
}

ensure_user() {
  local username="$1"

  if aws iam get-user --user-name "$username" &>/dev/null; then
    echo "  User exists: ${username}"
  else
    echo "  Create user: ${username}"
    aws iam create-user --user-name "$username" --path / >/dev/null
  fi
}

ensure_user_in_group() {
  local username="$1"
  local group="$2"

  if aws iam get-group --group-name "$group" \
    --query "Users[?UserName=='${username}'].UserName" --output text | grep -q .; then
    echo "  Already in group: ${group}"
  else
    echo "  Add to group: ${group}"
    aws iam add-user-to-group --user-name "$username" --group-name "$group"
  fi
}

create_cli_access_key() {
  local username="$1"
  local key_count access_key_id secret_access_key

  key_count="$(aws iam list-access-keys --user-name "$username" \
    --query 'length(AccessKeyMetadata)' --output text)"
  if [ "$key_count" -ge 2 ]; then
    echo "  WARNING: ${username} already has 2 access keys (AWS max)."
    echo "  Delete an existing key before creating a new one."
    return 1
  fi

  read -r access_key_id secret_access_key < <(
    aws iam create-access-key --user-name "$username" \
      --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text
  )

  echo ""
  echo "  CLI credentials for ${username} (secret shown once — copy now):"
  echo "  ────────────────────────────────────────────────────────────────"
  echo "  AWS_ACCESS_KEY_ID=${access_key_id}"
  echo "  AWS_SECRET_ACCESS_KEY=${secret_access_key}"
  echo ""
  echo "  aws configure set aws_access_key_id ${access_key_id} --profile ${username}"
  echo "  aws configure set aws_secret_access_key ${secret_access_key} --profile ${username}"
  echo "  aws configure set region us-east-1 --profile ${username}"
  echo "  ────────────────────────────────────────────────────────────────"
  echo ""
}

create_users_interactive() {
  local role identifier username group

  if ! [ -r /dev/tty ] && ! [ -t 0 ]; then
    echo "7. Skipping user creation (no TTY)."
    echo "   Run interactively to create users and access keys."
    return 0
  fi

  echo "7. Create IAM users (optional)"
  echo ""

  while prompt_yes_no "  Create another user?"; do
    echo ""
    role="$(prompt_user_role)"
    identifier="$(prompt_user_identifier "$role")"
    username="md-${identifier}-${role}"
    group="$(role_to_group "$role")"

    echo ""
    echo "  → user: ${username}"
    echo "  → group: ${group}"
    echo ""

    ensure_user "$username"
    ensure_user_in_group "$username" "$group"
    create_cli_access_key "$username" || true
    echo ""
  done
}

# ------------------------------------------------------------------------
# 1. Groups
# ------------------------------------------------------------------------
echo "1. Ensure groups exist..."
ensure_group "acl-admin-do-not-use"
ensure_group "acl-iam-full-access"
ensure_group "acl-power-users"
ensure_group "acl-read-only"
echo ""

# ------------------------------------------------------------------------
# 2. Custom policies
# ------------------------------------------------------------------------
echo "2. Publish custom policies..."
publish_policy "UserAdminsWriteList"       "${SCRIPT_DIR}/user-admins-write-list.json"
publish_policy "UserAdminsDenyList"        "${SCRIPT_DIR}/user-admins-deny-list.json"
publish_policy "UserAdminsSelfServiceIAM"  "${SCRIPT_DIR}/user-admins-self-service-iam.json"
publish_policy "UserAdminsDenyRegionsList" "${SCRIPT_DIR}/user-admins-deny-regions-list.json"
publish_policy "sts-federation"            "${SCRIPT_DIR}/sts-federation.json"
echo ""

ADMIN="arn:aws:iam::aws:policy/AdministratorAccess"
IAM_FULL="arn:aws:iam::aws:policy/IAMFullAccess"
READ_ONLY="arn:aws:iam::aws:policy/ReadOnlyAccess"
WRITE_LIST="arn:aws:iam::${ACCOUNT_ID}:policy/UserAdminsWriteList"
DENY_LIST="arn:aws:iam::${ACCOUNT_ID}:policy/UserAdminsDenyList"
SELF_SERVICE="arn:aws:iam::${ACCOUNT_ID}:policy/UserAdminsSelfServiceIAM"
DENY_REGIONS="arn:aws:iam::${ACCOUNT_ID}:policy/UserAdminsDenyRegionsList"
STS_FEDERATION="arn:aws:iam::${ACCOUNT_ID}:policy/sts-federation"

# ------------------------------------------------------------------------
# 3. Attach policies per group
# ------------------------------------------------------------------------
echo "3. Attach policies to groups..."

# acl-admin-do-not-use — break-glass only
attach "acl-admin-do-not-use" "$ADMIN"

# acl-iam-full-access — IAM writes + read everything; no UserAdminsDenyList
# Use acl-admin-do-not-use when elevated/break-glass permissions are needed.
attach "acl-iam-full-access" "$IAM_FULL"
attach "acl-iam-full-access" "$READ_ONLY"
attach "acl-iam-full-access" "$SELF_SERVICE"
attach "acl-iam-full-access" "$STS_FEDERATION"
detach "acl-iam-full-access" "$DENY_LIST"

# acl-power-users — daily operator
attach "acl-power-users" "$READ_ONLY"
attach "acl-power-users" "$WRITE_LIST"
attach "acl-power-users" "$DENY_LIST"
attach "acl-power-users" "$SELF_SERVICE"

# acl-read-only — audit/observer
attach "acl-read-only" "$READ_ONLY"
attach "acl-read-only" "$STS_FEDERATION"
echo ""

# ------------------------------------------------------------------------
# 4. Region restriction attachment (decision made at start)
# ------------------------------------------------------------------------
echo "4. Apply region restriction to acl-power-users..."
if [ "$restrict" = "yes" ]; then
  attach "acl-power-users" "$DENY_REGIONS"
else
  detach "acl-power-users" "$DENY_REGIONS"
fi
echo ""

# ------------------------------------------------------------------------
# 5. Detach known legacy attachments
# ------------------------------------------------------------------------
echo "5. Detach legacy policies (if present)..."
LEGACY_POWER_USER="arn:aws:iam::aws:policy/PowerUserAccess"
LEGACY_IAM_RO="arn:aws:iam::aws:policy/IAMReadOnlyAccess"
LEGACY_ALLOW="arn:aws:iam::${ACCOUNT_ID}:policy/UserAdminsAllowList"
LEGACY_DENY_SVCS="arn:aws:iam::${ACCOUNT_ID}:policy/UserAdminsDenyListServices"
LEGACY_DENY_GPU="arn:aws:iam::${ACCOUNT_ID}:policy/UserAdminsDenyListGpu"

for g in acl-admin-do-not-use acl-iam-full-access acl-power-users acl-read-only; do
  detach "$g" "$LEGACY_POWER_USER"
  detach "$g" "$LEGACY_IAM_RO"
  detach "$g" "$LEGACY_ALLOW"
  detach "$g" "$LEGACY_DENY_SVCS"
  detach "$g" "$LEGACY_DENY_GPU"
done
echo ""

# ------------------------------------------------------------------------
# 6. Final state
# ------------------------------------------------------------------------
echo "6. Final state:"
for g in acl-admin-do-not-use acl-iam-full-access acl-power-users acl-read-only; do
  echo ""
  echo "=== ${g} ==="
  aws iam list-attached-group-policies --group-name "$g" \
    --query 'AttachedPolicies[].PolicyName' --output table
done

echo ""

create_users_interactive

echo "Done."
