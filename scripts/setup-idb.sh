#!/bin/bash
# One-command idb setup for this app's UI smoke test and ad-hoc UI driving.
#
# `scripts/smoke-test.sh ui_signin` and any hand-driven `idb ui tap/text/key`
# need two pieces, and neither is obvious to assemble by hand:
#
#   - idb_companion — the native half, a Homebrew formula.
#   - idb           — the `fb-idb` Python client, which needs Python **3.12**
#                     (it calls asyncio.get_event_loop, removed in 3.14) and
#                     cannot be pip-installed into Homebrew's Python, which is
#                     PEP 668 externally-managed. So it goes in a venv.
#
# Usage:
#   bash scripts/setup-idb.sh
#
#   PRIMITIVE_IDB_VENV=<dir>    where the fb-idb venv lives. Defaults to
#                               ~/.local/share/primitive/idb-venv, outside any
#                               one app, so apps scaffolded from this template
#                               share a single install.
#   PRIMITIVE_IDB_COMPANION     host:port of a caller-managed companion. When
#                               set, the local idb_companion is not installed
#                               (same meaning as in smoke-test.sh).
#
# The run is idempotent: it assesses the client and the companion separately
# and installs only what is missing or broken, so re-running on a set-up
# machine touches neither brew nor pip. Every failure exits non-zero with a
# message naming the actual problem — a half-finished install is never
# reported as success, because the symptom otherwise surfaces much later as an
# unexplained "cannot run accessibility commands".
#
# `smoke-test.sh` finds the venv's client on its own, so no shell-profile edit
# is required for the smoke test. For ad-hoc `idb` commands, put ~/.local/bin
# on PATH (the script prints the line if it isn't).

set -euo pipefail

log()  { printf '[setup-idb] %s\n' "$*" >&2; }
note() { printf '[setup-idb]   %s\n' "$*" >&2; }
fail() { printf '[setup-idb] FAIL: %s\n' "$*" >&2; }

# The physical path of an existing directory, with every symlink, "..", "." and
# trailing slash resolved away. `pwd -P` is allowed to keep a leading "//"
# (POSIX leaves two leading slashes implementation-defined), and "//" is still
# the root directory, so that spelling is folded too. Fails if the path cannot
# be entered.
canonicalize() {
    local resolved
    resolved="$(CDPATH= cd -P -- "$1" 2>/dev/null && pwd -P)" || return 1
    case "$resolved" in
        //) resolved="/" ;;
        //*) resolved="/${resolved#//}" ;;
    esac
    printf '%s\n' "$resolved"
}

VENV="${PRIMITIVE_IDB_VENV:-$HOME/.local/share/primitive/idb-venv}"
# Written into a venv this script creates. Nothing without this marker is ever
# deleted, so an unrelated directory at $VENV is reported, not removed.
MARKER=".primitive-setup-idb"
LOCAL_BIN="$HOME/.local/bin"

# ────────────────────────────────────────────────────────────────────────
# 1. macOS only — idb drives the iOS Simulator. Checked before anything is
#    installed, so a wrong machine costs nothing.
# ────────────────────────────────────────────────────────────────────────

if [ "$(uname -s)" != "Darwin" ]; then
    fail "idb drives the iOS Simulator; it only works on macOS (this is $(uname -s))."
    exit 1
fi

# ────────────────────────────────────────────────────────────────────────
# 2. Assess what is already there. The two halves are independent: a machine
#    with a working client and no companion gets only the companion.
# ────────────────────────────────────────────────────────────────────────

# The client this run vouches for at the end. Empty until one is found/built.
CLIENT=""
if command -v idb >/dev/null 2>&1 && idb --help >/dev/null 2>&1; then
    CLIENT="$(command -v idb)"
elif [ -x "$VENV/bin/idb" ] && "$VENV/bin/idb" --help >/dev/null 2>&1; then
    CLIENT="$VENV/bin/idb"
fi

# `--help`/`--version` are the safe probes: they neither talk to a simulator
# nor start a server.
companion_ok=0
if [ -n "${PRIMITIVE_IDB_COMPANION:-}" ]; then
    companion_ok=1
elif command -v idb_companion >/dev/null 2>&1 \
     && { idb_companion --help >/dev/null 2>&1 || idb_companion --version >/dev/null 2>&1; }; then
    companion_ok=1
fi

if [ -n "$CLIENT" ] && [ "$companion_ok" = "1" ]; then
    log "Already set up: client $CLIENT, companion ready. Nothing to do."
    exit 0
fi

# ────────────────────────────────────────────────────────────────────────
# 3. Companion (Homebrew), only when it is missing or unrunnable.
# ────────────────────────────────────────────────────────────────────────

