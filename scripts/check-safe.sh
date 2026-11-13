#!/bin/sh
# Same @safe contract as orchestration-cluster-api-dlang / nano-coder-d.
cd "$(dirname "$0")/.." || exit 2
status=0
for f in $(grep -rL '^@safe:' source --include='*.d'); do
    echo "$f(1): Error: module is missing a module-level \`@safe:\` (see scripts/check-safe.sh)" >&2
    status=1
done
if grep -rnE '^[[:space:]]*@(system|trusted)[[:space:]]*:' source --include='*.d' >&2; then
    echo "Error: \`@system:\`/\`@trusted:\` turn off @safe for the rest of a scope; mark the smallest function or lambda instead" >&2
    status=1
fi
if grep -rnE '(^|[^/`[:alnum:]])@system\b' source --include='*.d' | grep -vE ':[[:space:]]*(///|//)' | grep -v 'extern (C)' >&2; then
    echo "Error: \`@system\` is only allowed on \`extern (C)\` declarations; use @safe, or @trusted on the smallest function or lambda" >&2
    status=1
fi
trusted() { grep -nE '(^|[^/`[:alnum:]])@trusted\b' "$@" | grep -vE ':[[:space:]]*(///|//)'; }
ratchet() {
    budget=$(cat "$3")
    what=${4:-\`@trusted\`}
    if [ "$2" -gt "$budget" ]; then
        echo "Error: $2 $what $1, budget is $budget ($3); make the code safe, or justify the escape and raise the budget" >&2
        status=1
    elif [ "$2" -lt "$budget" ]; then
        echo "check-safe: $2 $what $1, below the budget of $budget; lower $3 to $2" >&2
    fi
}
SAFEIO="source/d8ctl/safeio.d"
if [ -f "$SAFEIO" ]; then
    ratchet "outside safeio.d" "$(trusted -r source --include='*.d' | grep -c -v '^source/d8ctl/safeio.d:')" scripts/trusted-budget
    ratchet "in safeio.d" "$(trusted "$SAFEIO" | wc -l | tr -d ' ')" scripts/trusted-budget-safeio
    code() { grep -rnE "$1" source --include='*.d' | grep -v '^source/d8ctl/safeio.d:' | grep -vE ':[0-9]+:[[:space:]]*(///|//)'; }
else
    ratchet "outside safeio.d" "$(trusted -r source --include='*.d' | wc -l | tr -d ' ')" scripts/trusted-budget
    code() { grep -rnE "$1" source --include='*.d' | grep -vE ':[0-9]+:[[:space:]]*(///|//)'; }
fi
if code '\bnew Thread\b|\bisDaemon\b|\bstd\.concurrency\b' >&2; then
    echo "Error: do not start raw threads; keep the CLI single-threaded" >&2
    status=1
fi
if code '\b__gshared\b|(^|[^[:alnum:]_])union\b' >&2; then
    echo "Error: \`__gshared\` and unions are only allowed in safeio.d" >&2
    status=1
fi
ratchet "outside safeio.d" "$(code '\bassumeIsolated\(' | wc -l | tr -d ' ')" scripts/isolation-budget "\`assumeIsolated\` calls"
if ! find source -name '*.d' | sort | xargs awk '
    FNR == 1 { ok = 0 }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*\/\// { ok = 1; next }
    /(^|[^\/`[:alnum:]])@trusted([^[:alnum:]_]|$)|[.]assumeIsolated\(/ {
        if (!ok && FILENAME !~ /safeio[.]d$/ || !ok && $0 ~ /@trusted/) { printf "%s(%d): Error: `@trusted` or `assumeIsolated` without a comment above it saying why it is safe\n", FILENAME, FNR > "/dev/stderr"; bad = 1 }
        if ($0 ~ /[;{}][[:space:]]*$/) ok = 0
        next
    }
    /[;{}][[:space:]]*$/ { ok = 0 }
    END { exit bad }'; then
    status=1
fi
exit $status
