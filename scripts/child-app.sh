#!/usr/bin/env bash
# Give a line of work its own child app, and tear it down when the work ends.
#
# Usage:
#   scripts/child-app.sh up <slug>
#   scripts/child-app.sh down <slug> [--skip-teardown]
#
# A child app is a copy of the selected environment's app (its settings and
# secrets), owned by you, that shares the parent's primitive/<env>/ tree. Run
# this from the app with the parent environment selected, or a sibling child
# selected (the parent is then that child's tree).
#
# `up` creates the child (or attaches/resumes one that already exists), checks
# that `--env <slug>` really is that child, runs the app's own
# scripts/child-app-init, pushes the tree into the child and selects it. Every
# step is safe to repeat, so running `up` again resumes an interrupted run.
# Rebuild afterwards so scripts/resolve-primitive-config.sh writes the child
# into primitive.json.
#
# `down` checks that `--env <localName>` is the child, runs the app's own
# scripts/child-app-teardown, then deletes the child and its local state.
# `--skip-teardown` deletes without running the hook (and without the check),
# leaving anything the child created outside the platform behind.
#
# APP-OWNED HOOKS. This template ships neither hook; an app adds them as
# executable files when it needs them:
#
#   scripts/child-app-init      run by `up` before the first push, on EVERY
#                               `up`, so it must be safe to repeat. Seed what a
#                               fresh child needs here: users, databases, the
#                               child's own config vars (`primitive config set
#                               vars KEY=value`), anything else.
#   scripts/child-app-teardown  run by `down` before the delete. Revoke or
#                               delete anything the child created outside the
#                               platform (third-party connections, buckets,
#                               webhooks). Exiting non-zero keeps the child.
#
# Each hook runs from the app root with PRIMITIVE_ENV (the child's local
# environment name), CHILD_APP_ID, CHILD_APP_SLUG and PARENT_ENV set. Address
# the child through PRIMITIVE_ENV (or `--env`), never through the selected
# environment: a hook may change the selection, and this script does not rely
# on it afterwards. Every `primitive` call made after a hook names its
# environment explicitly.
#
# `primitive` is resolved from PATH; JSON is read through python3. Arguments
# are always quoted and never evaluated.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT_HOOK="scripts/child-app-init"
TEARDOWN_HOOK="scripts/child-app-teardown"

say() {
  local line
  for line in "$@"; do printf '[child-app] %s\n' "$line"; done
}

fail() {
  local line
  for line in "$@"; do printf '[child-app] %s\n' "$line" >&2; done
  exit 1
}

usage() {
  fail "$1" \
    "Usage:" \
    "  scripts/child-app.sh up <slug>                     create or resume a child app, push the tree into it, select it" \
    "  scripts/child-app.sh down <slug> [--skip-teardown] run the teardown hook, then delete the child"
}

# ---------------------------------------------------------------- arguments

VERB="${1:-}"
if [ "$#" -gt 0 ]; then shift; fi
case "$VERB" in
  up | down) ;;
  *) usage "Unknown command \"$VERB\"." ;;
esac
SLUG=""
SLUG_SET=0
SKIP_TEARDOWN=0
while [ "$#" -gt 0 ]; do
  arg="$1"
  shift
  case "$arg" in
    --) ;;
    --skip-teardown)
      [ "$VERB" = down ] || usage "Unknown option \"$arg\" for $VERB."
      SKIP_TEARDOWN=1
      ;;
    -*) usage "Unknown option \"$arg\" for $VERB." ;;
    *)
      [ "$SLUG_SET" = 0 ] || usage "Unexpected argument \"$arg\"."
      SLUG="$arg"
      SLUG_SET=1
      ;;
  esac
done
# The CLI validates the slug's characters; this only keeps a missing slug, or
# one that would read as an option, from reaching it.
[ -n "$SLUG" ] || usage "A child slug is required."
case "$SLUG" in
  *[[:space:]]*) usage "The slug \"$SLUG\" contains whitespace." ;;
esac

# ---------------------------------------------------------------- primitive

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
OUT="$TMP_DIR/stdout"
ERR="$TMP_DIR/stderr"
CODE=0

