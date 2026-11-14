#!/usr/bin/env bash
# Used by Claude (no local Swift toolchain): waits for the CI run of one commit and prints failures.
# usage: waitrun.sh <commit-sha> ; waits for the CI run of that exact commit, prints jobs, failing steps, error annotations
sha="$1"; api=https://api.github.com/repos/Maubro1/lifepath
for i in $(seq 1 120); do
  st=$(curl -s "$api/actions/runs?head_sha=$sha&per_page=1" | python -c "import sys,json;r=json.load(sys.stdin)['workflow_runs'];print(r[0]['status']+' '+str(r[0]['conclusion'])+' '+str(r[0]['id']) if r else 'none')")
  case "$st" in completed*) break;; esac
  sleep 20
done
echo "RUN: $st"
id=${st##* }
curl -s "$api/actions/runs/$id/jobs" | python -c "
import sys,json,urllib.request
for j in json.load(sys.stdin)['jobs']:
  print('JOB',j['name'],j['conclusion'])
  for s in j['steps']:
    if s['conclusion'] not in ('success','skipped'): print('   STEP',s['name'],s['conclusion'])
  if j['conclusion']=='failure':
    for a in json.load(urllib.request.urlopen('$api/check-runs/%d/annotations'%j['id'])):
      if a['annotation_level']=='failure': print('   ERR',a['message'][:400])
"
