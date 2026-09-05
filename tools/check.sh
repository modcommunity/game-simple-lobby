#!/usr/bin/env bash
#
# Every script parses, then every example runs.
#
#   tools/check.sh            parse pass, then every example
#   tools/check.sh --parse    parse pass only
#
# The --import pass registers class_name globals. Without it every cross-file type
# reference fails and it looks like dozens of unrelated errors — and after adding any
# script with a NEW class_name it has to be re-run, or the identifier does not resolve,
# the scene fails to load, and the process HANGS rather than exiting, because nothing
# ever reaches get_tree().quit().

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

GODOT="${GODOT:-godot}"
RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'
fails=0

echo "importing"
"$GODOT" --headless --path . --import >/dev/null 2>&1

echo "parsing"
while read -r f; do
    out="$("$GODOT" --headless --path . --check-only --script "res://${f#./}" 2>&1 \
        | grep -Ev '^(Godot Engine v|$)' \
        | grep -Eiv 'ObjectDB instances leaked|resources still in use|Pages in use exist at exit|at: (cleanup|clear|~PagedAllocator)')"
    if [ -n "$out" ]; then
        printf '  %sFAIL%s %s\n%s\n' "$RED" "$OFF" "$f" "$out"
        fails=$((fails + 1))
    fi
done < <(find game examples tools -name '*.gd' 2>/dev/null | sort)

[ "$fails" -eq 0 ] && printf '  %sok%s   every script parses\n' "$GRN" "$OFF"

echo
echo "the copy in dot-server-setup-test"
# game/ and scenes/ are copied into ../dot-server-setup-test by its setup.sh -- copied
# rather than linked, because they are compiled into that build and a symlink dangles
# in a container or a tarball. Both are gitignored there, so this repository is the
# only record of what they should contain.
#
# The drift is caused HERE and suffered THERE: fix the lobby, forget to re-run that
# project's setup.sh, and it deploys the old one. Both suites pass, because each tests
# the copy it has -- this one on the fix, that one on the code an operator actually
# runs. Different code, both green. That project checks the same thing from its side;
# this is the half that tells the person who caused it.
COPY="../dot-server-setup-test"
if [ -d "$COPY/game" ]; then
    stale=0
    for dir in game scenes; do
        [ -d "$dir" ] || continue
        # .uid files are deleted by that setup.sh and regenerated per project, so they
        # are expected to differ and are not compared.
        while read -r rel; do
            if [ ! -f "$COPY/$dir/$rel" ]; then
                printf '  %sFAIL%s %s/%s is not in the copy\n' "$RED" "$OFF" "$dir" "$rel"
                stale=$((stale + 1))
            elif ! cmp -s "$dir/$rel" "$COPY/$dir/$rel"; then
                printf '  %sFAIL%s %s/%s differs; re-run ../dot-server-setup-test/setup.sh\n' \
                    "$RED" "$OFF" "$dir" "$rel"
                stale=$((stale + 1))
            fi
        done < <(cd "$dir" && find . \( -name '*.gd' -o -name '*.tscn' \) \
            | sed 's|^\./||' | sort)
    done

    if [ "$stale" -eq 0 ]; then
        printf '  %sok%s   dot-server-setup-test has this lobby\n' "$GRN" "$OFF"
    else
        fails=$((fails + stale))
    fi
else
    # Not cloned beside this one, or never set up. There is no copy to be stale.
    printf '  %s--%s   ../dot-server-setup-test has no lobby copied in yet\n' "$RED" "$OFF"
fi

if [ "${1:-}" = "--parse" ]; then
    exit $((fails > 0))
fi

for scene in examples/headless_room examples/headless_net examples/dedicated examples/sandbox; do
    [ -f "$scene.tscn" ] || continue
    echo
    echo "running $scene"
    if ! "$GODOT" --headless --path . "res://$scene.tscn" "$@"; then
        printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$scene"
        fails=$((fails + 1))
    fi
done

echo
if [ "$fails" -eq 0 ]; then
    printf '%sall checks passed%s\n' "$GRN" "$OFF"
else
    printf '%s%d failed%s\n' "$RED" "$fails" "$OFF"
fi
exit $((fails > 0))
