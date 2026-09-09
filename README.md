# Deploy to repo

Brief description:

> With this action, you can push files/folder (may be created by a workflow run) to another GitHub repository.

See the [changelog](CHANGELOG.md) before upgrading; `v4` changes several defaults.

## Example usage (with access token)

```yml
name: Build and Deploy Assets
on:
  push:
    branches: [main]
jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    name: Deploy Assets
    steps:
      - name: Checkout the commit
        uses: actions/checkout@v4

      - name: Set up Node
        uses: actions/setup-node@v4
        with:
          node-version: lts/*

      - name: Install deps and build
        run: npm install && npm run build

      - name: Deploy
        uses: manzoorwanijk/action-deploy-to-repo@v4
        with:
          src_dir: build
          target_repo: <org>/<repo>
          target_dir: src/assets
          target_branch: main # default
          access_token: ${{ secrets.GITHUB_ACCESS_TOKEN }}
          # Optional
          cleanup_command: "rm -rf src/assets/* && rm -f src/assets/asset-manifest.json"
```

## Example usage (with SSH)

```yml
name: Build and Deploy Assets
on:
  push:
    branches: [main]
jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    name: Deploy Assets
    steps:
      - name: Setup SSH
        uses: MrSquaare/ssh-setup-action@v3
        with:
          host: github.com
          private-key: ${{ secrets.SSH_PRIVATE_KEY }}

      - name: Checkout the commit
        uses: actions/checkout@v4

      - name: Set up Node
        uses: actions/setup-node@v4
        with:
          node-version: lts/*

      - name: Install deps and build
        run: npm install && npm run build

      - name: Deploy
        uses: manzoorwanijk/action-deploy-to-repo@v4
        with:
          src_dir: build
          target_repo: <org>/<repo>
          target_dir: src/assets
          target_branch: main # default
          cleanup_command: "rm -rf src/assets/* && rm -f src/assets/asset-manifest.json"
```

## Configuration

Apart from the required arguments, you should either set up SSH as shown in the above example or pass the Access Token as shown in the first example.

## Parameters

| Name                | description                                                                                       | Required                   |
| ------------------- | ------------------------------------------------------------------------------------------------- | -------------------------- |
| `src_dir`           | Relative path of the source directory. A single file works too.                                   | **YES**                    |
| `target_repo`       | Target repository in the form of `<organization>/<repo>` e.g. `google/wireit`.                    | **YES**                    |
| `target_dir`        | Path of the target directory, relative to the root of the target repository.                      | **YES**                    |
| `target_branch`     | Name of the branch on target repo. Default `main`.                                                |                            |
| `access_token`      | GitHub access token for the target repo.                                                          | **YES** (if not using SSH) |
| `git_user_email`    | Email of the git user. Default `41898282+github-actions[bot]@users.noreply.github.com`.           |                            |
| `git_user_name`     | Name of the git user. Default `github-actions[bot]`.                                              |                            |
| `cleanup_command`   | The command(s) to run for clean up before copying the files.                                      |                            |
| `precommit_command` | The command(s) to run before committing the files.                                                |                            |
| `commit_msg`        | Deployment commit message.                                                                        |                            |
| `force`             | Force push the target branch. Default `false`.                                                    |                            |
| `target_owner`      | **Deprecated.** Owner of the target repo, only read when `target_repo` is a bare repository name. |                            |

## Outputs

| Name         | description                                                                                     |
| ------------ | ----------------------------------------------------------------------------------------------- |
| `pushed`     | `true` when a commit was pushed to the target branch, `false` when there was nothing to deploy. |
| `commit_sha` | Sha of the pushed commit, or of the target branch tip when nothing was pushed.                  |

## Behaviour

- **Target branch.** When `target_branch` does not exist on the target repository it is created off the default branch, or as the first branch of an empty repository, even when the copy produces no change.
- **Copying.** Everything in `src_dir` is copied into `target_dir`, including dotfiles and dot-directories. A `.git` at the top level of `src_dir` is skipped; a nested one is copied, and git stages it as a gitlink if it is a real checkout. Files already in `target_dir` that `src_dir` does not replace are left alone; use `cleanup_command` to remove them. A symlink the target repository committed at a path the copy writes is replaced, so the copy cannot be redirected out of the clone.
- **Pushing.** The push is a plain, fast-forward push. Set `force: true` when `precommit_command` rewrites history; it pushes with `--force-with-lease` against the sha that was cloned, so a commit pushed to the target branch in the meantime still aborts the push.
- **Committing.** Everything in the clone is staged, so a `precommit_command` that writes outside `target_dir` has its changes committed and pushed too. The action fails rather than reporting an empty success if the target repository would swallow the deploy, which happens when `target_dir` is ignored by its `.gitignore` or sits inside a submodule.
- **The clone.** The target repository is cloned into a temporary directory under `$RUNNER_TEMP`, outside `$GITHUB_WORKSPACE`, and deleted when the action finishes.
- **The token.** It is exported only into the environment of the git processes that talk to the remote, so it reaches neither the remote URL, the clone's config nor any process argv. The `AUTHORIZATION` header is scoped to `$GITHUB_SERVER_URL`, so a `url.<other>.insteadOf` rewrite cannot capture it; the git trace variables that would print it are closed, since the header is base64 and is not the string Actions masks in a log; git hooks, `ext::` remote helpers, credential helpers, askpass programs, an ssh wrapper and the filesystem monitor are all refused, and nothing is checked out by the process holding the credential, so a `.gitattributes` filter cannot run as its child either; and the push goes to the remote URL rather than to `origin`, which a `precommit_command` could have repointed. The action still trusts the runner's git installation, and a `url.<other>.insteadOf` rewrite there can still redirect where the deploy lands, though not the token.
- **GitHub Enterprise Server.** The remote is built from `$GITHUB_SERVER_URL`. With `access_token` this needs no further configuration; over SSH it uses the host and port from that URL and assumes the `<owner>/<repo>.git` layout.

## `cleanup_command` and `precommit_command`

Both run in their own `sh -e` on the runner, with the working directory set to the root of the clone, so do not rely on bash-only syntax. Because of `-e`, a failing command fails the action, except where POSIX `sh` masks it: inside a pipeline, or before a `||`. `cleanup_command` runs before the files are copied, `precommit_command` after. No environment variable carries `access_token` into them, but the rest of the job's environment, including any other secret exposed to the step, is visible. Treat them as trusted code and never interpolate untrusted input into them.

## Requirements

A runner with a POSIX shell and `git`. Using `access_token` needs `git` 2.31 or newer, which the action checks.

## Versioning

`v4` moves with the newest `v4.x.y` release. Pin an immutable `vX.Y.Z` tag or a commit sha for reproducible builds. Every release is listed in the [changelog](CHANGELOG.md).

This action is inspired by [hpcodecraft/action-deploy-workspace-to-repo](https://github.com/hpcodecraft/action-deploy-workspace-to-repo)
