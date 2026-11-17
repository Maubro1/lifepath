#!/usr/bin/env bash
# Used by Claude (no local iOS toolchain): waits for the CI run of one commit and prints failures.
# usage: ci-wait.sh <commit-sha>
# Polls with ETags: GitHub does not count "304 Not Modified" against the 60/hour anonymous limit.
sha="$1"; api=https://api.github.com/repos/Maubro1/lifepath
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
etag=""
get() { # get <url> <outfile>: GET with rate-limit wait; prints HTTP status
  while :; do
    code=$(curl -s -D "$tmp/h" -o "$2" -w '%{http_code}' ${etag:+-H "If-None-Match: $etag"} "$1")
    if [ "$code" = 403 ] || [ "$code" = 429 ]; then
      reset=$(grep -i '^x-ratelimit-reset:' "$tmp/h" | tr -dc '0-9'); now=$(date +%s)
      wait=$(( ${reset:-$((now+60))} - now + 5 )); [ "$wait" -lt 30 ] && wait=30
      echo "rate limited, waiting ${wait}s" >&2; sleep "$wait"; continue
    fi
    echo "$code"; return
  done
}
sleep "${CI_FIRST_WAIT:-300}"   # a run takes 10-15 min; the first look comes after 5 (GitHub allows 60 anonymous calls/hour)
for i in $(seq 1 60); do
  code=$(get "$api/actions/runs?head_sha=$sha&per_page=1" "$tmp/runs")
  if [ "$code" = 200 ]; then
    etag=$(grep -i '^etag:' "$tmp/h" | sed 's/^[^:]*: *//' | tr -d '\r')
    st=$(python -c "import sys,json;r=json.load(open(sys.argv[1])).get('workflow_runs',[]);print(r[0]['status']+' '+str(r[0]['conclusion'])+' '+str(r[0]['id']) if r else 'none')" "$tmp/runs")
    case "$st" in completed*) break;; esac
  fi
  sleep 120
done
echo "RUN: $st"
id=${st##* }; etag=""
get "$api/actions/runs/$id/jobs" "$tmp/jobs" >/dev/null
python - "$tmp/jobs" "$api" <<'EOF'
import sys, json, urllib.request
jobs = json.load(open(sys.argv[1])).get('jobs', [])
for j in jobs:
    print('JOB', j['name'], j['conclusion'])
    for s in j['steps']:
        if s['conclusion'] not in ('success', 'skipped'):
            print('   STEP', s['name'], s['conclusion'])
    if j['conclusion'] == 'failure':
        try:
            for a in json.load(urllib.request.urlopen('%s/check-runs/%d/annotations' % (sys.argv[2], j['id']))):
                if a['annotation_level'] == 'failure':
                    print('   ERR', a['message'][:400])
        except Exception as e:
            print('   (annotations unavailable: %s)' % e)
EOF
