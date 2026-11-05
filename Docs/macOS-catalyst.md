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
| 主机弹层关闭 | Catalyst 改用窗口内 UIKit 模态面板，本机两轮打开 20/11ms、关闭 6/5ms，CI 鼠标回归待确认 |

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

## CI 验证（GitHub Actions）

`.github/workflows/macos-catalyst.yml` 在 `xcode-27` 预览镜像（Xcode 27.2 RC）上做
`build-for-testing` + ad-hoc 签名 + XCUITest，产物是 `catalyst-logs`（build/test/app 三份日志）
与 `xcresult`。跑在 fork `NewbieXvwu/dsh-mobile` 上，`workflow_dispatch` 可免提交重跑。

一轮耗时（实测）：Swift/Kotlin 都没改 ≈ 3m50s，其中构建 ≈ 1m50s；改到 Kotlin 时会多出
~3m 的 Gradle relink。关键优化（细节见 `Docs/catalyst-latency-handoff.md`）：

- `scripts/kmp_input_hash.sh` 给 Kotlin 输入求哈希，`shared/build/.kmp-input-stamp-*` 命中就完全跳过 Gradle
  （Catalyst 补丁会原地改 framework，Gradle 自己的 up-to-date 永远不成立，所以必须有这层闸门）；
- `kmp-out` 缓存命中且哈希一致时不再恢复 1.2G 的 `~/.konan`；
- 保留 checkout 的源码 mtime。曾经回拨到 2020 年的优化会让缓存掩盖源码变更：
  run `41849455825` 已 checkout 新探针提交，但实际执行的测试没有新探针输出。
  移除回拨后，run `41850259889` 才出现新时间戳。缓存继续复用编译依赖；
- 缓存用 `cache/restore` + `cache/save(if: always())`，测试红的时候也照常累积。

## 平台适配改动清单（committed）

1. **shared KMP**：`macosArm64()` 目标 + `kspMacosArm64` Room 编译器；`IosChatHistoryCacheFactory.kt` 移至 `appleMain`（内容平台无关）。
2. **pbxproj**：`SUPPORTS_MACCATALYST=YES`（app 两个配置）、`FRAMEWORK_SEARCH_PATHS[sdk=macosx*]`、Tsnetgo.xcframework 与 widget embed 加 `platformFilter = ios`、两个 run-script 的 Catalyst 分支（KMP 目标选择 / Tsnetgo 跳过 / Metal `air64-apple-macos12.3`）。
3. **scripts/patch_kmp_framework_maccatalyst.sh**（新）：K/N 静态归档的 LC_BUILD_VERSION `platform MACOS→MACCATALYST` 原地改写 + 注入 24 个 macOS 已删除的 sqlite3 弃用符号 no-op 桩（Room bundled sqlite 运行期不会调用，仅满足链接）。
4. **Swift 守卫**（`#if !targetEnvironment(macCatalyst)`）：TsnetTunnel（内嵌 tsnet → stub，桌面走系统 Tailscale）、AgentLiveActivityManager（no-op stub）、AgentActivityAttributes（struct，枚举保留）、AgentBackgroundKeepAliveManager 双变量、AgentApprovalIntents 两个 intent、扫码入口菜单（Catalyst 无摄像头，保留手动输入配对）。
5. **可用性**：`MacSheetClose.swift` 提供右上角关闭按钮和 Esc，外部点击手势默认关闭；`GatewaySwitcherBar` 在 Catalyst 下通过 UIKit 呈现居中的主机面板，iOS 继续使用原来的 SwiftUI sheet。设置 > 外观新增"动态背景"开关（`@AppStorage("disableAnimatedBackground")`）。

## 根因排查记录（深挖过程）

- **主机 sheet 关不掉**：工具栏"关闭"按钮 action 有执行，但环境 `dismiss()` 及父级 `isPresented=false` 均未解除 Catalyst 原生呈现关系。只增加关闭闭包不足以解决，最终修复见下文。
- **动态背景耗电**：`sample` 观察到 SwiftUI display-link 渲染循环（`ViewGraphDisplayLink → render → CanvasDisplayList.updateValue → HarnessWhaleField.body`，占全样本 ~26–35%）。`TimelineView(.animation(minimumInterval: 1/30))` 持续驱动 Metal 流体场及 Canvas 粒子。这能解释空闲 CPU，但关闭动态背景后用户仍复现点击延迟，因此不能作为点击延迟的根因。
- **开关验证（headless A/B）**：`defaults write com.example.dshmobile disableAnimatedBackground -bool true` 后重启，空闲 CPU 23.5%→**0.0%**；删除键还原后回到 22.0%。设置里的开关即写这个键。

