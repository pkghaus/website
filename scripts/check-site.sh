#!/usr/bin/env bash
#
# What can go wrong on a hand-written static site without anyone noticing:
# a local asset renamed and its reference left behind, an in-page anchor
# pointing at a heading that was retitled, and an RFC 9116 security.txt
# quietly passing its Expires date. None of these fail a deploy. Legacy
# Pages serves whatever is on the branch.
#
#   scripts/check-site.sh            structure only
#   EXPIRY_WARN_DAYS=90 ...          also fail when security.txt is near expiry
#
# Anchors and assets are checked on every push; the expiry window is what the
# weekly run adds, so the one manual edit this file needs a year is asked for
# three months early instead of discovered by a researcher who could not
# report a bug.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0
note() { printf '  %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

html=(*.html)

# Local assets: href/src values that are neither absolute URLs, in-page
# anchors, nor the analytics proxy path the edge serves rather than the repo.
for f in "${html[@]}"; do
    while read -r ref; do
        [ -n "$ref" ] || continue
        case "$ref" in
            http://*|https://*|//*|"#"*|mailto:*|/zk/*) continue ;;
        esac
        path="${ref#/}"
        path="${path%%#*}"
        path="${path%%\?*}"
        [ -n "$path" ] || continue          # "/" is the site root
        if [ -e "$path" ]; then
            note "ok   $f -> $path"
        else
            bad "$f references $ref, which is not in the repo"
        fi
    done < <(grep -oE '(href|src)="[^"]*"' "$f" | sed 's/^[a-z]*="//; s/"$//')
done

# In-page anchors must land on an id that exists in the same file.
for f in "${html[@]}"; do
    while read -r frag; do
        [ -n "$frag" ] || continue
        if grep -q "id=\"${frag}\"" "$f"; then
            note "ok   $f#$frag"
        else
            bad "$f links to #$frag, which no element in it defines"
        fi
    done < <(grep -oE 'href="#[^"]+"' "$f" | sed 's/^href="#//; s/"$//')
done

# security.txt: RFC 9116 requires Contact and Expires, and treats a file
# past its Expires as invalid.
sec=.well-known/security.txt
for field in Contact Expires Canonical; do
    if grep -q "^$field:" "$sec"; then
        note "ok   $sec has $field"
    else
        bad "$sec is missing $field"
    fi
done

canonical="$(sed -n 's/^Canonical: *//p' "$sec")"
host="$(cat CNAME)"
if [ "$canonical" = "https://$host/.well-known/security.txt" ]; then
    note "ok   Canonical matches CNAME ($host)"
else
    bad "Canonical [$canonical] does not match CNAME [$host]"
fi

expires="$(sed -n 's/^Expires: *//p' "$sec")"
left=$(( ( $(date -u -d "$expires" +%s) - $(date -u +%s) ) / 86400 ))
if [ "$left" -le 0 ]; then
    bad "security.txt expired $(( -left )) days ago; set Expires a year out"
elif [ "$left" -lt "${EXPIRY_WARN_DAYS:-0}" ]; then
    bad "security.txt expires in $left days; set Expires a year out"
else
    note "ok   security.txt expires in $left days"
fi

echo
[ "$fail" -eq 0 ] && echo "site checks passed" || echo "site checks FAILED"
exit "$fail"
