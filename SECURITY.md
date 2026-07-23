# Security Policy

This repository documents an agent-orchestration workflow. It should never
contain secrets, but its guidance shapes how agents handle repositories and
reports, so unsafe guidance is treated as a security problem too.

## Supported Versions

The `main` branch is the supported version. Tagged releases receive fixes
through new tags on `main`.

## Reporting A Vulnerability

Use GitHub private vulnerability reporting for:

- A real secret, credential, or private identifier accidentally committed to
  this repository.
- Guidance that could cause agents to leak private data, run destructive
  commands, or transmit secrets externally.
- A validation gap that allows unsafe public examples.

Do not open a public issue containing tokens, credentials, private keys,
OAuth material, customer data, raw secret-bearing logs, or private
repository names and internal paths.

## Public Issue Safety

Public issues may include:

- Symptom class, such as "no-op completion notice" or "silent environment
  failure".
- Sanitized command classes, such as `git status --porcelain` output shape
  (empty vs non-empty), without private paths.
- Placeholder repository, branch, and file names.

Public issues must not include:

- Secret values or secret-display command output.
- Private repository names, internal absolute paths, hostnames, or customer
  data.
- Raw agent transcripts that contain any of the above.

## Scanner Coverage

The private-marker scanner (`scripts/scan-private-markers.ps1`) is a
best-effort safety net, not a guarantee. It scans git-tracked text files for
a curated set of secret prefixes (GitHub, OpenAI, AWS, GCP, Slack, Stripe,
PEM key blocks, and similar), private-looking absolute Windows paths,
non-allowlisted GitHub repository URLs, and configured local markers, and it
redacts any matched value. It does not detect every possible secret format
and is no substitute for keeping real credentials out of the repository in
the first place. Treat a passing scan as "no known marker found," not
"definitely safe."

Git-tracked scanning reads bounded regular stage-0 index blobs, not
working-tree targets. It rejects root/probe mismatches, unmerged or malformed
entries, symlink/gitlink modes, missing objects, replacement refs, lazy
promisor fetches, and metadata/content size-limit violations. NUL-delimited
metadata, text lines, configured local markers, and redacted finding output are
processed incrementally with explicit count limits to prevent secondary memory
amplification after the child-process byte caps. The local marker file is
untracked-only; a staged copy is rejected rather than silently excluded.
Explicit non-Git scans enumerate one directory level at a time and reject
links or reparse points before traversal. Content reads use a bounded child so
special files and replacement races fail without blocking the parent scanner.

Git runs in a bounded child process with ambient `GIT_*` values removed and
machine/global/system config, hooks, attributes, excludes, templates, prompts,
and trace output isolated. The adversarial self-test checks staged/worktree
divergence, missing files, external-link rejection, repository/index/object
redirection, replacement-ref bypass, synthetic promisor/no-remote-helper
behavior, config injection, present-empty removal and preservation, redaction,
descendant pipe termination, and outside-artifact prevention on both
PowerShell 7 and Windows PowerShell 5.1.

## Response Expectations

Maintainers should acknowledge actionable security reports when available,
remove or redact unsafe public material, and prefer guidance that reduces
data-exposure risk. If real exposure is possible, rotate the affected secret
outside this public repository and document only the remediation status.
