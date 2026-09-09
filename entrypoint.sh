#!/bin/sh

set -eu

die() {
	printf '❌ %s\n' "$*" >&2
	exit 1
}

set_outputs() {
	[ -n "${GITHUB_OUTPUT:-}" ] || return 0
	printf 'pushed=%s\ncommit_sha=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
}

# Creates $2 under $1 one component at a time, refusing to descend into a
# symlink, so a link the target repository committed cannot redirect the copy
# out of the clone. Sets DEST_PATH to the directory it created.
make_target_dir() {
	_probe="$1"
	_old_ifs="$IFS"
	IFS='/'
	# Splitting the path must not also glob it against the clone.
	set -f
	# shellcheck disable=SC2086 # Deliberate split of the path into components.
	set -- $2
	set +f
	IFS="$_old_ifs"
	for _component in "$@"; do
		case "$_component" in '' | .) continue ;; esac
		_probe="$_probe/$_component"
		[ ! -L "$_probe" ] || die "target_dir component '$_component' is a symlink in the target repository."
		[ -d "$_probe" ] || mkdir "$_probe" || die "Failed to create '$TARGET_DIR' in the target repository."
	done
	DEST_PATH="$_probe"
}

# Fails when any component of $1 is a submodule. A non-recursive clone leaves an
# empty directory there, so the copy would land in it and `git add` would ignore
# every file, reporting a deploy that deployed nothing.
assert_no_gitlink() {
	_probe=""
	_old_ifs="$IFS"
	IFS='/'
	set -f
	# shellcheck disable=SC2086 # Deliberate split of the path into components.
	set -- $1
	set +f
	IFS="$_old_ifs"
	for _component in "$@"; do
		case "$_component" in '' | .) continue ;; esac
		_probe="${_probe:+$_probe/}$_component"
		# ls-tree reports the entry type, so only that field is read and git's
		# quoting of an odd path name cannot hide the entry.
		if [ "$(git ls-tree HEAD -- ":(literal)$_probe" 2>/dev/null | awk 'NR == 1 { print $2 }')" = "commit" ]; then
			die "target_dir '$TARGET_DIR' is inside '$_probe', which is a submodule of $TARGET_REPO."
		fi
	done
}

# Removes a symlink sitting at any path the copy is about to write. `cp` follows
# a destination symlink, so one committed anywhere under target_dir would send
# the write to wherever it points. Paths are passed as arguments rather than
# read as lines, so a newline in a name cannot forge one.
clear_colliding_symlinks() {
	if [ ! -d "$1" ]; then
		[ ! -L "$2/${1##*/}" ] || rm -f "$2/${1##*/}"
		return 0
	fi
	find "$1" -mindepth 1 -path "$1/.git" -prune -o -exec sh -c '
		set -e
		_dest="$1"
		_src="$2"
		shift 2
		for _path in "$@"; do
			_collision="$_dest/${_path#"$_src"/}"
			[ ! -L "$_collision" ] || rm -f "$_collision"
		done
	' _ "$2" "$1" {} + || die "Failed to inspect the contents of $SRC_DIR."
}

# Runs git with the credentials in the environment of that one process. The
# header is scoped to the server so that a `url.<other>.insteadOf` rewrite
# cannot capture it, it reaches no process argv, every trace sink that would
# print it is closed, and every kind of child the runner's git configuration can
# name is refused: hooks, `ext::` remote helpers, credential helpers, askpass
# programs, an ssh wrapper and the filesystem monitor.
run_git() {
	set -- -c core.hooksPath=/dev/null -c protocol.ext.allow=never \
		-c credential.helper= -c core.askpass= -c core.sshCommand=ssh \
		-c core.fsmonitor=false "$@"
	if [ -n "$ACCESS_TOKEN" ]; then
		(
			GIT_CONFIG_COUNT=1
			GIT_CONFIG_KEY_0="http.$SERVER_URL/.extraheader"
			GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $AUTH_HEADER"
			export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
			unset GIT_TRACE2_ENV_VARS GIT_TRACE2_CONFIG_PARAMS
			# git reads these for presence, so assigning 0 switches them on.
			unset GIT_CURL_VERBOSE GIT_TRACE_CURL GIT_TRACE_CURL_NO_DATA
			# These read the value, and are assigned rather than unset so that a
			# trace2 target in the runner's config cannot switch them on.
			GIT_TRACE=0 GIT_TRACE_PACKET=0 GIT_TRACE_REDACT=1
			GIT_TRACE2=0 GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0
			export GIT_TRACE GIT_TRACE_PACKET GIT_TRACE_REDACT
			export GIT_TRACE2 GIT_TRACE2_EVENT GIT_TRACE2_PERF
			# An askpass or ssh helper named by the runner's config would
			# otherwise be a child of this process and see the credential.
			unset GIT_ASKPASS SSH_ASKPASS
			exec git "$@"
		)
	else
		git "$@"
	fi
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

# Assigning to a name the caller exported keeps it exported, which would hand
# the token to every command this script runs.
unset ACCESS_TOKEN AUTH_HEADER
ACCESS_TOKEN="${INPUT_ACCESS_TOKEN:-}"
# Keep the token out of the environment that the user supplied commands inherit.
unset INPUT_ACCESS_TOKEN
TARGET_OWNER="${INPUT_TARGET_OWNER:-}"
TARGET_REPO="${INPUT_TARGET_REPO:-}"
TARGET_BRANCH="${INPUT_TARGET_BRANCH:-main}"
CLEANUP_COMMAND="${INPUT_CLEANUP_COMMAND:-}"
SRC_DIR="${INPUT_SRC_DIR:-}"
TARGET_DIR="${INPUT_TARGET_DIR:-.}"
PRECOMMIT_COMMAND="${INPUT_PRECOMMIT_COMMAND:-}"
FORCE="${INPUT_FORCE:-false}"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
SERVER_URL="${SERVER_URL%/}"

[ -n "$SRC_DIR" ] || die "src_dir is required."
[ -n "$TARGET_REPO" ] || die "target_repo is required."
[ -n "$TARGET_BRANCH" ] || die "target_branch cannot be empty."
case "$FORCE" in
	true | false) ;;
	*) die "force must be 'true' or 'false', got '$FORCE'." ;;
