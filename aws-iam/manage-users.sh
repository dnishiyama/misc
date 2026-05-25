#!/usr/bin/env bash
# Interactive IAM user management for ACL groups.
#   AWS_PROFILE=md-iam-admin ./aws-iam/manage-users.sh
#   ACCOUNT_NAME=vincent AWS_PROFILE=md-iam-admin ./aws-iam/manage-users.sh
#
# Creates md-{identifier}-{account}-{role} users, assigns ACL groups,
# and prints a one-line aws-vault + ~/.aws/credentials setup command.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=user-management-lib.sh
source "${SCRIPT_DIR}/user-management-lib.sh"

echo "AWS IAM user management"
echo ""
echo "Caller:"
aws sts get-caller-identity --output table
echo ""

user_mgmt_create_users_interactive

echo "Done."
