# Changelog

All notable changes to this project are documented in this file.

The format loosely follows Keep a Changelog conventions.

## Unreleased

### Changed

- Replaced ambient child-environment cloning with an exact minimal boundary:
  OS-derived `SystemRoot` on Windows and no ambient values on POSIX. Git adds
  only fixed `GIT_*`, `GCM_INTERACTIVE=Never`, and locale `C` controls; the
  file reader adds only fixed PowerShell telemetry/update opt-outs and its
  selected input path. Runtime convenience, loader/profiler, credential/token,
  and SSH-agent variables are not inherited.
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
  and buffers instead of relying on GC; 40-run no-GC handle-count and
  file-descriptor regressions guard the boundary. Exported runner numeric
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
