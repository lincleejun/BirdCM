#!/bin/zsh
# ios/tools/test.sh quick|full — build once (build-for-testing), then test-without-building with parallel simulator clones.
#   quick: unit tests + appearance snapshots + a smoke set of UI flows on one simulator.
#   full:  every test on each simulator in DEVICES, the simulators side by side.
# Environment: DEVICES (;-separated simulator names), WORKERS (clones per simulator), DERIVED_DATA, SKIP_BUILD=1,
#   SLOWEST=n (also list the n slowest tests and seconds per class).
# Screenshots: ios/screenshots/<mode>-<simulator>/, result bundles: ios/build/<mode>-<simulator>-<time>.xcresult.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
mode=${1:-quick}
case $mode in
  quick) default_devices='BirdCM 18 Pro'; default_workers=3
    only=(-only-testing:BirdCMTests
      -only-testing:BirdCMUITests/ResultFlows/testResultNormal
      -only-testing:BirdCMUITests/ResultFlows/testResultSeveralBirds
      -only-testing:BirdCMUITests/PlaceFlows/testGPSHomeAndNoPlace
      -only-testing:BirdCMUITests/RecordFlows/testCorrectSpeciesCountAndReset
      -only-testing:BirdCMUITests/LayoutFlows/testAlaskaRowAtLargestType
      -only-testing:BirdCMUITests/EngineFlows/testRealInferenceEagle) ;;
  full) default_devices='BirdCM 18 Pro;BirdCM 15'; default_workers=3; only=() ;;
  *) echo "usage: $0 quick|full" >&2; exit 2 ;;
esac
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
