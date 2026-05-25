#!/usr/bin/env bash
# Shared IAM user management helpers for ACL group assignments.
# Source this file; do not run directly.

user_mgmt_read_tty_char() {
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

user_mgmt_read_tty_line() {
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

user_mgmt_prompt_yes_no() {
  local prompt="$1"
  local default_no="${2:-yes}"
  local ans

  if [ "$default_no" = "yes" ]; then
    ans="$(user_mgmt_read_tty_char "${prompt} [y/N]: ")"
    case "$ans" in
      y|Y) return 0 ;;
      *)   return 1 ;;
    esac
  fi

  ans="$(user_mgmt_read_tty_char "${prompt} [Y/n]: ")"
  case "$ans" in
    n|N) return 1 ;;
    *)   return 0 ;;
  esac
}

user_mgmt_role_to_group() {
  case "$1" in
    read-only)  printf '%s' "acl-read-only" ;;
    iam-admin)  printf '%s' "acl-iam-full-access" ;;
    power-user) printf '%s' "acl-power-users" ;;
    *)          return 1 ;;
  esac
}

user_mgmt_normalize_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-'
}

user_mgmt_valid_slug() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$ ]]
}

user_mgmt_build_username() {
  local identifier="$1"
  local account_name="$2"
  local role="$3"
  printf 'md-%s-%s-%s' "$identifier" "$account_name" "$role"
}

user_mgmt_prompt_account_name() {
  local raw account_name

  if [ -n "${ACCOUNT_NAME:-}" ]; then
    account_name="$(user_mgmt_normalize_slug "$ACCOUNT_NAME")"
    if user_mgmt_valid_slug "$account_name"; then
      echo "  Account name: ACCOUNT_NAME=${account_name}" >&2
      printf '%s' "$account_name"
      return 0
    fi
    echo "  Invalid ACCOUNT_NAME env var — falling back to prompt." >&2
  fi

  while true; do
    raw="$(user_mgmt_read_tty_line "  AWS account name (e.g. vincent — used in md-{identifier}-{account}-{role}): ")"
    account_name="$(user_mgmt_normalize_slug "$raw")"

    if user_mgmt_valid_slug "$account_name"; then
      if [ "$raw" != "$account_name" ]; then
        echo "  → account name: ${account_name}" >&2
      fi
      printf '%s' "$account_name"
      return 0
    fi

    echo "  Invalid account name — use lowercase letters, numbers, and hyphens." >&2
  done
}

