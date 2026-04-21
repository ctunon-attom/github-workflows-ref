# Branch Protection Rules

These rules **cannot** be enforced on a private repo under GitHub Free (personal account). They should be enabled when upgrading to **GitHub Pro** or transferring to a **GitHub Organization** on Team+.

## `master` (production)

| Rule | Setting |
|------|---------|
| Require pull request before merging | Yes |
| Required approving reviews | 1 |
| Dismiss stale PR approvals on new commits | Yes |
| Require review from Code Owners | Yes |
| Require status checks to pass | `CI / test`, `CI / lint` |
| Require branches to be up to date | Yes |
| Require conversation resolution | Yes |
| Require signed commits | Yes |
| Block force pushes | Yes |
| Block branch deletion | Yes |
| Allow admins to bypass | **No** (hard gate on production) |

## `staging`

Same as `master` except:

| Rule | Setting |
|------|---------|
| Allow admins to bypass | Yes (staging is less critical) |

## `develop`

| Rule | Setting |
|------|---------|
| Require pull request before merging | Optional (fast iteration) |
| Required approving reviews | 0 |
| Require status checks to pass | `CI / test`, `CI / lint` |
| Block force pushes | Yes |
| Block branch deletion | Yes |
| Allow admins to bypass | Yes |

## Rulesets vs Classic Protection

GitHub rulesets are the modern replacement for branch protection rules. Advantages:

- **Pattern matching**: a single ruleset can cover `master` and `staging` with `refs/heads/master,refs/heads/staging`.
- **Layered rules**: multiple rulesets can apply to the same branch (e.g. one org-wide, one repo-specific).
- **Bypass actors**: fine-grained control over who can bypass (apps, teams, roles).
- **Tag protection**: rulesets can also protect tags.

Rulesets require **GitHub Pro** on personal repos or **Team** on org repos for private repositories.

## Migration path

If renaming `ForgenLegal` to `staging`, create a ruleset matching both names during the transition:

```
refs/heads/ForgenLegal
refs/heads/staging
```

Once the rename is complete and all references are updated, remove the `ForgenLegal` pattern.
