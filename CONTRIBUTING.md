# Contributing

Thanks for improving this skill. This repository is intentionally small:
changes should make the delegation discipline safer, clearer, or easier to
verify.

## Before You Start

- Read [SKILL.md](SKILL.md) and the examples under [examples](examples).
- `SKILL.md` (English) is canonical. When you change it, update
  [docs/SKILL.ja.md](docs/SKILL.ja.md) in the same pull request so the two
  stay in sync.
- Do not paste tokens, credentials, private keys, OAuth codes, raw logs,
  customer data, private repository names, or internal absolute paths into
  issues, pull requests, commits, or examples. No token or secret value ever
  belongs in this repository.
- Use synthetic placeholders such as `<repo>`, `<file>:<line>`, and
  `<verify-command>` for examples.
- Put personal or organization-specific scan markers in an untracked
  `.private-markers.local` file, not in repository source.

## Development Workflow

1. Create a focused branch.
2. Make the smallest coherent change.
3. Update examples or README text when user-facing guidance changes.
4. Add or adjust validation when a safety rule should be machine-checkable.
5. Run the validation commands before opening a pull request.

## Validation

From the repository root, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
git diff --check
```

If `pwsh` is available, it is also acceptable for the PowerShell scripts:

```powershell
pwsh -NoProfile -File .\scripts\validate-oss-readiness.ps1
pwsh -NoProfile -File .\scripts\test-scan-private-markers.ps1
pwsh -NoProfile -File .\scripts\scan-private-markers.ps1
```

On macOS, Linux, or any POSIX shell with PowerShell 7 (`pwsh`) installed, use
forward slashes:

```bash
pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1
pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1
pwsh -NoProfile -File ./scripts/scan-private-markers.ps1
```

## Pull Request Expectations

- Explain the problem and the chosen fix.
- Include validation results.
- Call out any remaining unknowns.
- Claims about agent behavior should be grounded in something observable
  (a reproducible symptom, a measured session). Mark speculation as
  speculation.

## Maintainer Notes

Prefer documentation and validation that prevent future unsafe agent
behavior. Avoid adding broad dependencies or network-backed checks unless
they are clearly necessary for public safety.
