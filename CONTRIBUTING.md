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

On Linux with PowerShell 7 (`pwsh`) and trusted `setsid` at
`/usr/bin/setsid` or `/bin/setsid`, use forward slashes:

```bash
pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1
pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1
pwsh -NoProfile -File ./scripts/scan-private-markers.ps1
```

The self-test deliberately reuses the host that launched it: a
`powershell.exe` run validates Windows PowerShell 5.1, while a `pwsh` run
validates PowerShell 7. Every scanner and Git child process has a finite
timeout and bounded termination path, and each scan has a lower-only 120-second
monotonic deadline whose invalid values are checked inside the fixed-diagnostic
entrypoint boundary. Git fixture commands use a sanitized child environment; do not
replace that boundary with parent-process environment mutation. Repository
scans are defined by a byte-stable union of regular stage-0 index blobs and
safe current-worktree content, including intent-to-add files. Preserve the
single strictly framed `git cat-file --batch` read, before/after raw snapshot
equality, lazy-fetch/replacement-ref denial, and reparse checks. Non-Git fixture
scans must reject links/reparse points before traversal and keep content reads
in a bounded child. Preserve exact-case `.git` exclusion on POSIX and bounded
exact-root support for regular linked-worktree/submodule gitfiles. Keep the AST-validated first runner call as the binary
transport fixture and keep its native Git batch/BOM/input-encoding regression;
the Windows runner intentionally uses direct C# pipe handles instead of
PowerShell text stdin and explicitly disposes completed pump/stream resources.
Do not expand workflow triggers or permissions, add
jobs/steps, or replace full commit SHA action pins without updating the exact
workflow contract and its mutation tests. Keep
`with.persist-credentials: false` directly under every checkout step. Windows
and Ubuntu CI jobs are both limited to 25 minutes.

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
