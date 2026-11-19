#!/bin/zsh
# ios/tools/test.sh changed|quick|full — build once (build-for-testing), then test-without-building with parallel simulator clones.
#   changed: only the test classes that cover the changed files (default: uncommitted changes, or the last commit when the
#            tree is clean; BASE=<rev> to diff against a revision); unmapped app files fall back to quick. Default mode.
#   quick:   unit tests + appearance snapshots + a smoke set of UI flows on one simulator.
#   full:    every test on each simulator in DEVICES, the simulators side by side.
# Environment: DEVICES (;-separated simulator names), WORKERS (clones per simulator), DERIVED_DATA, SKIP_BUILD=1,
#   SLOWEST=n (also list the n slowest tests and seconds per class), DRY_RUN=1 (print the selection only).
# Screenshots: ios/screenshots/<mode>-<simulator>/, result bundles: ios/build/<mode>-<simulator>-<time>.xcresult.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
mode=${1:-changed}
smoke=(-only-testing:BirdCMTests
      -only-testing:BirdCMUITests/ResultFlows/testResultNormal
      -only-testing:BirdCMUITests/ResultFlows/testResultSeveralBirds
      -only-testing:BirdCMUITests/PlaceFlows/testGPSHomeAndNoPlace
      -only-testing:BirdCMUITests/RecordFlows/testCorrectSpeciesCountAndReset
      -only-testing:BirdCMUITests/LayoutFlows/testAlaskaRowAtLargestType
      -only-testing:BirdCMUITests/EngineFlows/testRealInferenceEagle)