if [ "$companion_ok" != "1" ]; then
    if ! command -v brew >/dev/null 2>&1; then
        fail "idb_companion is installed with Homebrew, which is not on PATH."
        note "Install Homebrew (https://brew.sh), then re-run this script, or"
        note "install the formula yourself:  brew install facebook/fb/idb-companion"
        exit 1
    fi
    log "Installing idb_companion (brew install facebook/fb/idb-companion)..."
    if ! brew install facebook/fb/idb-companion; then
        fail "idb installation failed: brew install facebook/fb/idb-companion did not succeed."
        exit 1
    fi
    hash -r
    # Verified, not assumed: a formula that installs but cannot run is an
    # installation failure here rather than a mystery at the first tap.
    if ! command -v idb_companion >/dev/null 2>&1 \
       || ! { idb_companion --help >/dev/null 2>&1 || idb_companion --version >/dev/null 2>&1; }; then
        fail "idb_companion was installed but is not runnable."
        note "Try 'brew reinstall facebook/fb/idb-companion' and check 'idb_companion --help'."
        exit 1
    fi
    log "idb_companion ready: $(command -v idb_companion)"
fi

# ────────────────────────────────────────────────────────────────────────
# 4. The fb-idb client in a Python 3.12 venv, only when no runnable client
#    was found above.
# ────────────────────────────────────────────────────────────────────────

