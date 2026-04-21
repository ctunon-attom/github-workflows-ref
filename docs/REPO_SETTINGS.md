# Recommended Repository Settings

Settings to configure in GitHub repository Settings UI (or via API).

## General

| Setting | Value | Why |
|---------|-------|-----|
| Default branch | `master` | Production branch |
| Delete head branches on merge | **Enabled** | Prevents stale branch accumulation (33+ in audited repo) |
| Allow squash merging | **Enabled** | Clean, linear history |
| Allow merge commits | **Disabled** | Prevents noisy merge commits |
| Allow rebase merging | **Disabled** | One strategy = consistent history |
| Web commit sign-off required | Optional | Nice-to-have for compliance |

## Actions

| Setting | Value | Why |
|---------|-------|-----|
| Default GITHUB_TOKEN permissions | **Read repository contents** | Least privilege. Workflows declare their own permissions. |
| Allow Actions to create/approve PRs | **Disabled** | Prevents automated self-approval |
| Fork PR workflow approval | Require approval for all outside collaborators | Prevents unauthorized workflow execution |

## Branches

See [BRANCH_PROTECTION.md](BRANCH_PROTECTION.md) for branch protection rules.

## Environments

See [SECRET_SCOPING.md](SECRET_SCOPING.md) for environment configuration.

## Applying via API

```bash
# Set merge strategy to squash-only and enable auto-delete
gh api repos/OWNER/REPO -X PATCH \
  -f allow_squash_merge=true \
  -f allow_merge_commit=false \
  -f allow_rebase_merge=false \
  -f delete_branch_on_merge=true

# Set default GITHUB_TOKEN to read-only
gh api repos/OWNER/REPO/actions/permissions/workflow \
  -X PUT \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=false
```