# changed file (relative to ios/) -> test classes; QUICK = run the smoke set as well.
covers() {
  case $1 in
    UITests/FlowCase.swift|Tests/Fixtures/*|project.yml|BirdCM.xcodeproj/*|BirdCM/Resources/*|Models/*) print QUICK ;;
    UITests/*.swift) [[ -f $1 ]] && sed -nE 's/^final class ([A-Za-z0-9]+):.*/BirdCMUITests\/\1/p' $1 || print QUICK ;;
    Tests/*.swift) [[ -f $1 ]] && sed -nE 's/^final class ([A-Za-z0-9]+):.*/BirdCMTests\/\1/p' $1 || print QUICK ;;
    BirdCM/ResultView.swift|BirdCM/BirdPager.swift|BirdCM/PhotoView.swift|BirdCM/Editors.swift|BirdCM/Confirm.swift)
      print -l U/ResultFlows U/ResultExtraFlows U/RecordFlows U/LayoutFlows T/AppearanceSnapshots T/LogicTests ;;
    BirdCM/DisplayCrop.swift) print -l T/DisplayCropTests T/AppearanceSnapshots U/ResultExtraFlows ;;
    BirdCM/Place.swift|BirdCM/Geo.swift|BirdCM/GeoNetwork.swift) print -l U/PlaceFlows T/GeoTests T/LogicTests T/AppearanceSnapshots ;;
    BirdCM/Records.swift) print -l U/RecordFlows U/LayoutFlows U/LargestTypeMoreFlows T/AppearanceSnapshots ;;
    BirdCM/Stats.swift|BirdCM/Ledger.swift|BirdCM/EBird.swift)
      print -l U/LargestTypeFlows U/LargestTypeMoreFlows U/LayoutFlows T/Step4Snapshots T/AppearanceSnapshots T/LibraryTests T/CrossPlatformTests ;;
    BirdCM/Explore.swift) print -l U/LargestTypeMoreFlows U/LayoutFlows T/AppearanceSnapshots T/Step4Snapshots ;;
    BirdCM/Settings.swift|BirdCM/AboutView.swift|BirdCM/Diagnostics.swift) print -l U/RecordFlows U/LargestTypeMoreFlows T/AppearanceSnapshots T/Step4Snapshots ;;
    BirdCM/Reference.swift|BirdCM/ReferenceView.swift) print -l T/ReferenceTests U/ReferenceFlows U/RecordFlows U/LargestTypeMoreFlows T/AppearanceSnapshots ;;
    BirdCM/Library.swift|BirdCM/Store.swift) print -l U/RecordFlows T/LibraryTests T/CrossPlatformTests T/LogicTests T/LaunchTests ;;
    BirdCM/Engine.swift|BirdCM/Pixels.swift) print -l U/EngineFlows U/LaunchFlows T/PipelineTests T/PerformanceTests T/LaunchTests T/LogicTests ;;
    BirdCM/SelfTest.swift) print -l T/PerformanceTests U/RecordFlows ;;
    BirdCM/Rarity.swift) print -l U/ResultFlows U/ResultExtraFlows T/LogicTests T/Step4Snapshots ;;
    BirdCM/Preview.swift) print -l U/ResultFlows U/ResultExtraFlows T/AppearanceSnapshots T/Step4Snapshots ;;
    BirdCM/App.swift) print -l QUICK U/LaunchFlows T/LaunchTests ;;
    BirdCM/*) print QUICK ;;
  esac
}
case $mode in
  changed) default_devices='BirdCM 18 Pro'; default_workers=3
    base=${BASE:-}
    [[ -z $base ]] && { [[ -n $(git status --porcelain -- .) ]] && base=HEAD || base=HEAD~1 }
    files=(${(f)"$( { git diff --name-only --relative $base -- .; git ls-files --others --exclude-standard -- .; } | sort -u)"})
    # an App file's UI flows (U/) only with UI=1: unit tests and snapshots cover it on the Mac (owner, 2026-11-19);
    # an edited UI test file still runs its own classes
    picked=($(for f in $files; do covers $f; done | { [[ -n ${UI:-} ]] && cat || grep -v '^U/' } | sed -e 's#^U/#BirdCMUITests/#' -e 's#^T/#BirdCMTests/#' | sort -u))
    echo "changed since $base: ${#files} file(s) -> ${picked:-nothing to test}"
    (( ${#picked} )) || exit 0
    # xcodebuild narrows to the most specific identifier (BirdCMTests + BirdCMTests/X runs only X): never pass both.
    only=()
    if (( ${picked[(Ie)QUICK]} )); then
      for t in $smoke; do c=${${t#-only-testing:}%/*}; (( ${picked[(Ie)$c]} )) || only+=($t); done
      picked=(${picked:#BirdCMTests/*})
    fi
    for t in ${picked:#QUICK}; do only+=(-only-testing:$t); done ;;
  quick) default_devices='BirdCM 18 Pro'; default_workers=3; only=($smoke) ;;
  full) default_devices='BirdCM 18 Pro;BirdCM 15'; default_workers=3; only=() ;;
  *) echo "usage: $0 changed|quick|full" >&2; exit 2 ;;
esac
[[ -n ${DRY_RUN:-} ]] && { print -l -- "${only[@]:-(everything)}"; exit 0 }
devices=("${(@s:;:)${DEVICES:-$default_devices}}")
workers=${WORKERS:-$default_workers}
dd=${DERIVED_DATA:-DerivedData}
mkdir -p build
start=$SECONDS
if [[ -z ${SKIP_BUILD:-} ]]; then
  xcodebuild -project BirdCM.xcodeproj -scheme BirdCM -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO build-for-testing -quiet
  echo "build-for-testing $((SECONDS-start)) s"
fi
xctestrun=("$dd"/Build/Products/*.xctestrun)
stamp=$(date +%Y%m%d-%H%M%S)
pids=()
for device in $devices; do
  slug=${device// /-}
  shots="$PWD/screenshots/$mode-$slug"
  rm -rf "$shots"; mkdir -p "$shots"
  TEST_RUNNER_SCREENSHOT_DIR="$shots" xcodebuild test-without-building -xctestrun "${xctestrun[1]}" \
    -destination "platform=iOS Simulator,name=$device" -parallel-testing-enabled YES -parallel-testing-worker-count "$workers" \
    -resultBundlePath "build/$mode-$slug-$stamp.xcresult" $only > "build/$mode-$slug-$stamp.log" 2>&1 &
  pids+=($!)
done
failed=0
for i in {1..$#pids}; do
  if wait ${pids[$i]}; then echo "${devices[$i]}: passed"; else failed=1; echo "${devices[$i]}: FAILED — build/$mode-${devices[$i]// /-}-$stamp.log"; fi
  python3 tools/xcresult_summary.py "build/$mode-${devices[$i]// /-}-$stamp.xcresult" ${SLOWEST:-0} || true
done
echo "$mode: $((SECONDS-start)) s wall"
exit $failed
