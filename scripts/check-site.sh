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
# A glob matching nothing expands to itself, and the grep that then fails does
# so inside a process substitution, where set -e cannot see it: both link
# checks would examine zero files and this would still print "site checks
# passed". Note *.html is root-only, so a page under a subdirectory is out of
# scope and this is what says so.
[ -e "${html[0]}" ] || bad "no .html at the repo root; the link checks examined nothing"

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

# The hostname comes from the Worker's route, which is what serves this site.
# Not from CNAME: that is a Pages artifact and this site has none.
canonical="$(sed -n 's/^Canonical: *//p' "$sec")"
host="$(sed -n 's|.*pattern = "\([^/]*\)/\*".*|\1|p' worker/wrangler.toml)"
if [ -z "$host" ]; then
    bad "no route pattern in worker/wrangler.toml; cannot check Canonical"
elif [ "$canonical" = "https://$host/.well-known/security.txt" ]; then
    note "ok   Canonical matches the Worker route ($host)"
else
    bad "Canonical [$canonical] does not match the route host [$host]"
fi

expires="$(sed -n 's/^Expires: *//p' "$sec")"
if ! exp_epoch="$(date -u -d "$expires" +%s 2>/dev/null)"; then
    # Without this the failed substitution left the arithmetic below a unary
    # minus on the current epoch, and an unparseable date was reported as an
    # expiry twenty thousand days ago.
    bad "cannot parse Expires [$expires] in security.txt"
else
    left=$(( (exp_epoch - $(date -u +%s)) / 86400 ))
    if [ "$left" -le 0 ]; then
        bad "security.txt expired $(( -left )) days ago; set Expires a year out"
    elif [ "$left" -lt "${EXPIRY_WARN_DAYS:-0}" ]; then
        bad "security.txt expires in $left days; set Expires a year out"
    else
        note "ok   security.txt expires in $left days"
    fi
fi

# A sibling host is named by its label, the apex by its full name. Four full
# hostnames plus the licence measured about 800px in a 736px column and
# wrapped, and a new host lengthens every footer in the estate at once. Every
# other surface asserts this in its own test suite; these two pages are hand
# written and this file is the only thing that reads them.
echo
for page in "${html[@]}"; do
    foot="$(sed -n '/<footer>/,/<\/footer>/p' "$page")"
    if [ -z "$foot" ]; then
        bad "$page has no footer"
        continue
    fi
    for pair in "apt.pkg.haus:apt" "buildinfos.pkg.haus:buildinfos" \
                "reproducible.pkg.haus:reproducible"; do
        host="${pair%%:*}"; label="${pair##*:}"
        if printf '%s' "$foot" | grep -q "href=\"https://$host\">$label</a>"; then
            note "ok   $page names $host by its label"
        else
            bad "$page must link $host as <a ...>$label</a>, not by hostname"
        fi
    done
    # The apex and github keep their full names: the first is the domain
    # itself, the second is not on it and a label alone would be ambiguous.
    printf '%s' "$foot" | grep -q '>pkg\.haus</a>' \
        || bad "$page must link the apex as pkg.haus"
    printf '%s' "$foot" | grep -q '>github\.com/pkghaus</a>' \
        || bad "$page must link github.com/pkghaus whole"
done

# A section boundary is 3.5rem of gap with its rule in the middle. Set
# 2026-09-22 across the landing, buildinfos and reproducible; stats already
# had it. This page was the mildest of the three at 4rem - the Worker pages
# were at 5.5rem - but a boundary that differs between siblings is the thing
# the registry exists to stop. Pinned because the value drifts back on the
# next edit and nobody notices half a rem.
# The estate style registry carries the reasoning.
if grep -q 'section { border-bottom: 1px solid var(--line); padding: 1.75rem 0; }' index.html; then
    note "ok   sections are 1.75rem a side, so a boundary is 3.5rem"
else
    bad "sections must use padding: 1.75rem 0 (see web-style.md, Layout)"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "site checks passed"
else
    echo "site checks FAILED"
fi
exit "$fail"
