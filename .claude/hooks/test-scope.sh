#!/bin/bash
# PreToolUse(Bash) hook: iOS tests run only for what changed (owner, 2026-11-19). Blocks, with the reason on stderr:
#   - xcodebuild test / test-without-building with no -only-testing (the whole suite)
#   - any UI flow suite (-only-testing:BirdCMUITests…, ios/tools/test.sh quick|full) without UI=1 in the command
# UI=1 is for when the owner asked for UI flows or a UI test file itself changed. Everything else passes untouched.
# Self-check: .claude/hooks/test-scope.sh --selftest
check() {
  local c=$1
  [[ $c == *UI=1* || $c == git\ * ]] && return 0      # ponytail: text matching; a git message naming xcodebuild passes
  if [[ $c == *xcodebuild* && $c =~ (^|[[:space:]])test(-without-building)?([[:space:]]|$) ]]; then
    [[ $c == *-only-testing* ]] || { echo "整套测试被拦下：只跑改动涉及的测试类（-only-testing:BirdCMTests/类名），或用 ios/tools/test.sh（changed 模式）。见 ios/README.md「测试」。" >&2; return 2; }
    [[ $c == *-only-testing:BirdCMUITests* ]] && { echo "UI 流程测试被拦下：能在 Mac 上验证的用单元测试和截图测试（BirdCMTests）。只有所有者要求或改了 UI 测试文件本身时，在命令里加 UI=1。" >&2; return 2; }
  fi
  if [[ $c =~ ios/tools/test\.sh[[:space:]]+(quick|full) ]]; then
    echo "test.sh ${BASH_REMATCH[1]} 含 UI 流程，被拦下：日常用 ios/tools/test.sh（changed）。所有者要求时加 UI=1。" >&2; return 2
  fi
  return 0
}
if [[ ${1:-} == --selftest ]]; then
  ok() { check "$1" 2>/dev/null; [[ $? == "$2" ]] || { echo "FAIL ($2): $1"; exit 1; }; }
  ok 'xcodebuild test-without-building -xctestrun x' 2
  ok 'xcodebuild test -scheme BirdCM' 2
  ok 'xcodebuild test-without-building -xctestrun x -only-testing:BirdCMTests/GeoTests' 0
  ok 'xcodebuild test-without-building -only-testing:BirdCMTests/X -only-testing:BirdCMUITests/RecordFlows' 2
  ok 'UI=1 xcodebuild test-without-building -only-testing:BirdCMUITests/RecordFlows' 0
  ok 'xcodebuild build-for-testing -scheme BirdCM' 0
  ok 'ios/tools/test.sh' 0
  ok 'ios/tools/test.sh quick' 2
  ok 'UI=1 ios/tools/test.sh full' 0
  ok 'git commit -m "xcodebuild test notes"' 0
  echo "selftest ok"; exit 0
fi
cmd=$(jq -r '.tool_input.command // empty')
check "$cmd"