# Runs `primitive "$@"` from the app root; its exit code goes to CODE, its
# output to $OUT and $ERR, unprinted.
capture() {
  set +e
  (cd "$ROOT_DIR" && primitive "$@") >"$OUT" 2>"$ERR"
  CODE=$?
  set -e
}

# Runs `primitive "$@"` from the app root with its output passed through; its
# exit code goes to CODE.
run() {
  say "> primitive $*"
  set +e
  (cd "$ROOT_DIR" && primitive "$@")
  CODE=$?
  set -e
}

# The CLI's own words from the last capture, for a failure this script repeats.
cli_output() {
  cat "$ERR" "$OUT" | grep -v '^CLI Version:' | sed -e '/^[[:space:]]*$/d' -e 's/^/[child-app]   /' >&2 || true
}

# Exits 1 naming the command the last capture ran, and repeating its output.
fail_cli() {
  printf "[child-app] 'primitive %s' failed:\n" "$1" >&2
  cli_output
  exit 1
}

# `json_get <file> <key.path>`: the value, `true`/`false` for a boolean, empty for null or absent.
json_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    doc = doc.get(part) if isinstance(doc, dict) else None
if doc is None:
    print("")
elif isinstance(doc, bool):
    print("true" if doc else "false")
else:
    print(doc)
PY
}

# `json_lists_child <file> <slug>`: `yes` when a children listing holds the slug.
json_lists_child() {
  python3 - "$1" "$2" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
print("yes" if any(item.get("childSlug") == sys.argv[2] for item in doc.get("items") or []) else "no")
PY
}

# ---------------------------------------------------------------- steps

# PARENT: the parent the selected environment implies — a child's tree, or the
# committed environment itself.
resolve_parent() {
  capture env show --json
  [ "$CODE" = 0 ] || fail_cli "env show --json"
  cp "$OUT" "$TMP_DIR/selected.json"
  if [ "$(json_get "$TMP_DIR/selected.json" local)" = true ]; then
    PARENT="$(json_get "$TMP_DIR/selected.json" tree)"
  else
    PARENT="$(json_get "$TMP_DIR/selected.json" name)"
  fi
}

# LISTED: `yes` when the parent lists the child SLUG, following the listing's cursor.
find_in_listing() {
  local cursor="" page="$TMP_DIR/list.json"
  LISTED=no
  while :; do
    if [ -n "$cursor" ]; then
      capture --env "$PARENT" apps children list --limit 100 --cursor "$cursor" --json
    else
      capture --env "$PARENT" apps children list --limit 100 --json
    fi
    [ "$CODE" = 0 ] || fail_cli "--env $PARENT apps children list --json"
    cp "$OUT" "$page"
    LISTED="$(json_lists_child "$page" "$SLUG")"
    [ "$LISTED" = no ] || return 0
    cursor="$(json_get "$page" nextCursor)"
    if [ "$(json_get "$page" hasMore)" != true ] || [ -z "$cursor" ]; then return 0; fi
  done
}

# Refuses a slug that names a committed environment in primitive/config.json
# before anything selects it: `env use <slug>` would select that environment
# instead of attaching the child. $1 is 1 when this run created the child.
refuse_committed_name() {
  capture env show "$SLUG" --json
  [ "$CODE" = 0 ] || return 0
  local created=()
  if [ "$1" = 1 ]; then
    created=("The child now exists on the server but is not registered here. Delete it with 'primitive --env $PARENT apps children delete $SLUG --yes'.")
  fi
  fail "\"$SLUG\" is a committed environment in primitive/config.json, so the child \"$SLUG\" cannot be attached under that name on this machine." \
    ${created[@]+"${created[@]}"} \
    "Nothing was selected, run or pushed. Choose another slug."
}

# Attaches the child SLUG of PARENT as a local environment.
attach() {
  run --env "$PARENT" env use "$SLUG"
  [ "$CODE" = 0 ] || fail "'primitive --env $PARENT env use $SLUG' failed. The child exists on the server; fix the problem above and run 'scripts/child-app.sh up $SLUG' again."
}

