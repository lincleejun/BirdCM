# 发版（macOS 观羽.app）

只有推送 `release/v<版本号>` 这种 tag 才会发版；平时的 push、别的 tag、PR 都不会触发。流水线是
`.github/workflows/release.yml`，两个小脚本是 `.github/release-version.sh`（核对版本号）和
`.github/release-notes.sh`（生成发布说明）。

平时的检查在 `.github/workflows/ci.yml`：每次推送分支和每个 PR 都跑引擎 `uv run --locked pytest`（`macos-15`，没有模型，
模型相关的几项跳过）和网页 `npm run typecheck`、`npm run build`（`ubuntu-latest`）；任何一步失败 CI 就是红的。iOS 不在里面。

## 版本号

- 唯一的版本号在 `engine/pyproject.toml` 的 `version`。`macos/build.sh` 读它，写进 `Info.plist`，也用于 dmg 文件名。
- tag 必须是 `release/v` 加上**一字不差**的同一个版本号，否则流水线第一步就失败，并说明原因。
- 格式：`x.y.z`，或预发布版 `x.y.z-alpha`、`x.y.z-beta`、`x.y.z-rc`，后面可以带编号（`-beta2`、`-rc.1`）。
  只允许这几种后缀，因为 uv/Python 只认这些（`0.0.2-beta` 在 `uv.lock` 里记成 `0.0.2b0`，属正常）。
  版本号里有 `-` 的，在 GitHub 上标成 **Pre-release**。
- `web/package.json` 里的 `version` 没有任何代码读取，不需要跟着改。

## 发一个版本

```sh
# 1. 改版本号（例：0.0.2），并更新锁文件里的那一行
sed -i '' 's/^version = ".*"/version = "0.0.2"/' engine/pyproject.toml
(cd engine && uv lock)                 # uv.lock 里只会改 birdcm 的 version 一行
git commit -am "Release 0.0.2"
git push origin impl:main              # 先让代码进 main（本仓库的本地 impl 推成 main）

# 2. 给这个提交打 tag 并推送：推送就是发版
git tag release/v0.0.2
git push origin release/v0.0.2
```

第一个版本是 `0.0.1`（pyproject 里已经是 0.0.1）：`git tag release/v0.0.1 && git push origin release/v0.0.1`。

然后到 GitHub → Actions → **release** 看进度（估计 15–25 分钟，未实测），完成后在 Releases 页能看到 `观羽 v0.0.2`。

## iOS 安装包

