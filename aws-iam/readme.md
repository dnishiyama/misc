# AWS IAM groups & policies

Portable IAM setup for any AWS account. One script, four groups, four custom policies.

## Groups

| Group                  | Use case                                                                                                                                                          | Attached policies                                                                         |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `acl-admin-do-not-use` | Break-glass only. Use root or this group to bootstrap or recover. Do not assign daily.                                                                            | `AdministratorAccess`                                                                     |
| `acl-iam-full-access`  | Manages users, groups, roles, policies. Read-only on all services via `ReadOnlyAccess`. No `UserAdminsDenyList` — use `acl-admin-do-not-use` for elevated access. | `IAMFullAccess`, `ReadOnlyAccess`, `UserAdminsSelfServiceIAM`, `sts-federation`           |
| `acl-power-users`      | Day-to-day operator. Read everything (except AI), write only on approved services.                                                                                | `ReadOnlyAccess`, `UserAdminsWriteList`, `UserAdminsDenyList`, `UserAdminsSelfServiceIAM` |
| `acl-read-only`        | Audit/observer. Reads only. Safe default for new users.                                                                                                           | `ReadOnlyAccess`, `sts-federation`                                                        |

## Custom policies (defined in this repo)

| Policy                     | File                                                                     | Purpose                                                                                                                                                                                                                                     |
| -------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `UserAdminsWriteList`      | [`user-admins-write-list.json`](user-admins-write-list.json)             | Write actions for approved services (EC2, S3, RDS, Lambda, ECS/ECR, CFN, CW, SSM, ACM, Secrets Manager, KMS use, SNS/SQS/SES, DynamoDB, Backup, Step Functions, CloudShell, EventBridge Scheduler, AWS Support, Health, Trusted Advisor, …) |
| `UserAdminsDenyList`       | [`user-admins-deny-list.json`](user-admins-deny-list.json)               | Hard deny that wins over everything: AI services, org/account writes, billing mutations, CloudTrail tamper, KMS destroy, Neptune via RDS, expensive GPU EC2, MWAA, Transfer Family, Shield subscriptions                                    |
| `UserAdminsSelfServiceIAM` | [`user-admins-self-service-iam.json`](user-admins-self-service-iam.json) | Each user can change own password, MFA, access keys — nothing else IAM                                                                                                                                                                      |
| `sts-federation`           | [`sts-federation.json`](sts-federation.json)                             | `sts:GetFederationToken` + `sts:GetCallerIdentity` for IAM admins to mint federated sessions                                                                                                                                                |

## Deploy

Requires root or an IAM admin (`IAMFullAccess`) on the target account.

```bash
AWS_PROFILE=<profile-with-iam-admin> ./aws-iam/setup-acl-groups.sh
```

The script:

1. Creates all four groups if missing.
2. Creates the three custom policies if missing; otherwise publishes a new version and sets it as default (auto-prunes oldest non-default version if at the 5-version limit).
3. Attaches the correct managed and custom policies to each group (idempotent).
4. Detaches legacy policies (`PowerUserAccess`, `IAMReadOnlyAccess`, old split deny policies) if present.
5. Prints a per-group attachment table at the end.

Account-agnostic — it reads the account ID via `sts:GetCallerIdentity`, no hardcoded IDs.

## After deploy — assigning users

```bash
# Standard operator
aws iam add-user-to-group --user-name jane --group-name acl-power-users

# Read-only auditor
aws iam add-user-to-group --user-name auditor --group-name acl-read-only

# Dedicated IAM admin (e.g. declan-iam-admin) — IAM writes + account-wide read
aws iam add-user-to-group --user-name iamadmin --group-name acl-iam-full-access

# Temporary elevated access — remove when done
aws iam add-user-to-group --user-name iamadmin --group-name acl-admin-do-not-use
aws iam remove-user-from-group --user-name iamadmin --group-name acl-admin-do-not-use

# Move a user
aws iam remove-user-from-group --user-name jane --group-name acl-read-only
aws iam add-user-to-group        --user-name jane --group-name acl-power-users

# Check membership
aws iam list-groups-for-user --user-name jane
```

`acl-admin-do-not-use` should usually have **zero** members. Keep root credentials offline; add yourself to this group only when you need elevated permissions (e.g. Bedrock, billing writes, org changes), then remove membership when done.

`acl-iam-full-access` is for day-to-day IAM administration with full read visibility across the account. It does **not** carry `UserAdminsDenyList`; hard blocks for AI, billing mutations, etc. apply only to `acl-power-users`.

## Writes allowed for power-users