user_mgmt_prompt_user_role() {
  local account_name="$1"
  local choice role

  while true; do
    echo "  Role (username will be md-{identifier}-${account_name}-{role}):" >&2
    echo "    1) read-only   → acl-read-only" >&2
    echo "    2) iam-admin   → acl-iam-full-access" >&2
    echo "    3) power-user  → acl-power-users" >&2
    choice="$(user_mgmt_read_tty_line "  Choice [1-3]: ")"
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

user_mgmt_normalize_identifier() {
  local raw="$1"
  local account_name="$2"
  local role="$3"
  local identifier="$raw"
  local known_role

  identifier="$(user_mgmt_normalize_slug "$identifier")"

  if [[ "$identifier" == md-* ]]; then
    identifier="${identifier#md-}"
  fi

  if [[ "$identifier" == *-"${role}" ]]; then
    identifier="${identifier%-${role}}"
  else
    for known_role in read-only iam-admin power-user; do
      if [[ "$identifier" == *-"${known_role}" ]]; then
        identifier="${identifier%-${known_role}}"
        break
      fi
    done
  fi

  if [[ "$identifier" == *-"${account_name}" ]]; then
    identifier="${identifier%-${account_name}}"
  fi

  printf '%s' "$identifier"
}

user_mgmt_prompt_user_identifier() {
  local account_name="$1"
  local role="$2"
  local raw identifier lower_raw expected_username

  expected_username="$(user_mgmt_build_username "{identifier}" "$account_name" "$role")"

  while true; do
    raw="$(user_mgmt_read_tty_line "  Identifier (e.g. declan, or full ${expected_username//\{identifier\}/declan}): ")"
    lower_raw="$(user_mgmt_normalize_slug "$raw")"
    identifier="$(user_mgmt_normalize_identifier "$raw" "$account_name" "$role")"

    if user_mgmt_valid_slug "$identifier"; then
      if [ "$lower_raw" != "$identifier" ]; then
        echo "  → parsed identifier: ${identifier}" >&2
      fi
      printf '%s' "$identifier"
      return 0
    fi

    echo "  Invalid identifier — use lowercase letters, numbers, and hyphens." >&2
    echo "  Tip: enter just the short name (e.g. declan)." >&2
  done
}

user_mgmt_ensure_user() {
  local username="$1"

  if aws iam get-user --user-name "$username" &>/dev/null; then
    echo "  User exists: ${username}"
  else
    echo "  Create user: ${username}"
    aws iam create-user --user-name "$username" --path / >/dev/null
  fi
}

user_mgmt_ensure_user_in_group() {
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

user_mgmt_create_cli_access_key() {
  local username="$1"
  local key_count access_key_id secret_access_key setup_cmd

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

  setup_cmd=" export AWS_ACCESS_KEY_ID='${access_key_id}' AWS_SECRET_ACCESS_KEY='${secret_access_key}' && aws-vault add ${username} --env --add-config && aws configure set aws_access_key_id \"\$AWS_ACCESS_KEY_ID\" --profile ${username} && aws configure set aws_secret_access_key \"\$AWS_SECRET_ACCESS_KEY\" --profile ${username} && aws configure set region us-east-1 --profile ${username}"

  echo ""
  echo "  CLI credentials for ${username} (secret shown once — copy now):"
  echo "  ────────────────────────────────────────────────────────────────"
  echo "  YOU MUST run the command below with a LEADING SPACE so it is not saved"
  echo "  to shell history — same idea as:  TEST=\"a\" && echo \$TEST"
  echo ""
  echo "${setup_cmd}"
  echo "  ────────────────────────────────────────────────────────────────"
  echo ""
}

user_mgmt_ensure_acl_groups_exist() {
  local group missing=0

  for group in acl-read-only acl-iam-full-access acl-power-users; do
    if ! aws iam get-group --group-name "$group" &>/dev/null; then
      echo "  Missing group: ${group}"
      missing=1
    fi
  done

  if [ "$missing" -eq 1 ]; then
    echo ""
    echo "  Run ./aws-iam/setup-acl-groups.sh first to create ACL groups and policies."
    return 1
  fi

  return 0
}

user_mgmt_create_users_interactive() {
  local account_name role identifier username group

  if ! [ -r /dev/tty ] && ! [ -t 0 ]; then
    echo "No TTY — run interactively to create users and access keys."
    echo "Tip: ACCOUNT_NAME=vincent can skip the account name prompt."
    return 1
  fi

  user_mgmt_ensure_acl_groups_exist || return 1
  echo ""

  account_name="$(user_mgmt_prompt_account_name)"
  echo ""

  while user_mgmt_prompt_yes_no "  Create another user?"; do
    echo ""
    role="$(user_mgmt_prompt_user_role "$account_name")"
    identifier="$(user_mgmt_prompt_user_identifier "$account_name" "$role")"
    username="$(user_mgmt_build_username "$identifier" "$account_name" "$role")"
    group="$(user_mgmt_role_to_group "$role")"

    echo ""
    echo "  → user: ${username}"
    echo "  → group: ${group}"
    echo ""

    user_mgmt_ensure_user "$username"
    user_mgmt_ensure_user_in_group "$username" "$group"
    user_mgmt_create_cli_access_key "$username" || true
    echo ""
  done
}
