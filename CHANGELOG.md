# Changelog

All notable changes to this project are documented in this file.

The format loosely follows Keep a Changelog conventions.

## Unreleased

- Upgraded all three immutable `actions/checkout` pins from v5.0.1 to
  v7.0.1. Readiness rejects the old pinned commit, a mutable `@v7` reference,
  and stale version comments while preserving read-only permissions and
  `persist-credentials: false` on each checkout step.
- OSS readiness now requires README and CONTRIBUTING to state the same
  Windows, Ubuntu, and macOS 25-minute CI job timeout contract as the workflow.
  In-memory mutations reject a 20-minute drift, a missing macOS mention, and a
  duplicate contradictory timeout statement.

## 0.2.0 - Release candidate (unpublished)

This section describes a release candidate, not a published tag or GitHub
Release. Publication remains a separate maintainer decision covering the
version, exact target commit, timing, and final release notes.

### Highlights

- Added baseline-aware completion verification. Orchestrators now compare the
  pre-edit branch, full HEAD OID, porcelain output, and artifact state with
  independently measured final Git and content evidence.
- Added a mandatory checkout-ownership gate. Delegated writers fail closed
  when a checkout contains unassigned work, has another writer, or lacks a
  clear exclusive assignment.
- Rebuilt the private-marker scanner around a bounded index/worktree union,
  hermetic child environments, byte-exact process I/O, and fail-closed
  repository-root and file-integrity checks.
- Added bounded process-tree termination for Windows and supported Linux hosts,
  deterministic Windows handle-leak evidence, and an explicit unsupported
  macOS fail-closed contract.
- Disabled persisted GitHub credentials in every CI checkout step and fixed the
  workflow shape, permissions, timeouts, and checkout action revision through
  readiness validation.

### Platform support

- Windows runs readiness and private-marker self-tests under PowerShell 7 and
  Windows PowerShell 5.1, plus the repository scan under PowerShell 7.
- Ubuntu 24.04 runs the full PowerShell 7 suite. macOS 15 runs OSS readiness,
  whitespace checks, and the unsupported-platform fail-closed scanner
  contract; it does not run the full process-backed scanner suite.

### Detailed changes

- Disabled persisted GitHub credentials in all three immutable
  `actions/checkout` steps. OSS readiness now requires
  `with.persist-credentials: false` on the exact checkout step and rejects a
  missing, enabled, or misnested scalar through in-memory mutations.
- Made completion verification baseline-aware. Delegation prompts now record
  the pre-edit branch, full HEAD OID, full porcelain output, and required
  artifact state with read-only commands. Orchestrators independently compare
  final HEAD/diff/current porcelain/content, so unchanged pre-existing
  artifacts remain no-ops, clean commits count as completed work, assigned
  dirty resumes use initial-to-final evidence, and unassigned WIP cannot be
  absorbed. Pure decision fixtures run on every readiness host. Process-backed
  synthetic Git fixtures run only where the production runner can close the
  process tree through a Windows job object or a fixed trusted `setsid`; an
  unsupported macOS host is not reported as having executed those fixtures.
  Fixture Git uses the existing byte-bounded process-tree runner with a fixed
  minimal environment, empty config/hook/attribute inputs, and hostile
  redirect/filter sentinels. Initial porcelain, final porcelain, and
  committed-diff scope rejection are exercised in separate repositories. A
  bounded `merge-base --is-ancestor` measurement and divergent same-branch
  history fixture prevent reset/rewrite from being accepted as forward
  completion.
- Added a mandatory pre-edit checkout-ownership gate to the canonical skill,
  Japanese translation, synthetic delegation template, and completion
  checklist. A delegated writer now fails closed on unassigned existing WIP,
  another writer, or unclear ownership and continues only in an exclusive
  checkout or isolated worktree and task branch. A resumed agent can continue
  its own explicitly assigned WIP. Repository validation uses exact semantic
  blocks plus in-memory negative fixtures, reads BOM-less Markdown explicitly
  as UTF-8 on Windows PowerShell 5.1 and PowerShell 7, and runs readiness under
  both hosts in Windows CI.
