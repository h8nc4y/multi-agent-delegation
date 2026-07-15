# Changelog

All notable changes to this project are documented in this file.

The format loosely follows Keep a Changelog conventions.

## Unreleased

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