if [ -z "$CLIENT" ]; then
    # 4a. A Python 3.12 interpreter: on PATH, under the brew prefix, or
    # installed with brew as a last resort.
    PY=""
    if command -v python3.12 >/dev/null 2>&1; then
        PY="$(command -v python3.12)"
    elif command -v brew >/dev/null 2>&1; then
        prefix="$(brew --prefix python@3.12 2>/dev/null || true)"
        if [ -n "$prefix" ] && [ -x "$prefix/bin/python3.12" ]; then
            PY="$prefix/bin/python3.12"
        else
            log "Installing Python 3.12 (brew install python@3.12)..."
            if brew install python@3.12; then
                hash -r
                prefix="$(brew --prefix python@3.12 2>/dev/null || true)"
                if command -v python3.12 >/dev/null 2>&1; then
                    PY="$(command -v python3.12)"
                elif [ -n "$prefix" ] && [ -x "$prefix/bin/python3.12" ]; then
                    PY="$prefix/bin/python3.12"
                fi
            fi
        fi
    fi
    if [ -z "$PY" ]; then
        fail "no Python 3.12 interpreter, and it could not be installed."
        note "fb-idb requires Python 3.12 specifically: it calls asyncio.get_event_loop,"
        note "which was removed in 3.14, so 3.13/3.14 will not do."
        note "Install it (brew install python@3.12) and re-run this script."
        exit 1
    fi
    log "Using Python 3.12: $PY"

    # 4b. The venv. Only a directory this script marked as its own is ever
    # rebuilt; anything else is reported so the user decides.
    case "$VENV" in
        /*) ;;
        *) fail "PRIMITIVE_IDB_VENV must be an absolute path (got: $VENV)."; exit 1 ;;
    esac
    if [ "$VENV" = "/" ] || [ "$VENV" = "$HOME" ]; then
        fail "PRIMITIVE_IDB_VENV must be a dedicated directory, not $VENV."
        exit 1
    fi
    if [ -L "$VENV" ]; then
        fail "$VENV is a symlink; this script will not write through one."
        note "Remove it, or point PRIMITIVE_IDB_VENV at a real directory."
        exit 1
    fi
    if [ -e "$VENV" ] && [ ! -d "$VENV" ]; then
        fail "$VENV exists and is not a directory."
        note "Remove it, or point PRIMITIVE_IDB_VENV somewhere else."
        exit 1
    fi
    if [ -d "$VENV" ]; then
        # Resolved before anything is deleted, not just compared as text:
        # "$HOME/", "//" and any ".."/symlinked alias name a directory the
        # string checks above happily let through, and the next step is rm -rf.
        venv_real="$(canonicalize "$VENV")" || venv_real=""
        home_real="$(canonicalize "$HOME")" || home_real="$HOME"
        if [ -z "$venv_real" ]; then
            fail "$VENV exists but could not be resolved to a real path."
            note "Nothing was deleted. Point PRIMITIVE_IDB_VENV at a path this script can own."
            exit 1
        fi
        if [ "$venv_real" = "/" ] || [ "$venv_real" = "$home_real" ]; then
            fail "PRIMITIVE_IDB_VENV must be a dedicated directory, not $venv_real."
            exit 1
        fi
        if [ ! -f "$venv_real/$MARKER" ]; then
            fail "$venv_real already exists and was not created by this script (no $MARKER marker)."
            note "Nothing was deleted. Remove that directory yourself, or set"
            note "PRIMITIVE_IDB_VENV to a path this script can own."
            exit 1
        fi
        log "Rebuilding $venv_real (its idb is missing or not runnable)..."
        rm -rf "$venv_real"
    fi

    log "Creating the fb-idb venv at $VENV..."
    # Each mutation below is checked rather than left to `set -e`: a permission
    # or quota failure must say "idb installation failed" like every other
    # failure here, not exit silently mid-install.
    if ! mkdir -p "$(dirname "$VENV")"; then
        fail "idb installation failed: could not create $(dirname "$VENV")."
        exit 1
    fi
    if ! "$PY" -m venv "$VENV"; then
        fail "idb installation failed: could not create a venv at $VENV."
        exit 1
    fi
    # The marker goes in before pip runs, so an interrupted install still
    # leaves a directory this script recognises as its own and can rebuild.
    # Without it the venv would be unowned — and the next run would refuse to
    # touch it — so a marker that cannot be written takes the venv with it.
    if ! touch "$VENV/$MARKER"; then
        fail "idb installation failed: could not write the ownership marker $VENV/$MARKER."
        note "Removing the venv this run just created, so a re-run starts clean."
        rm -rf "$VENV"
        exit 1
    fi
    log "Installing fb-idb into the venv..."
    if ! "$VENV/bin/pip" install fb-idb; then
        fail "idb installation failed: pip install fb-idb did not succeed."
        note "The venv at $VENV is left in place; re-run this script to retry."
        exit 1
    fi
    if [ ! -x "$VENV/bin/idb" ]; then
        fail "idb installation failed: fb-idb installed but $VENV/bin/idb is missing."
        exit 1
    fi
    CLIENT="$VENV/bin/idb"
fi

# ────────────────────────────────────────────────────────────────────────
# 5. Put the venv's client on PATH via ~/.local/bin — but never over
#    something the user manages there.
# ────────────────────────────────────────────────────────────────────────

# The link is a convenience: the client is already usable at $VENV/bin/idb and
# smoke-test.sh finds it there. So a filesystem failure in this section is
# reported as a note and the run still succeeds — it never leaves the caller
# guessing, and it never claims a link that does not exist.
if [ "$CLIENT" = "$VENV/bin/idb" ] && ! mkdir -p "$LOCAL_BIN"; then
    note "could not create $LOCAL_BIN — skipping the idb symlink."
    note "idb is installed at $CLIENT; use it directly or link it yourself."
elif [ "$CLIENT" = "$VENV/bin/idb" ]; then
    link="$LOCAL_BIN/idb"
    link_it=0
    if [ -L "$link" ]; then
        dest="$(readlink "$link")"
        case "$dest" in
            "$VENV"/*) link_it=1 ;;                      # ours already
            *) [ -e "$link" ] || link_it=1 ;;            # broken: a stale link
        esac
        if [ "$link_it" = "0" ]; then
            note "$link is a symlink to $dest — leaving it alone."
        fi
    elif [ -e "$link" ]; then
        note "$link already exists and is not managed by this script — leaving it alone."
        note "Use $CLIENT directly, or remove $link and re-run."
    else
        link_it=1
    fi
    if [ "$link_it" = "1" ]; then
        if ln -sfn "$CLIENT" "$link"; then
            log "Linked $link -> $CLIENT"
        else
            note "could not write $link — idb is installed at $CLIENT."
            note "Use it directly, or link it yourself once $LOCAL_BIN is writable."
        fi
    fi

    case ":$PATH:" in
        *":$LOCAL_BIN:"*) ;;
        *)
            note "$LOCAL_BIN is not on your PATH. scripts/smoke-test.sh finds the venv"
            note "client on its own, but for ad-hoc idb commands add this to your shell:"
            note 'export PATH="$HOME/.local/bin:$PATH"'
            ;;
    esac
fi

# ────────────────────────────────────────────────────────────────────────
# 6. Verify the client this run vouches for actually runs.
# ────────────────────────────────────────────────────────────────────────

if ! "$CLIENT" --help >/dev/null 2>&1; then
    fail "$CLIENT is installed but not runnable."
    note "This is usually the Python version: fb-idb needs 3.12 (asyncio.get_event_loop"
    note "was removed in 3.14). Remove $VENV and re-run this script with python3.12"
    note "available, or check '$CLIENT --help' for the real error."
    exit 1
fi

log "idb is ready: $CLIENT"
log "Try it:  bash scripts/smoke-test.sh ui_signin"