# CHILD_APP_ID: the child SLUG of PARENT, created, attached or resumed.
create_or_attach() {
  local got="$TMP_DIR/get.json"
  capture --env "$PARENT" apps children get "$SLUG" --json
  if [ "$CODE" = 0 ]; then
    cp "$OUT" "$got"
    CHILD_APP_ID="$(json_get "$got" appId)"
    local local_name
    local_name="$(json_get "$got" localName)"
    if [ "$(json_get "$got" local)" = true ]; then
      if [ "$local_name" != "$SLUG" ]; then
        fail "The child \"$SLUG\" ($CHILD_APP_ID) is registered on this machine as \"$local_name\"." \
          "Run 'primitive env use $local_name' to work on it; nothing was run or pushed."
      fi
      say "Resuming the child \"$SLUG\" ($CHILD_APP_ID)."
      return 0
    fi
    if [ -n "$(json_get "$got" localConflict.appId)" ]; then
      fail "The local environment \"$SLUG\" holds a different app, $(json_get "$got" localConflict.appId) (tree \"$(json_get "$got" localConflict.tree)\"), not the child \"$SLUG\" ($CHILD_APP_ID)." \
        "Nothing was selected, run or pushed. Choose another slug, or remove that entry first."
    fi
    refuse_committed_name 0
    say "Attaching the existing child \"$SLUG\" ($CHILD_APP_ID)."
    attach
    return 0
  fi

  # `get` fails for a slug the parent has no child for, but also for a stale
  # local entry, a login or a network failure: create only when the listing
  # confirms the child is absent.
  cp "$OUT" "$TMP_DIR/get.out"
  cp "$ERR" "$TMP_DIR/get.err"
  find_in_listing
  if [ "$LISTED" = yes ]; then
    cp "$TMP_DIR/get.out" "$OUT"
    cp "$TMP_DIR/get.err" "$ERR"
    fail_cli "--env $PARENT apps children get $SLUG --json"
  fi
  say "Creating the child \"$SLUG\" of \"$PARENT\"."
  capture --env "$PARENT" apps children create "$SLUG" --json
  if [ "$CODE" = 0 ]; then
    CHILD_APP_ID="$(json_get "$OUT" appId)"
    return 0
  fi
  if [ "$CODE" = 2 ]; then
    # Created on the server, not registered here.
    CHILD_APP_ID="$(json_get "$OUT" appId)"
    refuse_committed_name 1
    attach
    return 0
  fi
  fail_cli "--env $PARENT apps children create $SLUG --json"
}

# Exits unless `--env $1` resolves to the machine-local environment of the
# child CHILD_APP_ID: nothing that writes may run against anything else. $2
# says what did not happen.
verify_identity() {
  capture --env "$1" env show --json
  if [ "$CODE" = 0 ]; then
    cp "$OUT" "$TMP_DIR/identity.json"
    local is_local app_id name kind
    is_local="$(json_get "$TMP_DIR/identity.json" local)"
    app_id="$(json_get "$TMP_DIR/identity.json" appId)"
    name="$(json_get "$TMP_DIR/identity.json" name)"
    if [ "$is_local" = true ] && [ "$app_id" = "$CHILD_APP_ID" ]; then return 0; fi
    kind=committed
    if [ "$is_local" = true ]; then kind=machine-local; fi
    fail "'--env $1' does not resolve to the child \"$SLUG\" ($CHILD_APP_ID): it resolved to \"$name\" ($app_id, $kind)." "$2"
  fi
  printf "[child-app] '--env %s' does not resolve to the child \"%s\" (%s): it resolved to nothing.\n" "$1" "$SLUG" "$CHILD_APP_ID" >&2
  cli_output
  fail "$2"
}

# Runs the app-owned hook $1 when it exists, with PRIMITIVE_ENV=$2 and the
# child's variables; HOOK_RAN says whether it ran. Exits when the hook is not
# executable or fails, saying $3.
run_hook() {
  local relative="$1" path="$ROOT_DIR/$1"
  HOOK_RAN=0
  [ -e "$path" ] || return 0
  [ -x "$path" ] || fail "$relative exists but is not executable. Run 'chmod +x $relative', then run this again." "$3"
  say "Running $relative..."
  set +e
  (cd "$ROOT_DIR" && PRIMITIVE_ENV="$2" CHILD_APP_ID="$CHILD_APP_ID" CHILD_APP_SLUG="$SLUG" PARENT_ENV="$PARENT" "$path")
  local code=$?
  set -e
  [ "$code" = 0 ] || fail "$relative exited $code." "$3"
  HOOK_RAN=1
}