CI 不构建 iOS（模型约 0.7 GB，要在本机编译）。流水线发布后在本机构建并上传未签名 IPA：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer V=0.0.2 OUT=ios/build/release-$V
xcodebuild -project ios/BirdCM.xcodeproj -scheme BirdCM -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath ios/DerivedData-device CODE_SIGNING_ALLOWED=NO build
mkdir -p $OUT/Payload && cp -Rc ios/DerivedData-device/Build/Products/Release-iphoneos/BirdCM.app $OUT/Payload/
(cd $OUT && zip -qry GuanYu-$V-iOS-unsigned.ipa Payload && shasum -a 256 GuanYu-$V-iOS-unsigned.ipa > GuanYu-$V-iOS-unsigned.ipa.sha256)
gh release upload release/v$V $OUT/GuanYu-$V-iOS-unsigned.ipa $OUT/GuanYu-$V-iOS-unsigned.ipa.sha256
```

公开包带 IUCN 等级（默认 `BIRDCM_BUNDLE_IUCN=1`）：构建时从 `engine/birdcm/data/iucn.csv` 写入包内稀有度表，许可 CC BY 4.0，署名在 About 与 NOTICE.md（依据见 `engine/birdcm/data/iucn-LICENSE.md`；2026-11-19 所有者确认许可依据并要求随工程打包）。要去掉就传 `BIRDCM_BUNDLE_IUCN=0`，它必须作为 xcodebuild 参数传入：放在命令前当环境变量，脚本阶段读不到。发布前核对包内 `Models/iucn-build-flag` 与预期一致。（0.0.2 的 ipa 是在打包 IUCN 之前用 `BIRDCM_BUNDLE_IUCN=0` 构建的，不含 IUCN，它的发布说明也这样写。）iOS 版本号在 `ios/project.yml` 与工程文件的 `MARKETING_VERSION`，与 `engine/pyproject.toml` 保持一致。

## 流水线做了什么

1. **gate**（`macos-15`，Apple Silicon）：核对 tag 和版本号；`uv run --locked pytest`（engine 测试；需要模型文件、
   或需要作者本机照片 / 稀有度表的测试在 CI 上会自动跳过）；`npm ci && npm run build`（web）。
2. **build**（`macos-15`）：运行 `macos/build.sh`（ad-hoc 签名，不做公证）；`hdiutil verify` 检查 dmg；算 sha256；
   把 dmg 和 `.sha256` 作为 workflow artifact（名为 `dmg`，保留 14 天）交给下一步。
   runner 说明见 GitHub 文档 <https://docs.github.com/en/actions/reference/runners/github-hosted-runners>
  （公开仓库免费；`macos-15` / `macos-26` / `macos-latest` 是 M1、3 核、7 GB 内存）。
3. **release**（`ubuntu-latest`，只有这一步有 `contents: write` 权限）：生成发布说明 → 建一个**草稿** release →
   上传 `GuanYu-<版本>-arm64.dmg`、`GuanYu-<版本>-arm64.dmg.sha256`、`观羽-<版本>-arm64.dmg` → 检查 GitHub 实际
   保存的文件名 → 发布草稿。

发布说明 = 固定的中英文须知（只支持 Apple Silicon + macOS 15+；未公证，第一次怎么打开；模型首次使用时下载；
iOS 未签名 ipa 怎么装、包内带 IUCN；许可）+ 自上一个 `release/v*` tag 以来的提交（不含 merge 提交；正式版从上一个正式版算起，
跳过中间的 beta/rc；第一个版本列出全部提交）。本地预览：`.github/release-notes.sh 0.0.1`。

### 中文文件名

GitHub 文档说上传的资产文件名里有“特殊字符、非字母数字字符”会被改名
（<https://docs.github.com/en/rest/releases/assets>）。所以每次都同时上传 ASCII 名的 `GuanYu-<版本>-arm64.dmg`
（内容完全相同）。如果 `观羽-…dmg` 被改了名，流水线会删掉那个改过名的副本，在日志里留一条警告，只保留
`GuanYu-…dmg`；没被改名就两个都在。`.sha256` 文件里两种名字各有一行，用
`shasum -a 256 -c --ignore-missing GuanYu-<版本>-arm64.dmg.sha256` 校验即可。实际是哪种情况，第一次真正发版后看
release 页面或 release 任务的 summary 才能确定（预演不会上传到 Releases）。

### 缓存

uv（依赖 wheel 和 python-build-standalone 的 CPython）、npm、exiftool 压缩包都有缓存。GitHub 规定 tag 上的运行
只能读取默认分支（main）的缓存，不能读别的 tag 的；所以只有在 main 上运行（例如预演）时才写缓存，发版前在 main 上
预演一次，正式发版就能用上。没有缓存也能跑，只是慢几分钟。

## 预演（不发版）

workflow 文件进了 main 之后，GitHub → Actions → **release** → **Run workflow**：

- “Use workflow from” 选 `main`，`dry_run` 保持勾选 → 跑 gate、build、release 三步，但 release 步骤只生成说明、不建
  release。看：
  - gate 里 pytest 的结尾（应全部通过，`SKIPPED` 只有模型 / 照片 / 稀有度表相关的几项）；
  - build 里 `build.sh` 每个 `==` 步骤、`signed N nested Mach-O files`、dmg 大小（约 215 MB）和 sha256；
  - 运行页底部的 **Artifacts → dmg**：下载下来，在自己的 Mac 上解压、打开 dmg、按说明去掉隔离属性后启动；
  - release 任务的 **Summary**：版本、prerelease 标记、文件列表、完整发布说明。
- 不勾选 `dry_run` 且选择一个 `release/v*` tag：对那个 tag 真正发版（用于重发，见下）。不勾选但选的是分支：直接报错，
  不会自己建 tag。

## 发版失败了怎么办

- **版本号不一致**（gate 第一步报错）：删掉 tag，改对版本号，再打 tag：
  ```sh
  git push origin :refs/tags/release/v0.0.2 && git tag -d release/v0.0.2
  # 改 engine/pyproject.toml + uv lock，提交，推送 main
  git tag release/v0.0.2 && git push origin release/v0.0.2
  ```
- **偶发失败**（网络、下载超时、runner 问题）：在失败的运行页点 **Re-run failed jobs**。如果 release 步骤留下了草稿，
  重跑时会先把那个草稿删掉再建；**已经发布的 release 不会被覆盖**（会报错停下）。
- **代码或流水线本身有问题**：tag 触发的运行用的是 tag 那个提交里的 workflow 和代码，重跑不会带上修复。先修好并推送
  main，再删掉 tag、在新提交上重新打同名 tag 并推送（命令同上）。若这个 tag 已经有发布了的 release，先在 Releases 页
  删除它（或 `gh release delete release/v0.0.2`）。
- 不想重新打 tag 时，也可以 Actions → release → Run workflow，选那个 tag，取消 `dry_run`，等于对该 tag 重新发版。
- **release 这一步本身反复失败**（它是唯一没法预演的一步）：gate 和 build 已经成功的话，dmg 就在那次运行的
  Artifacts 里，可以手工发布：
  ```sh
  V=0.0.2; gh run download <run-id> -n dmg -D out          # run-id 在运行页的地址里
  cp "out/GuanYu-$V-arm64.dmg" "out/观羽-$V-arm64.dmg"
  .github/release-notes.sh "$V" > notes.md                  # 在已 checkout 该 tag、带完整历史和 tag 的仓库里
  gh release create "release/v$V" --verify-tag --title "观羽 v$V" --notes-file notes.md \
    "out/GuanYu-$V-arm64.dmg" "out/GuanYu-$V-arm64.dmg.sha256" "out/观羽-$V-arm64.dmg"   # 预发布版加 --prerelease
  ```

## 不发布什么，为什么

- **不做公证、没有 Developer ID 签名**：需要付费的 Apple Developer Program。dmg 只有 ad-hoc 签名，别的 Mac 第一次打开
  会被 Gatekeeper 拦下，发布说明里写了怎么放行。以后有了 Developer ID，可按 `macos/README.md` 的方法签名和公证，
  再把证书和公证凭据作为 secret 加到流水线里。
- **没有 Intel 版**：`build.sh` 只构建 arm64（PyTorch 和打包的 Python 都是 arm64）。
- **不打包模型**：模型约 0.8 GB，各有许可，首次使用时从 bioclip-bird / bioclip-bird-heads 的 Releases（和 BirdNET
  地理模型的发布页）下载并校验 sha256；还没发布的几个文件（见 `models.toml` 里 `released = false`）用户暂时拿不到。
- **iOS 版只发未签名 ipa，CI 不构建**：没有付费开发者账号，免费签名的安装包不能分享给别人安装，所以上传的是未签名 ipa（见上文「iOS 安装包」），用户用 AltStore / Sideloadly 以自己的 Apple ID 签名后安装。
- **作者自己的照片**（`docs/prototype/img/`、`web/public/hero.jpg`）不在仓库里，CI 构建的 app 首页没有示例照片，
  只显示文字标志。
