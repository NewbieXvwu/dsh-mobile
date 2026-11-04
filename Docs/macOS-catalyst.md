# Mac Catalyst 客户端（变体 1）构建与可用性评估

> 分支 `feat/macos-catalyst` · 基线 main@e4120e7 · 实测环境 Xcode 27.2 / macOS 27.2 SDK / Apple Silicon

## 结论速览

| 项 | 状态 |
| --- | --- |
| Catalyst Debug 构建 | ✅ BUILD SUCCEEDED（arm64） |
| Catalyst Release 构建 | ✅ BUILD SUCCEEDED（需 `ARCHS=arm64`，见下） |
| iOS 回归（generic/platform=iOS Debug） | ✅ BUILD SUCCEEDED（tsnetgo xcframework 本地产出后） |
| app 可运行 | ✅ 欢迎页/会话页/设置均正常渲染（用户实测） |
| 空闲 CPU（动态背景默认开） | ⚠️ ~22–23%（TimelineView 30fps + Metal 流体场 + Canvas 粒子） |
| 空闲 CPU（设置里关闭动态背景后） | ✅ **0.0%**（headless A/B 实测） |
| 已知交互缺陷 | sheet 内 `Environment(\.dismiss)` 在 Catalyst 不生效 → 已改闭包关闭 |

## 构建方法

前置：JDK 17（`JAVA_HOME` 指向 temurin 17）、Android SDK（`local.properties` 的 `sdk.dir`）、KMP macosArm64 产物由构建阶段自动产出。

```bash
export JAVA_HOME=/path/to/temurin-17/Contents/Home
xcodebuild -project DeepSeekHarnessMobile.xcodeproj -scheme DeepSeekHarnessMobile \
  -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/dsh-catalyst \
  -scmProvider system build ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  CODE_SIGN_ENTITLEMENTS= DEVELOPMENT_TEAM= LOCAL_DEVELOPMENT_TEAM=
```

要点：
- **`ARCHS=arm64` 必须带**（Release 默认编 Universal 2，K/N 目前只产出 macosArm64，x86_64 半边链接失败；后续可给 shared 加 `macosX64()` 目标或维持 arm64-only）。
- `-scmProvider system`：绕开本机 Xcode 内嵌 SCM XPC 挂死（环境相关，非仓库问题）。
- 签名关闭后产物可直接 ad-hoc 运行：`codesign --force --deep --sign - DshMobile.app`。

## 平台适配改动清单（committed）

1. **shared KMP**：`macosArm64()` 目标 + `kspMacosArm64` Room 编译器；`IosChatHistoryCacheFactory.kt` 移至 `appleMain`（内容平台无关）。
2. **pbxproj**：`SUPPORTS_MACCATALYST=YES`（app 两个配置）、`FRAMEWORK_SEARCH_PATHS[sdk=macosx*]`、Tsnetgo.xcframework 与 widget embed 加 `platformFilter = ios`、两个 run-script 的 Catalyst 分支（KMP 目标选择 / Tsnetgo 跳过 / Metal `air64-apple-macos12.3`）。
3. **scripts/patch_kmp_framework_maccatalyst.sh**（新）：K/N 静态归档的 LC_BUILD_VERSION `platform MACOS→MACCATALYST` 原地改写 + 注入 24 个 macOS 已删除的 sqlite3 弃用符号 no-op 桩（Room bundled sqlite 运行期不会调用，仅满足链接）。
4. **Swift 守卫**（`#if !targetEnvironment(macCatalyst)`）：TsnetTunnel（内嵌 tsnet → stub，桌面走系统 Tailscale）、AgentLiveActivityManager（no-op stub）、AgentActivityAttributes（struct，枚举保留）、AgentBackgroundKeepAliveManager 双变量、AgentApprovalIntents 两个 intent、扫码入口菜单（Catalyst 无摄像头，保留手动输入配对）。
5. **可用性**：`MacSheetClose.swift`（新）＝右上角关闭按钮 + Esc + 点击 sheet 外关闭；`GatewaySwitcherSheet` 改闭包关闭；设置 > 外观新增"动态背景"开关（`@AppStorage("disableAnimatedBackground")`）。

## 根因排查记录（深挖过程）

- **sheet 关不掉**：Xcode AX 驱动 + `log stream` 实证——toolbar"关闭"按钮 action **有执行**（日志 `close button tapped`），但 `Environment(\.dismiss)` 60 秒内不解散 presentation（Catalyst 下该 API 在此场景失效）。改为通过父级 `isPresented` 闭包关闭（全 app 其他 19 个 sheet 的既有模式）。
- **点击响应慢（10–20 秒）**：`sample` 实证主线程持续被 SwiftUI display-link 渲染循环占据（`ViewGraphDisplayLink → render → CanvasDisplayList.updateValue → HarnessWhaleField.body`，占全样本 ~26–35%），任何状态切换（如 dismiss 动画）都要在这个高负载主线程上排队重diff整棵视图树。根因是欢迎页动态背景：`TimelineView(.animation(minimumInterval: 1/30))` 驱动 Metal 流体场（`ShaderLibrary.harnessFluid`）+ Canvas 网格/鲸鱼粒子逐帧重算。
- **开关验证（headless A/B）**：`defaults write com.example.dshmobile disableAnimatedBackground -bool true` 后重启，空闲 CPU 23.5%→**0.0%**；删除键还原后回到 22.0%。设置里的开关即写这个键。

## 遗留 / 后续

- [ ] widget extension 目前从 Catalyst 排除（platformFilter）；Xcode 27.3 带 macOS 27.3 SDK 后，Live Activities 将正式支持 Mac（菜单栏/灵动岛，Apple Tech Talk「Bring Live Activities to Mac」），届时可移除 ActivityKit 守卫并重估 widget。
- [ ] K/N `macosX64()`（Intel Mac）或 `ARCHS` 收敛说明，视上游意愿。
- [ ] WebRTC（stasel 154.0.0 含 maccatalyst slice）已链入但未实测 P2P 通话；Catalyst 起步走 WebSocket-only 无碍。
- [ ] 上游 PR 拆分建议：①shared macosArm64+patch 脚本（普适）②pbxproj Catalyst 开关③Swift 守卫④Mac 可用性（MacSheetClose/开关，可平台无关合入）。