| Area                 | Services                                                                                                                            |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Compute & network    | EC2 (incl. VPC), ELB, Auto Scaling, Lambda, ECS, ECR, EFS, Route53, CloudFront, API Gateway, Cloud Map                              |
| Data                 | S3, RDS (+ Performance Insights), DynamoDB, Backup                                                                                  |
| Deploy & ops         | CloudFormation, CloudWatch, Logs, EventBridge, EventBridge Scheduler, Step Functions, SSM, CloudTrail, X-Ray, CloudShell            |
| Security & messaging | ACM, Secrets Manager, KMS (use, not destroy), SNS, SQS, SES                                                                         |
| Misc                 | Resource Groups, Tags, RAM, narrow STS, IAM PassRole (scoped), service-linked roles, AWS Support, Health Dashboard, Trusted Advisor |

**Not in the write list → reads only:** Redshift, EMR, OpenSearch, MSK, ElastiCache, WorkSpaces, AppStream, Glue, Athena, Marketplace, App Runner, Beanstalk, Lightsail, Code\* services, and anything else not listed.

## Hard denies (overrides everything)

| Statement                 | Blocks                                                                                                                                                         |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DenyAIServices`          | All actions on Bedrock, SageMaker, Comprehend, Rekognition, Textract, Personalize, Forecast, Lex, Polly, Translate, Transcribe, Kendra, Q. **No read either.** |
| `DenyOrgAndAccountWrites` | All `organizations:*`; `account:CloseAccount/EnableRegion/DisableRegion/PutAccountName/PutAlternateContact/…`                                                  |
| `DenyBillingMutations`    | Write actions on billing, budgets, savings plans, purchase orders, CUR (reads stay allowed)                                                                    |
| `DenyExpensiveServices`   | `mwaa:*`, `transfer:Create/UpdateServer`, `shield:Create*`                                                                                                     |
| `DenyCloudTrailTampering` | `cloudtrail:Stop/Delete/UpdateTrail`, `PutEventSelectors`, `DeleteEventDataStore`                                                                              |
| `DenyKMSDestruction`      | `kms:ScheduleKeyDeletion`, `DisableKey`, `DisableKeyRotation`                                                                                                  |
| `DenyNeptuneViaRds`       | RDS create/modify where `rds:DatabaseEngine == neptune`                                                                                                        |
| `DenyExpensiveGpuEc2`     | EC2 launches/modifies for `p*`, `g*`, `inf*`, `trn*`, `dl*`, `f*`, `vt*`, `u-*tb*.metal`, `x2i*`                                                               |

## Verifying behavior

```bash
USER=jane
ARN="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):user/$USER"

aws iam simulate-principal-policy \
  --policy-source-arn "$ARN" \
  --resource-arns "*" \
  --action-names \
    ec2:RunInstances s3:PutObject lambda:CreateFunction dynamodb:CreateTable \
    redshift:DescribeClusters redshift:CreateCluster \
    bedrock:ListFoundationModels bedrock:InvokeModel \
    mwaa:CreateEnvironment transfer:CreateServer shield:CreateSubscription \
    organizations:ListAccounts cloudtrail:StopLogging kms:ScheduleKeyDeletion \
    iam:ListUsers iam:CreateUser \
  --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision}' \
  --output table
```

Expected:

- Approved writes (`ec2:RunInstances`, `s3:PutObject`, `lambda:CreateFunction`, `dynamodb:CreateTable`) → `allowed`
- Reads via `ReadOnlyAccess` (`redshift:DescribeClusters`, `iam:ListUsers`) → `allowed`
- Implicit deny (`redshift:CreateCluster`, `iam:CreateUser`) → `implicitDeny`
- Explicit deny (AI, MWAA, Transfer, Shield, org, CT tamper, KMS destroy) → `explicitDeny`

## CloudFormation note

CloudFormation create/update actions run with the _deployer's_ IAM permissions unless the stack specifies a separate execution role. If you give an `acl-power-users` member a stack execution role with `AdministratorAccess`, the guardrails are bypassed during stack runs. Always use scoped execution roles, ideally derived from `UserAdminsWriteList`.

## Adding a new service later

| Goal             | Where to change                                                                                               |
| ---------------- | ------------------------------------------------------------------------------------------------------------- |
| Allow reads only | Already covered by `ReadOnlyAccess`. No change needed.                                                        |
| Allow writes     | Add a narrow allow to [`user-admins-write-list.json`](user-admins-write-list.json), then re-run setup script. |
| Hard block       | Add to [`user-admins-deny-list.json`](user-admins-deny-list.json), then re-run setup script.                  |
