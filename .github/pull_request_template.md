<!--
Thanks for opening a PR. Fill in the sections below — reviewers rely on them
to understand scope, risk, and how to verify. Delete sections that don't apply.
Keep the title short (under 70 chars) and imperative, e.g. "Add feature-env
teardown on PR close", not "Added some cleanup stuff".
-->

## Summary

<!-- One or two sentences: what this PR does, at a glance. -->

## Context

<!-- Why this change? Link the issue, audit finding, incident, or decision doc. -->

Closes #

## Type of change

<!-- Check all that apply. -->

- [ ] Feature (user-visible behavior added)
- [ ] Fix (user-visible bug corrected)
- [ ] Chore / refactor (no behavior change)
- [ ] Infra / CI / deploy (workflows, Dockerfile, render.yaml, scripts)
- [ ] Dependency update
- [ ] Docs only
- [ ] Breaking change <!-- if checked, explain the migration path under Risk -->

## Target environment

<!--
Base branch → environment mapping. Check the branch this PR targets.
-->

- [ ] `develop` → development
- [ ] `staging` → staging
- [ ] `master` → production

## How to verify

<!--
What should a reviewer run or click to confirm this works? Be concrete:
commands, URLs, pages, API calls. If a feature env was deployed for this
PR, the bot will post its URL below — include any steps specific to it.
-->

## Risk & rollback

<!-- Delete this section for pure docs/chore PRs. -->

**Impact level:** <!-- low / medium / high — your judgement -->

**What breaks if this is wrong:**

**Rollback plan:**
<!--
Concrete steps, not "revert the PR". Examples:
- Re-run the Deploy workflow with the previous commit SHA via workflow_dispatch.
- Toggle feature flag X off in Render dashboard.
- Roll the DB migration back with `python manage.py migrate taskapp 0042`.
-->

## Security & data

<!-- Delete this section only if clearly inapplicable. -->

- [ ] No secrets, credentials, or PII in the diff
- [ ] No new external network calls, or they're documented above
- [ ] Authentication / authorization checked if this touches user data
- [ ] CODEOWNERS review path covers anything security-sensitive in this diff

## Pre-merge checklist

- [ ] CI is green (tests, lint, CodeQL)
- [ ] Migrations run cleanly and are reversible, or explained under Risk
- [ ] Docs updated if behavior or setup changed (README, `docs/`, SECURITY.md)
- [ ] PR title is short and imperative
- [ ] I've self-reviewed the diff