esac

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

case "$TARGET_DIR" in
	/*) die "target_dir must be relative to the root of the target repository." ;;
	.. | ../* | */../* | */..) die "target_dir must stay inside the target repository." ;;
esac
# Writing into .git would let the copy rewrite the clone's own config, and a case
# insensitive filesystem resolves .GIT to it just the same.
case "$(printf '%s' "$TARGET_DIR" | tr '[:upper:]' '[:lower:]')" in
	.git | .git/* | */.git/* | */.git) die "target_dir must not write into the git metadata of the target repository." ;;
esac

if [ -n "$ACCESS_TOKEN" ]; then
	# GIT_CONFIG_COUNT, which carries the token, is only read from git 2.31 on.
	GIT_VERSION="$(git --version | awk '{ print $3 }')"
	GIT_MAJOR="${GIT_VERSION%%.*}"
	GIT_MINOR="${GIT_VERSION#*.}"
	GIT_MINOR="${GIT_MINOR%%.*}"
	case "$GIT_MAJOR.$GIT_MINOR" in
		[0-9]*.[0-9]*)
			if [ "$GIT_MAJOR" -lt 2 ] || { [ "$GIT_MAJOR" -eq 2 ] && [ "$GIT_MINOR" -lt 31 ]; }; then
				die "access_token needs git 2.31 or newer, found $GIT_VERSION."
			fi
			;;
	esac

	REMOTE_URL="$SERVER_URL/$TARGET_REPO.git"
	AUTH_HEADER="$(printf 'x-access-token:%s' "$ACCESS_TOKEN" | base64 | tr -d '\n')"
else
	# Otherwise it is assumed that SSH is already set up.
	SERVER_HOST="${SERVER_URL#*://}"
	SERVER_HOST="${SERVER_HOST%%/*}"
	case "$SERVER_HOST" in
		# The scp-like form has no way to spell a port.
		*:*) REMOTE_URL="ssh://git@$SERVER_HOST/$TARGET_REPO.git" ;;
		*) REMOTE_URL="git@$SERVER_HOST:$TARGET_REPO.git" ;;
	esac
	AUTH_HEADER=""
fi

# Clone outside the workspace so the checkout is never picked up by later steps.
TEMP_ROOT="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/deploy-to-repo.XXXXXX")" ||
	die "Failed to create a temporary directory for the clone."
# `|| true` because a failing clean up must not turn a successful deploy into a
# failed step.
trap 'rm -rf "$TEMP_ROOT" || true' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
CLONE_DIR="$TEMP_ROOT/clone"

echo "⬇️ Cloning $TARGET_REPO"
# The remote name is pinned because `clone.defaultRemoteName` would otherwise
# rename it. Nothing is checked out here, so a `.gitattributes` filter cannot run
# as a child of the process holding the credential; the checkout below has none.
run_git clone --quiet --no-tags --no-checkout --origin origin \
	--config core.hooksPath=/dev/null "$REMOTE_URL" "$CLONE_DIR" || die "Failed to clone $TARGET_REPO."

cd "$CLONE_DIR"
# Resolved before any user command runs, so one that replaces the clone with a
# symlink cannot move what the rest of the script treats as the clone.
CLONE_REAL="$(pwd -P)"

git config user.email "$GIT_USER_EMAIL"
git config user.name "$GIT_USER_NAME"

if git rev-parse --verify --quiet "refs/remotes/origin/$TARGET_BRANCH" >/dev/null; then
	git checkout --quiet -B "$TARGET_BRANCH" "refs/remotes/origin/$TARGET_BRANCH"
	BASE_SHA="$(git rev-parse HEAD)"
else
	echo "🌱 $TARGET_BRANCH does not exist on $TARGET_REPO, branching it off the default branch"
	if git rev-parse --verify --quiet HEAD >/dev/null; then
		git checkout --quiet -B "$TARGET_BRANCH"
	else
		# An empty repository has no commit to branch off.
		git symbolic-ref HEAD "refs/heads/$TARGET_BRANCH"
	fi
	BASE_SHA=""
