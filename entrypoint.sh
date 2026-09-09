#!/bin/sh

set -eu

die() {
	printf '❌ %s\n' "$*" >&2
	exit 1
}

# Runs a user supplied command in its own shell so that a failure in it fails
# the action. A `( ... ) || die` subshell would have its `set -e` ignored.
run_user_command() {
	sh -ec "$1"
}

# Refuses a src_dir that resolves outside the workspace, where a symlink would
# otherwise deploy anything the runner can read. Checked again after the user
# commands have run, since one of them can replace the source with a symlink.
# The workspace itself is resolved once, before any of them runs, so replacing
# the workspace too cannot move both sides of the comparison together.
assert_src_inside_workspace() {
	if [ -d "$SRC_PATH" ]; then
		_src_real="$(cd "$SRC_PATH" && pwd -P)"
	else
		_src_real="$(cd "$(dirname "$SRC_PATH")" && pwd -P)/$(basename "$SRC_PATH")"
	fi
	case "$_src_real" in
		"$WORKSPACE_REAL" | "$WORKSPACE_REAL"/*) ;;
		*) die "src_dir '$SRC_DIR' resolves outside the workspace." ;;
	esac
}

# Rejects anything that is not a plain GitHub owner or repository name.
assert_github_name() {
	case "$1" in
		'' | . | ..) die "$2 '$1' is not a valid name." ;;
		*[!A-Za-z0-9._-]*) die "$2 '$1' contains a character that a GitHub name cannot." ;;
	esac
}

echo "🚀 Igniting...3 2 1"

echo "⚙️ Changing the gears"

GIT_USER_EMAIL="${INPUT_GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
GIT_USER_NAME="${INPUT_GIT_USER_NAME:-github-actions[bot]}"

ACCESS_TOKEN="${INPUT_ACCESS_TOKEN:-}"
TARGET_OWNER="${INPUT_TARGET_OWNER:-}"
TARGET_REPO="${INPUT_TARGET_REPO:-}"
TARGET_BRANCH="${INPUT_TARGET_BRANCH:-main}"
CLEANUP_COMMAND="${INPUT_CLEANUP_COMMAND:-}"
SRC_DIR="${INPUT_SRC_DIR:-}"
TARGET_DIR="${INPUT_TARGET_DIR:-.}"
PRECOMMIT_COMMAND="${INPUT_PRECOMMIT_COMMAND:-}"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"

[ -n "$SRC_DIR" ] || die "src_dir is required."
[ -n "$TARGET_REPO" ] || die "target_repo is required."
[ -n "$TARGET_BRANCH" ] || die "target_branch cannot be empty."

# target_repo takes the "<owner>/<repo>" form. target_owner is only read for the
# legacy split form and ignored once target_repo already names an owner.
case "$TARGET_REPO" in
	*/*/*) die "target_repo '$TARGET_REPO' is not a valid '<owner>/<repo>' pair." ;;
	*/*) ;;
	*)
		[ -n "$TARGET_OWNER" ] || die "target_repo '$TARGET_REPO' has no owner. Pass target_repo as '<owner>/<repo>'."
		assert_github_name "$TARGET_OWNER" "target_owner"
		TARGET_REPO="$TARGET_OWNER/$TARGET_REPO"
		;;
esac
assert_github_name "${TARGET_REPO%%/*}" "The owner in target_repo"
assert_github_name "${TARGET_REPO#*/}" "The repository in target_repo"

case "$SRC_DIR" in
	/*) die "src_dir must be a path relative to the workspace." ;;
	.. | ../* | */../* | */..) die "src_dir must stay inside the workspace." ;;
esac
WORKSPACE_REAL="$(cd "$WORKSPACE" && pwd -P)" || die "The workspace '$WORKSPACE' is not a directory."
SRC_PATH="$WORKSPACE/$SRC_DIR"
# A trailing slash would later defeat the prefix stripping that maps a source
# path to its destination.
while [ "${SRC_PATH%/}" != "$SRC_PATH" ]; do
	SRC_PATH="${SRC_PATH%/}"
done
[ -e "$SRC_PATH" ] || die "src_dir '$SRC_DIR' does not exist."
assert_src_inside_workspace

if [ -n "$ACCESS_TOKEN" ]; then
	REPO_PATH="https://$ACCESS_TOKEN@github.com/$TARGET_REPO.git"
else
	# Otherwise it is assumed that SSH is already set up.
	REPO_PATH="git@github.com:$TARGET_REPO.git"
fi

echo "⬇️ Cloning $TARGET_REPO"
CLONE_DIR="$WORKSPACE/__deploy_to_repo_clone__"
[ ! -e "$CLONE_DIR" ] || die "$CLONE_DIR already exists in the workspace."
git clone --quiet -b "$TARGET_BRANCH" "$REPO_PATH" "$CLONE_DIR" || die "Failed to clone $TARGET_REPO ($TARGET_BRANCH)."

cd "$CLONE_DIR"
# Resolved before any user command runs, so one that replaces the clone with a
# symlink cannot move what the rest of the script treats as the clone.
CLONE_REAL="$(pwd -P)"

git config user.email "$GIT_USER_EMAIL"
git config user.name "$GIT_USER_NAME"

if [ -n "$CLEANUP_COMMAND" ]; then
	echo "🧹 Housekeeping"
	run_user_command "$CLEANUP_COMMAND" || die "cleanup_command failed."
	[ -d "$CLONE_REAL/.git" ] || die "cleanup_command removed the git metadata of the clone."
fi

echo "⏳ Copying files from $SRC_DIR"
# cleanup_command may have replaced the source with a link out of the workspace.
assert_src_inside_workspace
# Make sure the directory exists after clean up.
DEST_PATH="$CLONE_REAL/$TARGET_DIR"
mkdir -p "$DEST_PATH"

if [ -d "$SRC_PATH" ]; then
	cp -r "$SRC_PATH"/* "$DEST_PATH/" || die "Failed to copy $SRC_DIR."
else
	cp -r "$SRC_PATH" "$DEST_PATH/" || die "Failed to copy $SRC_DIR."
fi

if [ -n "$PRECOMMIT_COMMAND" ]; then
	echo "🟡 Running pre-commit command"
	run_user_command "$PRECOMMIT_COMMAND" || die "precommit_command failed."
fi

SOURCE_COMMIT="${GITHUB_REPOSITORY:-}@${GITHUB_SHA:-}"
COMMIT_MSG="${INPUT_COMMIT_MSG:-Deployed from $SOURCE_COMMIT}"

git add -A
STATUS="$(git status --porcelain)"

if [ -n "$STATUS" ]; then
	echo "☑️ Committing changes"
	git commit --quiet -m "$COMMIT_MSG"
	echo "🚀 Pushing the changes"
	git push -f origin "HEAD:refs/heads/$TARGET_BRANCH"
else
	echo "🤷🏻‍♂️ No changes to push"
fi

echo "✅ All done"
