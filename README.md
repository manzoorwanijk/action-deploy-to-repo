# Deploy to repo

Brief description:

> With this action, you can push files/folder (may be created by a workflow run) to another GitHub repository.

## Example usage (with access token)

```yml
name: Build and Deploy Assets
on:
  push:
    branches: [master]
jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    name: Deploy Assets
    steps:
      - name: Checkout the commit
        uses: actions/checkout@v2

      - name: Set up Node
        uses: dcodeIO/setup-node-nvm@master
        with:
          node-version: lts/*

      - name: Install deps and build
        run: npm install; npm run build

      - name: Deploy
        uses: manzoorwanijk/action-deploy-to-repo@master
        with:
          src_dir: build
          target_owner: manzoorwanijk
          target_repo: wptelegram-login
          target_dir: src/assets
          target_branch: master # default
          # Optional
          access_token: ${{ secrets.GITHUB_ACCESS_TOKEN }}
          cleanup_command: "rm -rf assets/* && rm -f assets/asset-manifest.json"
```

## Example usage (with SSH)

```yml
name: Build and Deploy Assets
on:
  push:
    branches: [master]
jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    name: Deploy Assets
    steps:
      - name: Setup SSH
        uses: MrSquaare/ssh-setup-action@v1
        with:
          host: github.com
          private-key: ${{ secrets.SSH_PRIVATE_KEY }}

      - name: Checkout the commit
        uses: actions/checkout@v2

      - name: Set up Node
        uses: dcodeIO/setup-node-nvm@master
        with:
          node-version: lts/*

      - name: Install deps and build
        run: npm install; npm run build

      - name: Deploy
        uses: manzoorwanijk/action-deploy-to-repo@master
        with:
          src_dir: build
          target_owner: manzoorwanijk
          target_repo: wptelegram-login
          target_dir: src/assets
          target_branch: master # default
          # Optional
          # access_token: ${{ secrets.GITHUB_ACCESS_TOKEN }} # Not needed when using SSH
          cleanup_command: "rm -rf assets/* && rm -f assets/asset-manifest.json"
```

## Configuration

Apart from the required arguments, you should either set up SSH as shown in the above example or pass the Access Token as shown in the first example.

## Parameters

| Name                | description                                                  | Required                   |
| ------------------- | ------------------------------------------------------------ | -------------------------- |
| `src_dir`           | Relative path of the source directory.                       | **YES**                    |
| `target_owner`      | GitHub username of the target repo owner.                    | **YES**                    |
| `target_repo`       | Name of the target repo.                                     | **YES**                    |
| `target_dir`        | Relative path of the target directory.                       | **YES**                    |
| `target_branch`     | Name of the branch on target repo. Default `master`.         |                            |
| `access_token`      | GitHub access token for the target repo.                     | **YES** (if not using SSH) |
| `git_user_email`    | Email of the git user.                                       |                            |
| `git_user_name`     | Name of the git user.                                        |                            |
| `cleanup_command`   | The command(s) to run for clean up before copying the files. |                            |
| `precommit_command` | The command(s) to run before committing the files.           |                            |
| `commit_msg`        | Deployment commit message.                                   |                            |

This action is inspired by [hpcodecraft/action-deploy-workspace-to-repo](https://github.com/hpcodecraft/action-deploy-workspace-to-repo)