fi

if [ -n "$CLEANUP_COMMAND" ]; then
	echo "🧹 Housekeeping"
	run_user_command "$CLEANUP_COMMAND" || die "cleanup_command failed."
	[ -d "$CLONE_REAL/.git" ] || die "cleanup_command removed the git metadata of the clone."
fi

echo "⏳ Copying files from $SRC_DIR"
# cleanup_command may have replaced the source with a link out of the workspace.
assert_src_inside_workspace
# Make sure the directory exists after clean up.
make_target_dir "$CLONE_REAL" "$TARGET_DIR"
DEST_REAL="$(cd "$DEST_PATH" && pwd -P)"
case "$DEST_REAL" in
	"$CLONE_REAL" | "$CLONE_REAL"/*) ;;
	*) die "target_dir resolves outside the target repository." ;;
esac

assert_no_gitlink "$TARGET_DIR"

# A nested repository at target_dir would swallow the whole copy too.
DEST_TOPLEVEL="$(git -C "$DEST_PATH" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$DEST_TOPLEVEL" ] || [ "$(cd "$DEST_TOPLEVEL" && pwd -P)" != "$CLONE_REAL" ]; then
	die "target_dir '$TARGET_DIR' belongs to a nested repository, not to $TARGET_REPO."
fi

clear_colliding_symlinks "$SRC_PATH" "$DEST_PATH"

if [ -d "$SRC_PATH" ]; then
	find "$SRC_PATH" -mindepth 1 -path "$SRC_PATH/.git" -prune -o -exec sh -c '
		set -e
		_target_dir="$1"
		_src="$2"
		shift 2
		for _path in "$@"; do
			printf "%s\n" "$_target_dir/${_path#"$_src"/}"
		done
	' _ "$TARGET_DIR" "$SRC_PATH" {} + >"$TEMP_ROOT/deployed-paths" ||
		die "Failed to list the contents of $SRC_DIR."
else
	printf '%s\n' "$TARGET_DIR/${SRC_PATH##*/}" >"$TEMP_ROOT/deployed-paths"
fi

if [ -d "$SRC_PATH" ]; then
	# Copy entry by entry so dotfiles come along and the source `.git`, which
	# would clobber the clone or become a gitlink, does not.
	for entry in "$SRC_PATH"/* "$SRC_PATH"/.[!.]* "$SRC_PATH"/..?*; do
		[ -e "$entry" ] || [ -L "$entry" ] || continue
		[ "${entry##*/}" != ".git" ] || continue
		cp -a "$entry" "$DEST_PATH/" || die "Failed to copy $entry."
	done
else
	cp -a "$SRC_PATH" "$DEST_PATH/" || die "Failed to copy $SRC_DIR."
fi

if [ -n "$PRECOMMIT_COMMAND" ]; then
	echo "🟡 Running pre-commit command"
	run_user_command "$PRECOMMIT_COMMAND" || die "precommit_command failed."
fi

SOURCE_COMMIT="${GITHUB_REPOSITORY:-}@${GITHUB_SHA:-}"
COMMIT_MSG="${INPUT_COMMIT_MSG:-Deployed from $SOURCE_COMMIT}"

git add -A
STATUS="$(git status --porcelain)"

if [ -z "$STATUS" ]; then
	# git drops ignored paths without a word, so a deploy into an ignored
	# directory would otherwise report success having deployed nothing.
	IGNORED="$(git check-ignore --stdin <"$TEMP_ROOT/deployed-paths" 2>/dev/null | head -1 || true)"
	[ -z "$IGNORED" ] ||
		die "$TARGET_REPO ignores '$IGNORED', so nothing would be committed. Change its .gitignore or target_dir."
fi

if [ -n "$STATUS" ]; then
	echo "☑️ Committing changes"
	git commit --quiet -m "$COMMIT_MSG"
elif [ -n "$BASE_SHA" ]; then
	echo "🤷🏻‍♂️ No changes to push"
	set_outputs false "$BASE_SHA"
	echo "✅ All done"
	exit 0
elif ! git rev-parse --verify --quiet HEAD >/dev/null; then
	# The branch is new and the repository is empty, so it needs a commit to be
	# created at all.
	git commit --quiet --allow-empty -m "$COMMIT_MSG"
fi

COMMIT_SHA="$(git rev-parse HEAD)"

echo "🚀 Pushing the changes"
# The URL rather than `origin`, so a user command that repointed the remote
# cannot redirect the push, and the credentials with it.
if [ "$FORCE" = "true" ] && [ -n "$BASE_SHA" ]; then
	# The lease keeps the push from discarding commits made since the clone.
	run_git push --force-with-lease="refs/heads/$TARGET_BRANCH:$BASE_SHA" "$REMOTE_URL" "HEAD:refs/heads/$TARGET_BRANCH"
else
	run_git push "$REMOTE_URL" "HEAD:refs/heads/$TARGET_BRANCH"
fi

set_outputs true "$COMMIT_SHA"

echo "✅ All done"
