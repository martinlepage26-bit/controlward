# Sourced by bin/test-portable (bash) and bin/test-native-app (zsh); needs PROJECT_ROOT and BUILD_ROOT.
# Argus planted reds 9 and 10 are pharos-api vitest cases. Unless CW_PHAROS_PLANTED_REDS already names a vitest JSON
# report, run the pharos-api suite with a JSON report so the Swift tally can count them. vitest is found either at the
# repo root (root package.json, `yarn install`; run with --config pharos-api/vitest.config.ts, as `yarn test:worker`)
# or at the old pharos-api/node_modules path. If neither exists, nothing is set: the tally counts reds 9 and 10 as
# RED-NOT-RUN (with the reason, never "accepted"), so the slice 3 total prints MISMATCH and the run fails.
# A missing vitest is never a silent pass.
if [ -z "${CW_PHAROS_PLANTED_REDS:-}" ]; then
  cw_pharos_report="${BUILD_ROOT}/pharos-vitest.json"
  rm -f "${cw_pharos_report}"
  if [ -x "${PROJECT_ROOT}/node_modules/.bin/vitest" ]; then
    (cd "${PROJECT_ROOT}" && ./node_modules/.bin/vitest run --config pharos-api/vitest.config.ts \
      --reporter=default --reporter=json --outputFile.json="${cw_pharos_report}") || true
    export CW_PHAROS_PLANTED_REDS="${cw_pharos_report}"
  elif [ -x "${PROJECT_ROOT}/pharos-api/node_modules/.bin/vitest" ]; then
    (cd "${PROJECT_ROOT}/pharos-api" && ./node_modules/.bin/vitest run \
      --reporter=default --reporter=json --outputFile.json="${cw_pharos_report}") || true
    export CW_PHAROS_PLANTED_REDS="${cw_pharos_report}"
  else
    echo "pharos-planted-reds: no vitest at node_modules/.bin or pharos-api/node_modules/.bin (run yarn install at the repo root);" \
      "Argus reds 9 and 10 will print RED-NOT-RUN and the slice 3 total will MISMATCH (the run fails)" >&2
  fi
fi