- Replaced ambient child-environment cloning with an exact minimal boundary:
  OS-derived `SystemRoot` on Windows and no ambient values on POSIX. Git adds
  only fixed `GIT_*`, `GCM_INTERACTIVE=Never`, and locale `C` controls; the
  file reader adds only fixed PowerShell module-search/cache null-device
  controls, telemetry/update opt-outs, and its selected input path. The reader
  reasserts the effective module path before its first unqualified command.
  Runtime convenience, loader/profiler, credential/token, and SSH-agent
  variables are not inherited.
- Hardened git-tracked private-marker enumeration against repository, worktree,
  index, object, config, execution, prompt, and trace overrides by running each
  Git command in that hermetic child environment.
- Changed repository scans to a bounded regular stage-0 index/current-worktree
  union, including intent-to-add and unstaged content. Unique blobs use one
  strictly framed `git cat-file --batch` process, and raw index/debug snapshots
  must remain byte-identical through the scan. Valid non-reparse linked-worktree
  and submodule gitfiles are accepted after an exact bounded root probe;
  broken/dangling/reparse or mismatched `.git` entries return a fixed exit-2
  diagnostic. Nested exact-case `.git` metadata below a true non-Git root is
  excluded without being read, while POSIX `.GIT` remains ordinary content.
  Malformed/unmerged entry,
  symlink/gitlink/reparse, missing object,
  replacement-ref, lazy-fetch, metadata/entry, and size-limit failures are
  fail closed. Non-Git scans reject links and reparse points before traversal
  and use a bounded child for every content read.
- Added sensitive-name coverage for `.env*`, `.npmrc`, `*.pem`, `*.key`, and
  extensionless files.
- Added a byte-exact child-process runner. Windows uses suspended
  `CreateProcessW`, an explicit inherited-handle list, and a kill-on-close Job
  Object before resume. Launch failures check termination, re-wait, and every
  owned native handle close. Linux uses trusted `setsid` behind an owner-only
  fixed-`/tmp` release gate: it verifies the ready PID is its own process-group
  leader before permitting target `exec`, then handles direct-launcher exit,
  late-ready races, checked group termination/re-wait, and non-recursive gate
  cleanup. Child output, final UTF-8 output, and the lower-only 120-second
  scan-wide time are capped.
  Git 2.43's locale-fixed disabled-lazy-fetch warning is accepted only as an
  exact byte sequence; all other batch stderr remains fail closed.
- Fixed the raw binary fixture as the first eager production-runner call with
  an AST validator that distinguishes definitions, stored scriptblocks, and
  `ScriptBlock.Invoke*()` execution. Direct/transitive and scope-qualified
  function calls, in-source aliases, static function references, and later
  references and `Get-Variable`/`gv` recovery of direct or function-indirect
  variable-backed scriptblocks are followed through in-source aliases, early
  direct/transitive wrappers, and aliases to those wrappers. A lookup is now
  accepted only for a uniquely assigned top-level unqualified or `script:`
  variable whose literal value is exactly `{ $_ }` or `{ $PSItem }` with an
  unqualified current-item variable and whose assignment completed before the
  eager call. Lookup-name shadows remain fail closed. Target-name
  function/alias shadowing, Alias:/Function: provider
  mutation through item/content commands, dynamic bootstrap dot-sourcing,
  command-argument scriptblocks, composite receiver invocation, risky class
  invocation/casts/static initialization, runtime expressions, and unresolved
  dynamic calls/lookups fail conservatively. Unknown/unbound targets,
  runtime-created or reassigned scriptblocks, scope-mismatched assignments,
  qualified current-item variables, variable mutation, deferred
  IEX/unknown/dynamic calls, risk-sensitive command aliases, alias
  import/remove, module import/new/`using module` outside the exact
  module-qualified bootstrap, module-qualified commands impersonating an
  approved filesystem helper, Alias:/Function: provider
  copy/move/rename/remove/clear, external PowerShell script execution, unbound
  call-operator targets, and wildcard or unnamed lookups fail while the
  explicitly proven safe-scriptblock and literal application lookups remain
  accepted. Early `Remove-Item` wrappers are allowed only for a fixed `Env:`
  path or the exact SHA-256-pinned bounded fixture-cleanup function.
  Function-local call-operator targets require a unique literal-scriptblock
  binding, and the runner bootstrap requires the SHA-256-pinned source prefix
  plus module-qualified sibling import. A native
  Git batch fixture now proves BOM-less byte transport and exact caller
  input-encoding preservation on Windows PowerShell 5.1 as well as PowerShell
  7.
