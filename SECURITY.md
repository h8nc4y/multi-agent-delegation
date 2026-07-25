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

Git-tracked scanning uses the union of bounded regular stage-0 index blobs and
safe current-worktree content, including intent-to-add files. Unique blobs are
read through one strictly framed `git cat-file --batch` process. Byte-exact
stage and debug snapshots must remain unchanged from scan start to finish. The
scanner rejects root/probe mismatches, broken/dangling/reparse or mismatched
root/ancestor `.git` entries, unmerged or malformed entries,
symlink/gitlink/reparse paths,
missing objects, replacement refs, lazy promisor fetches, and metadata/content
size-limit violations. Root/ancestor Git-control failures return exit code 2
with the fixed diagnostic `Private marker scan failed closed (integrity:
git-probe).` A regular non-reparse linked-worktree/submodule gitfile is accepted
only when the bounded Git probe establishes the exact requested root. Nested
exact-case `.git` directories and leaf files below a true non-Git root are
excluded without being read; `.GIT` remains ordinary content on POSIX.
Sensitive names such as `.env*`, `.npmrc`, `*.pem`, `*.key`, and extensionless
files are treated as text candidates. NUL-delimited metadata, text lines,
configured local markers, and redacted finding output are processed
incrementally with explicit count limits to prevent secondary memory
amplification after the child-process byte caps. The local marker file is
untracked-only; a staged copy is rejected rather than silently excluded.
Explicit non-Git scans enumerate one directory level at a time and reject
links or reparse points before traversal. Content reads use a bounded child so
special files and replacement races fail without blocking the parent scanner.

Git and file-reader children start from a fixed minimal environment rather than
inheriting the scanner process. Windows receives only an OS-derived
`SystemRoot`; POSIX receives no ambient values. Git adds explicit `GIT_*`,
`GCM_INTERACTIVE=Never`, and locale controls, while the reader adds fixed
PowerShell module-search/cache null-device controls, telemetry/update opt-outs,
and one input path. `PATH`, temp, home/profile, loader/profiler,
credential/token, and SSH-agent variables are not inherited. PowerShell 7
prepends default module paths during startup, so the reader reasserts the
null-device module path before its first unqualified command. Git machine,
global, and system config, hooks, attributes, excludes, templates, prompts, and
trace output remain isolated. Git resolution fixes the first native-application
PATH candidate and requires a rooted regular non-reparse file; ordinary Windows
hard links are allowed, while aliases,
functions, scripts, symbolic links, and reparse targets fail closed. Windows
assigns a suspended process to a kill-on-close Job Object before resuming it;
Linux uses
trusted `setsid` behind an owner-only fixed-`/tmp` release gate. The parent
reads the gate shell PID, verifies `getpgid(pid) == pid`, and only then creates
the release file that permits target `exec`. An unreleased timeout kills the
direct launcher, boundedly probes a late ready file, terminates any verified
group, and removes only the private known gate entries. Final cleanup probes
the verified group even after launcher exit. Windows
launch cleanup also checks termination, wait, and every owned
pipe/thread/process/Job handle-close
result. Raw stdin/stdout/stderr, child-output caps, the final 64 KiB UTF-8
report, and the lower-only two-minute scan deadline are enforced without
line-ending assumptions. The child-operation budget begins before environment
preparation and process launch, while termination and cleanup retain a separate
bounded kill-wait allowance. The exported process runner accepts only
canonical integers for numeric arguments and rejects fractional, exponential,
aggregate, overflow, and out-of-range values with `process-limit-invalid`.
Invalid public scan-deadline values are normalized inside the scanner
entrypoint to fixed stdout, empty stderr, and exit 2. The only accepted
non-empty Git batch stderr is the
exact locale-fixed Git 2.43 warning produced when disabled lazy fetching
returns a missing promisor object; extra bytes fail closed. The adversarial
self-test covers these boundaries on PowerShell 7 and Windows PowerShell 5.1
on Windows, and PowerShell 7 on Ubuntu 24.04. Windows uses direct raw C# pipe
handles rather than PowerShell's text stdin writer; the first eager runner
call is AST-validated through direct/transitive and scope-qualified function
calls, in-source aliases, static function references, and later direct or
function-indirect stored-scriptblock references. `Get-Variable`/`gv` recovery
is accepted only for a uniquely assigned top-level unqualified or `script:`
variable whose literal value is exactly `{ $_ }` or `{ $PSItem }` with an
unqualified current-item variable, and whose assignment completes before the
eager call; that positive proof propagates through in-source aliases, early
direct/transitive wrappers, and aliases to those wrappers. Shadowed lookup names
remain fail closed. Target-name shadowing, risky class construction/method
calls/casts/static initialization, Alias:/Function: provider mutation through
`Set-Item`, `Set-Content`, or `New-Item`, dynamic bootstrap dot-sourcing,
command-argument scriptblocks, composite receiver invocation, runtime
expressions, unknown or unbound variables, runtime-created or reassigned
scriptblocks, scope-mismatched assignments, qualified current-item variables,
variable mutation, deferred IEX/unknown/dynamic calls,
risk-sensitive command aliases, alias import/remove, module
import/new/`using module` outside the exact module-qualified bootstrap,
module-qualified commands impersonating an approved filesystem helper,
Alias:/Function: provider copy/move/rename/remove/clear, external PowerShell
script execution, unbound call-operator targets, and wildcard or unnamed
lookups fail closed. Function-local call-operator targets are accepted only
when uniquely bound to a literal scriptblock whose body passes the same
identity checks. The explicitly proven
safe-scriptblock lookup and literal application lookups remain accepted. The
only early `Remove-Item` wrapper exceptions are a fixed `Env:` path and the
exact SHA-256-pinned bounded fixture-cleanup function. The runner bootstrap is
also fixed to a SHA-256-pinned source prefix and the module-qualified import of
the sibling runner module. Job cleanup
retains a handle until close succeeds, retries once, and keeps a direct-process
fallback when Job termination fails. Entry/helper/isolation exceptions are
reduced to fixed redacted exit-2 diagnostics. A native Git batch response proves
BOM-less byte transport, and the caller's console input encoding must remain
unchanged. Completed stream-pump tasks, streams, and buffers are explicitly
disposed on Windows and POSIX; 40-run no-GC handle and file-descriptor
regressions prevent deferred resource collection from masking leaks. CI
workflow validation also rejects expanded triggers, writable or
job-local permission overrides, duplicate/extra jobs, extra step keys, and
mutable third-party action references.

## Response Expectations

Maintainers should acknowledge actionable security reports when available,
remove or redact unsafe public material, and prefer guidance that reduces
data-exposure risk. If real exposure is possible, rotate the affected secret
outside this public repository and document only the remediation status.
