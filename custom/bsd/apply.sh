#!/bin/sh
# Apply the BSD patch set on top of a pristine upstream cloudflared checkout.
#
# Design notes (why this replaces the old "merge custom/patch branch" flow):
#   * A merge of a year-old branch onto a new upstream tag produces conflict
#     markers, and `git add -A` happily commits them -> the build dies with
#     syntax errors far away from the real conflict.
#   * Upstream keeps reorganising the packages we touch, so carrying whole
#     stale copies of files (e.g. the Makefile) silently reverts upstream work
#     (this is what broke `-mod=vendor` after the vendor/ directory was removed).
#
# So the patch is expressed as the smallest possible set of edits:
#   1. overlay/  -> files that upstream does not have at all (BSD only)
#   2. build-tag extension -> existing shared files that only need freebsd/
#      openbsd/netbsd added to their //go:build line
#   3. one targeted Makefile edit (netbsd was dropped from LOCAL_OS upstream)
#
# Every step is idempotent and fails loudly if upstream renamed or removed a
# file we depend on, instead of producing a release that cannot compile.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
OVERLAY="$ROOT/custom/bsd/overlay"

cd "$ROOT"

log() { printf '  [bsd-patch] %s\n' "$*"; }
die() { printf '  [bsd-patch] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Whole-file overlays: files that only exist because of the BSD port.
#    If upstream ever ships the same path itself, we stop and let a human
#    decide instead of silently shadowing upstream code.
# ---------------------------------------------------------------------------
for src in $(cd "$OVERLAY" && find . -type f -name '*.go' | sed 's|^\./||' | sort); do
	dst="$ROOT/$src"
	if [ -f "$dst" ]; then
		# Re-running on an already patched tree is fine as long as the content
		# is ours; otherwise upstream shipped its own file and a human has to
		# reconcile them.
		if cmp -s "$OVERLAY/$src" "$dst"; then
			log "already applied $src"
			continue
		fi
		# A stale copy of our own overlay (older patch revision): replace it.
		if grep -q 'custom/bsd overlay' "$dst"; then
			cp "$OVERLAY/$src" "$dst"
			log "updated stale overlay $src"
			continue
		fi
		die "upstream now ships $src itself - drop it from custom/bsd/overlay/ and adapt the patch"
	fi
	mkdir -p "$(dirname "$dst")"
	cp "$OVERLAY/$src" "$dst"
	log "add $src"
done

# ---------------------------------------------------------------------------
# 2. Extend //go:build lines of shared POSIX files to the BSDs.
# ---------------------------------------------------------------------------
add_bsd_tags() {
	file=$1
	[ -f "$file" ] || die "file not found: $file"

	if head -n 1 "$file" | grep -q 'freebsd'; then
		log "build tag already covers BSD: $file"
		return 0
	fi

	first=$(head -n 1 "$file")
	case "$first" in
	'//go:build '*) ;;
	*) die "expected a //go:build line on line 1 of $file, got: $first" ;;
	esac

	tag=$(printf '%s' "$first" | sed 's|^//go:build ||')
	work=$(mktemp)
	{
		printf '//go:build %s || freebsd || openbsd || netbsd\n' "$tag"
		tail -n +2 "$file"
	} >"$work"
	cat "$work" >"$file"
	rm -f "$work"
	log "build tag += freebsd/openbsd/netbsd: $file"
}

add_bsd_tags diagnostic/network/collector_unix.go
add_bsd_tags diagnostic/network/collector_unix_test.go
add_bsd_tags ingress/icmp_posix.go
# ingress/icmp_posix_test.go is intentionally NOT extended: it exercises a real
# ICMP proxy over sockets, and on the BSDs ingress falls back to icmp_generic.go
# (the "not implemented" stub - icmp_linux.go/icmp_darwin.go are OS specific).
# Enabling it would only produce a failing test.

# ---------------------------------------------------------------------------
# 3. Makefile: re-add netbsd to the LOCAL_OS -> TARGET_OS mapping.
#    Upstream dropped it (only freebsd/openbsd are still mapped) and without it
#    `make cloudflared` aborts with "This system's OS netbsd isn't supported".
# ---------------------------------------------------------------------------
[ -f Makefile ] || die "Makefile not found"

if grep -q 'netbsd' Makefile; then
	log "Makefile already maps netbsd"
else
	work=$(mktemp)
	awk '
		/^else ifeq \(\$\(LOCAL_OS\),openbsd\)$/ { in_openbsd = 1; print; next }
		in_openbsd && /TARGET_OS \?= openbsd/ {
			print
			print "else ifeq ($(LOCAL_OS),netbsd)"
			print "    TARGET_OS ?= netbsd"
			in_openbsd = 0
			next
		}
		{ print }
	' Makefile >"$work"

	mv "$work" Makefile

	if ! grep -q 'TARGET_OS ?= netbsd' Makefile; then
		die "could not inject the netbsd branch into the Makefile (LOCAL_OS mapping changed upstream?)"
	fi
	log "Makefile: netbsd mapped to TARGET_OS"
fi

# ---------------------------------------------------------------------------
# 4. Sanity check: the target OS must be reachable for all three BSDs.
# ---------------------------------------------------------------------------
for os in freebsd openbsd netbsd; do
	grep -q "$os" Makefile || die "Makefile does not mention $os after patching"
done

log "BSD patch applied"