up() {
  resolve_parent
  create_or_attach
  verify_identity "$SLUG" "No hook ran and nothing was pushed."

  # ---- App setup: scripts/child-app-init (see the header). ----
  run_hook "$INIT_HOOK" "$SLUG" \
    "Nothing was pushed. The child \"$SLUG\" exists; run 'scripts/child-app.sh up $SLUG' again to resume."
  if [ "$HOOK_RAN" = 0 ]; then say "There is no $INIT_HOOK hook; the child gets the tree as it is."; fi

  run --env "$SLUG" config push --yes
  [ "$CODE" = 0 ] || fail "'primitive --env $SLUG config push --yes' failed. Fix the problem above and run 'scripts/child-app.sh up $SLUG' again."
  run env use "$SLUG"
  [ "$CODE" = 0 ] || fail "'primitive env use $SLUG' failed. Run it again to select the child."

  local ran="No $INIT_HOOK hook ran."
  if [ "$HOOK_RAN" = 1 ]; then ran="$INIT_HOOK ran before the push."; fi
  say "The child \"$SLUG\" ($CHILD_APP_ID) is ready and selected." \
    "$ran" \
    "Rebuild the app so scripts/resolve-primitive-config.sh writes the child into primitive.json." \
    "Tear it down when the work ends: scripts/child-app.sh down $SLUG"
  if [ -n "${PRIMITIVE_ENV:-}" ]; then
    say "PRIMITIVE_ENV=$PRIMITIVE_ENV is exported in this shell and outranks the selection just written; unset it to use \"$SLUG\"."
  fi
}

down() {
  resolve_parent
  local got="$TMP_DIR/get.json"
  capture --env "$PARENT" apps children get "$SLUG" --json
  [ "$CODE" = 0 ] || fail_cli "--env $PARENT apps children get $SLUG --json"
  cp "$OUT" "$got"
  CHILD_APP_ID="$(json_get "$got" appId)"

  if [ "$SKIP_TEARDOWN" = 1 ]; then
    say "Skipping $TEARDOWN_HOOK: anything \"$SLUG\" created outside the platform is left behind for you to remove."
  else
    if [ "$(json_get "$got" local)" != true ]; then
      if [ -n "$(json_get "$got" localConflict.appId)" ]; then
        fail "The local environment \"$SLUG\" holds a different app, $(json_get "$got" localConflict.appId), not the child \"$SLUG\" ($CHILD_APP_ID)." \
          "'scripts/child-app.sh down $SLUG --skip-teardown' deletes it without the hook. Nothing was deleted."
      fi
      fail "The child \"$SLUG\" ($CHILD_APP_ID) is not registered on this machine, so its teardown hook cannot run against it." \
        "Run 'primitive env use $SLUG' to attach it, then run this again." \
        "'scripts/child-app.sh down $SLUG --skip-teardown' deletes it without the hook. Nothing was deleted."
    fi
    local local_name
    local_name="$(json_get "$got" localName)"
    verify_identity "$local_name" "Nothing was deleted."

    # ---- App teardown: scripts/child-app-teardown (see the header). ----
    run_hook "$TEARDOWN_HOOK" "$local_name" "The child \"$SLUG\" is kept; nothing was deleted."
    if [ "$HOOK_RAN" = 0 ]; then say "There is no $TEARDOWN_HOOK hook; nothing outside the platform is cleaned up."; fi
  fi

  # The parent was resolved before the hook ran: a hook that changed the
  # selection cannot redirect the delete to another parent's child.
  run --env "$PARENT" apps children delete "$SLUG" --yes
  [ "$CODE" = 0 ] || fail "'primitive --env $PARENT apps children delete $SLUG --yes' failed."
  say "Deleted the child \"$SLUG\" ($CHILD_APP_ID)."
  if [ "$(json_get "$got" selected)" = true ]; then
    say "\"$SLUG\" was selected; run 'primitive env use $PARENT' to select its parent."
  fi
}

PARENT=""
CHILD_APP_ID=""
HOOK_RAN=0
LISTED=no
if [ "$VERB" = up ]; then up; else down; fi