- Retained Windows Job handles until confirmed close, added one bounded close
  retry and direct `TerminateProcess` launch-cleanup fallback, and added a
  synthetic PID/sentinel regression for that path. Missing helpers, helper
  exceptions, and Git isolation create/remove failures now emit one fixed
  redacted stdout line with empty stderr and exit code 2.
- Explicitly dispose Windows and POSIX success-path pump Tasks, pipe streams,
  and buffers instead of relying on GC. The Windows regression now runs in a
  dedicated script in a fresh instance of the same PowerShell executable,
  after the main self-test has proved raw transport. It measures an
  80-invocation startup window, a 40-invocation runtime calibration window, and
  consecutive 40-run measured and confirmation windows. The confirmation
  window always runs once rather than acting as a conditional retry. Each
  window uses the same bounded 10-by-50 ms no-GC quiescence sample. The startup
  limit remains 16 through calibration and caps either single steady-window
  plateau. Within that absolute bound, the persistent threshold remains 4:
  growth above 4 in both consecutive windows is classified as a persistent
  leak. A one-window plateau of at most 16 and all maxima remain evidence. This
  separates
  delayed one-time Windows PowerShell runtime initialization from sustained
  growth without weakening immediate child failure or the runner's individual
  native-handle close checks. The POSIX 40-run no-GC file-descriptor regression
  remains unchanged.
- Seal the dedicated Windows handle probe's canonical UTF-8 source with
  SHA-256, while retaining a separate AST contract and parse-valid negative
  fixtures for zero-run loops, runtime limit mutation, control-flow arguments,
  provider command shadowing, and conditional loop bodies across all four
  execution windows and their quiescence windows.
  Exported runner numeric
  arguments, including fractional and overflow inputs, are body-validated into
  a fixed `process-limit-invalid` exception instead of coercion or
  parameter-binding errors. Invalid public scanner deadlines retain the
  scanner's fixed stdout/empty-stderr/exit-2 boundary.
- Start the monotonic child-operation deadline before environment preparation
  and process launch, while preserving a separate bounded cleanup allowance.
- Resolve Git only through the first native-application PATH candidate and
  require a rooted regular non-reparse file. Normal Windows hard links are
  accepted; aliases, functions, scripts, symbolic links, and reparse targets
  remain fail closed.
- Reject derived classes whose direct or transitive base constructor can run
  before the first trusted production-runner call.
- Added incremental NUL and line parsing plus explicit local-marker, line, and
  redacted-finding limits so bounded child output cannot expand into unbounded
  in-process arrays or reports.
- Made a staged `.private-markers.local` an explicit untracked-only contract
  violation instead of silently excluding it from the index scan.
- Added adversarial staged/worktree divergence, intent-to-add, sensitive-name,
  snapshot-mutation, missing-file, external-link, dangling-control,
  replacement-ref, synthetic-promisor, parent-environment, present-empty
  removal/preservation, raw-byte/partial-I/O, outside-artifact,
  descendant-pipe, final-newline-budget, and bounded-timeout regressions. The
  self-test uses the current PowerShell host explicitly. CI runs PowerShell 7
  and Windows PowerShell 5.1 on Windows plus PowerShell 7 on Ubuntu 24.04, with
  structurally validated triggers, permissions, job IDs, job/step ownership,
  immutable action pins, mutation rejection, and 25-minute job deadlines.
- Pinned the checkout action to the v5.0.1 commit instead of a mutable major
  tag.
- Added a native macOS 15 CI job for the explicitly unsupported runner path.
  It uses only synthetic input to prove that the missing trusted `setsid`
  boundary rejects the target before launch and that the public scanner emits
  fixed redacted stdout, empty stderr, and exit code 2. Windows and Ubuntu
  remain the full scanner-support jobs.

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
