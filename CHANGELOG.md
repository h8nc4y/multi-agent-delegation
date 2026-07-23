# Changelog

All notable changes to this project are documented in this file.

The format loosely follows Keep a Changelog conventions.

## Unreleased

### Changed

- Hardened git-tracked private-marker enumeration against ambient `GIT_*`
  repository, worktree, index, object, config, execution, prompt, and trace
  overrides by running each Git command in a sanitized child environment.
- Changed repository scans to bounded regular stage-0 index blobs, with
  fail-closed root/probe, malformed/unmerged entry, symlink/gitlink, missing
  object, replacement-ref, lazy-fetch, metadata/entry, and size-limit handling.
  Non-Git scans now reject links and reparse points before traversal and use a
  bounded child for every content read.
- Added incremental NUL and line parsing plus explicit local-marker, line, and
  redacted-finding limits so bounded child output cannot expand into unbounded
  in-process arrays or reports.
- Made a staged `.private-markers.local` an explicit untracked-only contract
  violation instead of silently excluding it from the index scan.
- Added adversarial staged/worktree divergence, missing-file, external-link,
  dangling-control, replacement-ref, synthetic-promisor, parent-environment,
  present-empty removal/preservation, outside-artifact, descendant-pipe, and
  bounded-timeout regressions. The self-test uses the current PowerShell host
  explicitly, and CI runs it separately on PowerShell 7 and Windows PowerShell
  5.1 with structurally validated job and step ownership.
- Pinned the checkout action to the v5.0.1 commit instead of a mutable major
  tag.

## 0.1.0 - 2026-07-16

### Added

- Initial multi-agent delegation discipline skill (`SKILL.md`): mandatory
  delegation-prompt clauses, artifact verification of completion notices,
  resume-based no-op recovery, execution-environment isolation, routing by
  task profile, and ledger-as-spec parallel delegation.
- Japanese full version of the skill (`docs/SKILL.ja.md`).
- Synthetic examples: delegation prompt template (English and Japanese),
  completion verification checklist, and ledger template for parallel
  delegation.
- Private-marker scan for common secret prefixes, private-looking absolute
  paths, and non-allowlisted GitHub repository URLs, with a self-test and
  local marker support through `.private-markers.local` or the
  `MULTI_AGENT_DELEGATION_PRIVATE_MARKERS` environment variable.
- OSS readiness validation script for required public project files and
  skill frontmatter.
- GitHub Actions workflow for validation, private-marker scanning, and
  whitespace checks.
- Issue and pull request templates with sanitized-report guidance.
- Contributor, security, code of conduct, editor, and Git attribute
  documentation.
