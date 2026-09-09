# Changelog

All notable changes to this action are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Major tags (`v1`, `v2`, `v3`, ...) move to the newest release of that major version; `vX.Y.Z` tags are immutable.

## [v4.0.0] - 2026-09-09

This release changes several defaults, so read the breaking changes before upgrading.

### Breaking

- The action runs as a composite action instead of a Docker action. `cleanup_command` and `precommit_command` now run on the runner rather than inside an `alpine/git` container, so they see the runner's tools and the workflow's `PATH`. They still run in `sh`. The action no longer requires a Docker capable runner.
- The target branch is no longer force pushed. Set `force: true` to keep the old behaviour; it pushes with `--force-with-lease`, so a commit made on the target branch since the clone still aborts the push.
- `target_branch` defaults to `main` in `action.yml`. It was documented as `main` since v3 but the input still defaulted to `master`.
- The clone lives in a temporary directory under `$RUNNER_TEMP`, is deleted when the action finishes and is no longer visible in `$GITHUB_WORKSPACE`, so a `precommit_command` can no longer leave anything behind for a later step to pick up.
- Dotfiles and dot-directories in `src_dir` are now copied. A `.git` at the top level of `src_dir` is skipped.
- `cleanup_command` and `precommit_command` run in their own `sh -e`, so an intermediate failing command fails the action rather than only a failing last command. Add `|| true` where a command is allowed to fail.
- `target_dir` must be relative, must stay inside the target repository (including through a symlink it committed at or below `target_dir`) and cannot be `.git`.
- A deploy that the target repository would silently swallow now fails: `target_dir` ignored by its `.gitignore`, or inside a submodule. Both used to report success having deployed nothing.
- `src_dir` must resolve inside the workspace. An absolute path never worked, but a `../` one did, and so did a symlink pointing anywhere the runner could read.
- `target_repo` and `target_owner` must be plain GitHub names.

### Fixed

- `target_owner` was declared as a required input but never read, so following `action.yml` produced a clone of `github.com/<repo>.git`. Both `<owner>/<repo>` and the legacy `target_owner` plus `target_repo` pair now work.
- The script had no `set -e` and checked nothing, so a failed clone left the action running: `cleanup_command` ran in `$GITHUB_WORKSPACE` and deleted the caller's checkout, and the step still exited 0. Every step that can fail now fails the action.
- The access token was embedded in the clone URL and stayed in the `.git/config` of a clone inside `$GITHUB_WORKSPACE`, where later steps, `upload-artifact` or `git remote -v` could expose it. It is now exported as an `http.extraheader` only into the git processes that talk to the remote, so it is in no process argv either. The header is scoped to `$GITHUB_SERVER_URL` so a `url.<other>.insteadOf` rewrite cannot capture it, the git trace variables that would print it are closed, git hooks, `ext::` remote helpers, credential helpers, askpass programs, an ssh wrapper and the filesystem monitor are refused, and the clone checks nothing out, so nothing the runner's git configuration names runs as a child of the process holding it, the push goes to the remote URL rather than to a `origin` a user command could repoint, and no environment variable carries it into `cleanup_command` or `precommit_command`.
- A `target_branch` that did not exist on the target repository failed the clone. It is now created off the default branch, or as the first branch of an empty repository.
- The git identity defaults contained literal single quotes, so the committer email was `'github-action@users.noreply.github.com'`.
- The clone directory was named after `target_repo`, so an `<owner>/<repo>` value nested it and the following `rm -rf` targeted an unexpected path.
- Unquoted expansions broke on paths containing spaces or glob characters.
- An empty `src_dir` failed the copy.

### Added

- `force` input.
- `pushed` and `commit_sha` outputs.
- Support for GitHub Enterprise Server through `$GITHUB_SERVER_URL`.
- An end to end test suite (`tests/run.sh`) and CI running shellcheck, the suite on Linux and macOS, and the action itself.

## [v3] - 2024-01-17

The `action.yml` metadata was not updated to match, so until v4 the action still
declared `target_owner` as required and still defaulted `target_branch` to
`master`. The entries below describe the intended behaviour.

### Breaking

- `target_branch` defaults to `main` instead of `master`.
- `target_owner` and `target_repo` are combined into a single `target_repo` input of the form `<owner>/<repo>`.

  ```yml
  # Before
  target_owner: <org>
  target_repo: <repo>

  # After
  target_repo: <org>/<repo>
  ```

### Changed

- Simplified the action inputs. ([#7](https://github.com/manzoorwanijk/action-deploy-to-repo/pull/7))

## [v2] - 2024-01-17

### Added

- `src_dir` accepts a single file as well as a directory. ([#4](https://github.com/manzoorwanijk/action-deploy-to-repo/pull/4))

### Changed

- Updated the README. ([#5](https://github.com/manzoorwanijk/action-deploy-to-repo/pull/5))

## [v1] - 2021-02-28

- Initial release. ([#1](https://github.com/manzoorwanijk/action-deploy-to-repo/pull/1))

[v4.0.0]: https://github.com/manzoorwanijk/action-deploy-to-repo/compare/v3...v4.0.0
[v3]: https://github.com/manzoorwanijk/action-deploy-to-repo/compare/v2...v3
[v2]: https://github.com/manzoorwanijk/action-deploy-to-repo/compare/v1...v2
[v1]: https://github.com/manzoorwanijk/action-deploy-to-repo/releases/tag/v1