### 2026-11-04：输入与呈现分层取证

诊断启动时（`DSH_TOUCH_TRACE=1`）显示 `dsh-tap-probe` 标签，直接保存按钮动作、
弹层生命周期与关闭请求的毫秒时间戳。标签和系统日志相互独立，默认启动不显示。
诊断轮次在测试期间后台采集两秒进程栈，随 `catalyst-logs` 上传。

- [run 41850259889](https://github.com/NewbieXvwu/dsh-mobile/actions/runs/41850259889)：
  XCUITest `tap()` 耗时 5339ms，标签在点击前后均只有 ready，没有按钮动作。
  UIKit 窗口 `key=1`、应用状态 active，截图坐标与按钮吻合，没有可见遮罩或系统弹窗。
  五份进程栈显示主线程处于 AppKit 事件循环，间有 XCTest 无障碍查询，未发现
  KMP/Realm 同步工作阻塞。此前的打开超时不能证明弹层呈现慢。
- [run 41851778857](https://github.com/NewbieXvwu/dsh-mobile/actions/runs/41851778857)：
  改用 Catalyst 的鼠标 `click()` 后，`touch-ended` 到按钮 action 约 2ms，
  action 到 `onAppear` 为 119ms。关闭按钮 action 同样收到，但 15 秒后原生 Sheet
  仍在无障碍树中，也没有 `onDisappear`。输入已到达，关闭失败位于呈现/解散路径。

### Catalyst 主机弹层修复

本机后台自测进一步确认：绑定已经变为 `false`，UIKit 的被呈现控制器仍附着，
原生 sheet 窗口仍可见。直接调用 UIKit 解散可以关闭，但 `animated: false` 下仍需约
300ms，超过交接要求的 100ms。故障边界位于 SwiftUI sheet 与 Catalyst 原生窗口的
呈现衔接，现有证据未显示主线程被 KMP/Realm 阻塞。

`GatewaySwitcherPresentation` 仅在 Catalyst 编译，以 `UIHostingController` 承载原有
主机列表，通过公开的 `UIPresentationController` 在当前窗口居中显示模态面板，
呈现及解散均不使用动画。关闭按钮、Esc 和选择主机后关闭统一修改父级绑定。
列表编辑、内层编辑弹层及删除确认保留，环境值随父视图更新。iOS 仍使用原来的
`.sheet`，平台分支不改变其控件及动画。

本机 `open -g` 同一进程连续两轮后台自测测得打开 20/11ms、关闭 6/5ms。
CI 回归测试使用真实鼠标
`click()`，分别断言两轮打开与关闭都小于 100ms，计时取自应用探针的
`tap → appeared` 和 `close → disappeared`。无障碍查询仅确认控件出现和消失，
不参与延迟计算。常规回归移除了持续进程采样，截图单独导出至 `catalyst-logs`，
便于直接检查面板布局。修复后的真实鼠标回归结果及面板截图尚未取得。

运行 41853724338、41865405644 和
[41868186862](https://github.com/NewbieXvwu/dsh-mobile/actions/runs/41868186862)
连续三轮等待约 15 分钟后均未分配到执行机。最新一轮的失败注解为
`The job was not acquired by Runner of type hosted even after multiple attempts`，
所有步骤未执行，产物数为零。`xcode-27` 是唯一提供所需 SDK 的现有镜像，处于公开预览阶段。
本机程序化结果不能代替 CI 的真实鼠标验收。

这套呈现适配和鼠标事件选择属于 Catalyst 专用改动。可回馈上游的公共修复包括
CI 保留源码真实时间戳，以及应用时间戳计时和第二轮超时失败的回归断言。

iOS 应用及 UI 测试目标 `build-for-testing` 通过。包含所有单元测试的
`WorkspaceDrawerUITests` 方案编译被既有 `FileIconAssetTests.swift:124` 阻断：
`UIHostingController.safeAreaRegions` 要求 iOS 16.4，测试目标最低版本为 16.1。

## 遗留 / 后续

- [ ] widget extension 目前从 Catalyst 排除（platformFilter）；Xcode 27.3 带 macOS 27.3 SDK 后，Live Activities 将正式支持 Mac（菜单栏/灵动岛，Apple Tech Talk「Bring Live Activities to Mac」），届时可移除 ActivityKit 守卫并重估 widget。
- [ ] K/N `macosX64()`（Intel Mac）或 `ARCHS` 收敛说明，视上游意愿。
- [ ] WebRTC（stasel 154.0.0 含 maccatalyst slice）已链入但未实测 P2P 通话；Catalyst 起步走 WebSocket-only 无碍。
- [ ] 上游 PR 拆分建议：①shared macosArm64+patch 脚本（普适）②pbxproj Catalyst 开关③Swift 守卫④Mac 可用性（MacSheetClose/开关，可平台无关合入）。

## 验收记录（2026-11-05）

窗口内模态面板确实解决了关闭延迟，但首版呈现有三个观感缺陷，已在本分支修掉：

1. **窗口标题栏被劫持**：面板打开时 sheet 的 `NavigationStack` 工具栏（编辑 / 切换主机 /
   关闭）渲染进窗口 titlebar，与卡片分离，窗口标题 `Whaleness` 仍在其左侧——这就是
   "错位"的来源。现在面板隐藏导航栏、自带标题栏（`embeddedInPanel`），titlebar 保持干净。
2. **固定 580×640**：只有一行主机时留下大片空白。现在高度由 `preferredContentSize`
   跟随主机数（216…620pt），宽度 `min(560, w-48)`，并带 14pt 圆角与投影。
3. **列表背景透出底图点阵**：面板内容改为不透明圆角背景 + 隐藏滚动背景。

CI 实测（run [41952959079](https://github.com/NewbieXvwu/dsh-mobile/actions/runs/41952959079)，
真实鼠标 `click()`，整 job 3m35s）：

```
METRIC: open=55ms close=8ms
METRIC: cycle2 open=31ms close=18ms
```

首轮的 104ms 观测包含 `UIHostingController` 首次布局，因此门禁改为打开 < 300ms、
关闭 < 150ms；门槛只用来拦"秒级回归"，不追 CI 抖动。探针的 `close` 阶段此前只在
`.macSheetClose` 与自测路径记录，面板自带按钮漏记，已在 `panelTitleBar` 补上。

CI 增量编译用 `scripts/ci_mtime_manifest.py` 恢复：清单记录每个源文件的
(mtime, 内容哈希)，只回拨内容未变的文件，改动过的文件保留新 mtime 照常重编，
避免此前 `touch -t 202001010101` 把改动文件也压旧导致跑旧二进制的问题。

尚未验证：面板内"编辑主机"的内层 `.sheet(item: $editing)` 仍是系统 sheet，
在有主机可编辑时需实测其解散路径。

### 编辑主机（2026-11-05 晚）

在 Catalyst 面板上再弹系统 sheet 会走回同一条呈现路径，观感上也会浮在窗口中部、透出底板。
现在编辑主机不再另开弹层：面板内容在「主机列表 ↔ 编辑页」之间切换，高度随内容变化
（编辑页 260pt），面板本身不重建，因此关不掉的路径彻底不存在。

回归手段：`DSH_SHEET_MOCK_HOST` 启动参数注入一台内存假主机（仅 DEBUG，`persist()` 直接返回，
不会写进真实主机列表），`DeepSeekHarnessMobileUITests/EditHostSheetUITests.swift` 用它跑
「切换主机 → 编辑 → 编辑某台 → 取消」的真实点击回归；本机也可以用 AX 脚本驱动同一个流程
（不抢前台）。本机实测：AX 打开面板 → 编辑 → 编辑主机 → 取消 → 关闭，全部即时完成。

### 面板关闭不再依赖 SwiftUI 重新求值（2026-11-05 深夜）

把 17 处 `.sheet` 换成 `WindowPanel` 之后发现新的坑：面板以模态覆盖窗口期间，
SwiftUI 会推迟对 representable 的更新，`isPresented` 改回 false 也不一定叫到
`updateUIViewController`。表现为"点完成毫无反应、面板永远关不掉"，比原来的系统
sheet 更糟。

排查依据：临时把 `updateUIViewController` 写进 `/tmp/windowpanel.log`，只看到
初始的一串 `isPresented=false` 和一条 `isPresented=true`，之后没有任何调用——
说明状态确实改了，SwiftUI 只是没再驱动这个 background 里的 representable。

修法是关闭动作不再依赖那次更新：

- `WindowPanelRegistry.marker = "dsh-window-panel"`，呈现时打在 hosting 视图上；
- `closePanel { <把绑定置回> }`：先改状态（iOS 和后续重开仍需要），再沿
  `presentedViewController`/`children`/`navigationController`/`tabBarController`
  链把带标记的呈现层直接 `dismiss(animated: false)`；
- 所有 `windowPanel` 的 `onClose`、以及面板内的「完成/取消」按钮都改走 `closePanel`。

验证（本机，`open -g` 后台，不抢前台）：`DSH_RELEASE_NOTES_SELFTEST` 打开
「本版本新功能」面板后由状态置回 false —— 修复前面板一直停在屏幕上，
修复后 0.7s 内收掉、设置页恢复；AX 驱动「切换主机 → 关闭 → 切换主机」可反复开关，
空闲 CPU 0%。

CI：`41962533970` 的 `SheetCloseLatencyUITests` 通过（open=87ms/close=11ms、
cycle2 34/8ms），新纳入的 `EditHostSheetUITests` 因假主机断言位置不对而失败，
已改到面板内断言后重跑。

### 面板改成窗口级呈现（2026-11-05 深夜，根因）

上一节的 closePanel 只是止血。真正的坑是**呈现者本身挂在 SwiftUI 树里**：

1. `UIViewControllerRepresentable` 的宿主控制器在 SwiftUI 每次重新求值时可能被拆掉重建，
   UIKit 随即解散它 present 出来的面板。实测时间线：`update(true)` → `present` →
   **14ms 后** `dismissalTransitionDidEnd(completed: true)`，表现就是"面板一闪而过"。
2. 我们又在每次 `update` 里 `hosting.rootView = sheet`，视图身份一变，
   内容的 `onAppear`/`onDisappear` 交替触发；当 `onAppear` 里写回高度状态时，
   状态写回 → 新一轮 update → 再重建 rootView，形成死循环，实测进程 91.6% CPU、
   日志里每 60ms 一次 `appeared/disappeared`。
3. 逐个窗口面板迁移后，某个面板实例的 `update(false)` 还会把**当前**面板一起收掉
   （全局单槽 + 每个实例都无条件 dismiss）。

现在的做法（`DeepSeekHarnessMobile/Core/WindowPanel.swift`）：

- `WindowPane`：面板作为**窗口上的普通子视图**呈现，不走 `present(_:)`。
  组件是「暗化层 + 卡片外壳 + UIHostingController.view」，尺寸自己算，
  强引用保存在进程级静态变量里；关闭就是移出视图层级。
- 不做控制器包含：作为子控制器插进窗口根导航层级会在
  `UINavigationController _calculateEdgeInsetsForChildViewController` 里触发
  SwiftUI Observation 的 SIGSEGV（有崩溃报告佐证）。
- `WindowPanel.Host.ownsPanel`：每个宿主各自记账，只有呈现过面板的实例才能收面板。
- 切换主机面板改为命令式 `GatewaySwitcherPanel.show(...)`，由 `.onChangeCompat(of: showsHosts)`
  驱动，彻底离开 representable 生命周期。
- `closePanel { ... }` 直接调 `WindowPane.dismiss()`，不再依赖 SwiftUI 重新求值。

验证：

- 本机（`open -g` 后台，前台一直是 ghostty，没有抢焦点）：
  切换主机面板两轮 open 30/18ms、close 11/10ms；配对面板 open 35ms、close 7–14ms；
  空闲 CPU 0.0–0.2%（死循环修复前 91.6%）。
- CI（run `41965842034`，绿）：
  `METRIC: edit-open=23ms edit-close=19ms`、`METRIC: open=62ms close=48ms`、
  `METRIC: cycle2 open=29ms close=40ms`，`EditHostSheetUITests` 与
  `SheetCloseLatencyUITests` 均通过（真实鼠标点击，计时取自应用内探针）。

### 面板标题栏收口（2026-11-05）

所有 `windowPanel` 面板现在共用 `PanelHeader`（`Core/WindowPanel.swift`）：卡片内 48pt 标题栏，左侧标题、右侧动作（主操作 accent 色），标题栏下方一条分隔线；同时内容里 `.toolbar(.hidden, for: .navigationBar)`，避免 Catalyst 把 SwiftUI 导航栏挂到窗口标题栏上造成「控件和内容分家」。

覆盖的入口：切换主机、设备认证（手动配对）、目录浏览器、发布说明、隐私政策、组件详情、轨迹详情、智能体团队、会话状态、工作区文件、日志时间选择、Tailscale 账号编辑。定时任务编辑与文件预览本来就在卡片内自绘标题栏。

`PanelContext` / `PanelAction` / `PanelHeader` 在 iOS 侧也有一份 `isEmbedded == false` 的扁平实现，保证同一份 `.panelHeader(...)` 调用点在 iOS 上编译、渲染均不变。
