#!/bin/bash
# .github/release-notes.sh <version>   (from the repo root, full history and tags fetched) -> release notes (markdown).
# Changes = commits (no merges) since the previous release/v* tag reachable from HEAD (for a final version: the previous
# final one, so 0.0.2 lists everything since 0.0.1 even after 0.0.2-beta), or since the first commit.
# One line per bullet: GitHub renders a newline in a release body as a line break.
# shellcheck disable=SC1111  # the Chinese quotes “” in the text are meant
set -euo pipefail
v=$1
skip=(--exclude "release/v$v"); [[ $v == *-* ]] || skip+=(--exclude 'release/v*-*')
prev=$(git describe --tags --abbrev=0 --match 'release/v*' "${skip[@]}" HEAD 2>/dev/null || true)
dmg="观羽-$v-arm64.dmg"
ascii="GuanYu-$v-arm64.dmg"
since=${prev:+"since $prev"}; since=${since:-"since the first commit"}
notice="https://github.com/lincleejun/BirdCM/blob/release/v$v/NOTICE.md"
cat <<EOF
**下载 / Download:** \`$ascii\`（列表里若还有 \`$dmg\`，是同一个文件 / if also listed, the same file）
**校验 / Verify:** \`shasum -a 256 -c --ignore-missing $ascii.sha256\`

## 须知

- 仅支持 **Apple Silicon（M 系列）Mac、macOS 15 或更高版本**。
- **未经 Apple 公证**（没有付费开发者账号，只做了 ad-hoc 签名），第一次打开会被 macOS 拦下。把 观羽.app 拖进“应用程序”后，打开一次，再到 系统设置 → 隐私与安全性 → 点“仍要打开”；或在终端运行 \`xattr -dr com.apple.quarantine /Applications/观羽.app\`。
- 模型文件不在安装包里：第一次使用时从 [bioclip-bird](https://github.com/lincleejun/bioclip-bird/releases) 和 [bioclip-bird-heads](https://github.com/lincleejun/bioclip-bird-heads/releases) 的 Releases（以及 BirdNET 地理模型的发布页）下载，约 0.8 GB，逐个做 sha256 校验。
- iOS 版：\`GuanYu-$v-iOS-unsigned.ipa\`（iOS 17+，**未签名**），用 AltStore / Sideloadly 等以自己的 Apple ID 签名后安装；模型已在包内，离线可用。包内带 IUCN 受威胁等级（CC BY 4.0，见 NOTICE.md）。
- 许可：代码 MIT；眼/喙与飞行两个模型头**仅限非商业用途**；其余模型与数据各有许可，见 [NOTICE.md]($notice)。

## Notes

- **Apple Silicon (M-series) Macs with macOS 15 or later only.**
- **Not notarised** (no paid Apple developer account; ad-hoc signed), so macOS blocks the first launch. After dragging 观羽.app to Applications, open it once, then System Settings → Privacy & Security → "Open Anyway"; or run \`xattr -dr com.apple.quarantine /Applications/观羽.app\` in Terminal.
- Models are not in the app: they are downloaded on first use from the [bioclip-bird](https://github.com/lincleejun/bioclip-bird/releases) and [bioclip-bird-heads](https://github.com/lincleejun/bioclip-bird-heads/releases) releases (plus the BirdNET geo model's release), about 0.8 GB, each sha256-checked.
- iOS: \`GuanYu-$v-iOS-unsigned.ipa\` (iOS 17+, **unsigned**): sign it with your own Apple ID via AltStore / Sideloadly to install; models are inside, works offline. It carries the IUCN Red List categories (CC BY 4.0, see NOTICE.md).
- Licences: code MIT; the eye/beak and flight heads are **non-commercial use only**; other models and data have their own terms, see [NOTICE.md]($notice).

## 改动 / Changes ($since)

EOF
git log --no-merges --format='- %s (%h)' ${prev:+"$prev..HEAD"}
