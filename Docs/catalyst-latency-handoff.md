# 任务：诊断 Mac Catalyst 客户端「点击 sheet 打开/关闭延迟数秒」

> 2026-11-04 执行进展：事件分层取证已完成。Catalyst 的 `tap()` 未送达按钮，
> 改用鼠标 `click()` 后复现真实关闭故障。主机弹层现改用 Catalyst 专用的窗口内
> UIKit 模态面板，本机连续两轮后台打开 20/11ms、关闭 6/5ms。CI 连续三次未分配到
> 执行机，修复后的真实鼠标验收尚未完成。
> 最新证据及修法见 `Docs/macOS-catalyst.md`。下文保留接手时的诊断基线。

你接手一个已经构建成功、可运行、但交互延迟异常的 Mac Catalyst 客户端。目标不是"再猜一轮"，而是**用可复现的测量把延迟定位到具体一环并修掉**。所有基础设施（CI、埋点、测试）已经就绪，你的主要工作是读数据、缩小范围、改代码。

---

## 1. 仓库与环境

- 工作目录：`~/dsh-mobile`，当前分支 **`ci/probe`**（HEAD = `git log -1`；`feat/macos-catalyst` 指向同一份内容，两条分支都推在 fork 上）
- 这份文档就是交接材料本身：`Docs/catalyst-latency-handoff.md`
- 已就位的诊断基础设施（都在本分支）：`DeepSeekHarnessMobile/Core/TouchTrace.swift`（事件埋点）、`Core/MacSheetClose.swift` 里的 `SheetDiagnostics`（`DSH_SHEET_SELFTEST=1` 自测）、`DeepSeekHarnessMobileUITests/SheetCloseLatencyUITests.swift`（XCUITest + `METRIC:` 输出）、`.github/workflows/macos-catalyst.yml`（CI）
- `origin` = 上游 `Clarklevis1995/dsh-mobile`（**禁止 push**，用户自行与上游沟通）
- `fork` = `NewbieXvwu/dsh-mobile`（可以 push，CI 跑在这里）
- 机器：macOS 27.0.1，Xcode 27.2（iOS/macOS 27.2 SDK），arm64
- JDK：`/Users/newbiexvwu/.local/share/mise/installs/java/temurin-17.0.21+9/Contents/Home`（temurin-17，KMP 构建必需）
- Android SDK：`~/Library/Android/sdk`（`local.properties` 已配置，KMP 的 android target 配置阶段需要）
- Gradle 下载需要代理：`~/.gradle/gradle.properties` 已配置 `127.0.0.1:7890`（用户级，不在仓库里）

### 构建（本机，Debug）

```bash
cd ~/dsh-mobile
export JAVA_HOME=/Users/newbiexvwu/.local/share/mise/installs/java/temurin-17.0.21+9/Contents/Home
xcodebuild -project DeepSeekHarnessMobile.xcodeproj -scheme DeepSeekHarnessMobile \
  -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /tmp/dsh-catalyst-dd -scmProvider system build \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  CODE_SIGN_ENTITLEMENTS= DEVELOPMENT_TEAM= LOCAL_DEVELOPMENT_TEAM=
```

产出的 `DshMobile.app` 需要 `codesign --force --deep --sign -` 才能启动（ad-hoc）。

### 已知的构建坑（不要重新踩）

1. `xcodebuild` 必须加 `-scmProvider system`，否则内嵌 SCM 的 XPC 会挂住。
2. Release 必须 `ARCHS=arm64`：Kotlin/Native 只有 `macosArm64` 产物，Universal 会因 x86_64 半边链接失败。
3. 链接阶段依赖 `scripts/patch_kmp_framework_maccatalyst.sh`：把 ar 归档内每个 `.o` 的 `LC_BUILD_VERSION` 从 platform=macOS 改成 MACATALYST，并注入 24 个 macOS `libsqlite3.tbd` 缺失的弃用符号 stub。脚本由 Xcode 的 build phase 自动调用。
4. Xcode 26.3 / macos-15 runner **无法**构建本项目：代码用到 iOS 27.1 的 `toolbarVerticalEdge`（`DeepSeekHarnessMobile/Views/WorkspaceView.swift:782`），必须有 27.x SDK。

---

## 2. 症状（用户原始反馈，按时间）

- 点 sheet 右上角「关闭」后要等**好几秒** sheet 才消失；用户前后反馈过三轮，换了修复方式仍然复现。
- 更早的表述是「各种按钮都慢」。
- 用户明确要求：**不要抢他的前台**（他平时前台是 ghostty/浏览器）。所以禁止在本机激活 app 做真实点击测试。

---

## 3. 已经排除的假设（有实证，别重复做）

| # | 假设 | 结论与证据 |
|---|---|---|
| 1 | `Environment(\.dismiss)` 在 Catalyst toolbar 按钮里失效 | **真缺陷，已修**。日志证明 action 执行了，但 sheet 60s 不解散。改为调用点闭包 `onClose { showsHosts = false }`（`GatewaySwitcherView.swift:45`），并保留 `dismiss()` 兜底 |
| 2 | 动画背景（30fps TimelineView + Metal 流体场）占满主线程 | **真问题，已修**。空闲主线程 22% → 加 `disableAnimatedBackground` 开关后 0.0% 采样。**但与点击延迟无关**：关掉后用户仍报慢 |
| 3 | 窗口级 `UITapGestureRecognizer`（点外部关闭）拖慢所有点击 | **不是根因**。已默认禁用（`MacSheetClose.swift:41` 的 catcher 由 `enableOutsideTapCatcher` 门控），用户仍报慢 |
| 4 | sheet 状态切换/动画本身慢 | **不是**。程序化（非点击）开→关：open 98ms、close 863ms（含动画），见 `DSH_SHEET_SELFTEST` 日志 |
| 5 | 本机可跑 XCUITest | **不行**。testmanagerd 初始化失败：`com.apple.LocalAuthentication -5 "Empty user password"`（该账户没有密码）。不要要求用户设密码 |
| 6 | 本机 CGEvent 合成点击 | 需要抢前台（违反约束），且结果不可信：点「切换主机」25s 不出 sheet，同时点「设置」也无任何效果 → 无法区分"事件被丢弃"与"真慢" |

---

## 4. 复现现状（最重要）

**GitHub Actions 上 XCUITest 可以正常跑**（runner 有正常测试账户环境），并且已经复现了症状：

- 仓库：`NewbieXvwu/dsh-mobile`，workflow：`.github/workflows/macos-catalyst.yml`，`runs-on: xcode-27`（预览镜像 = macOS 27.0.1 + Xcode 27.2，与本机同版本）
- 第一轮（run 41820449733）：`switcher.tap()` 之后 **20 秒内 sheet 没出现**，断言失败。
- 第二轮（run 41822666912，60s 超时 + 截图 + AX dump + 实时 app.log）：**仍然失败**。日志时间线（`test.log`）：

```
t= 8.94s Tap Button "当前主机：未选择，切换主机"
t= 9.25s   Synthesize event            ← 事件在这里投递
t=14.59s   Wait for app to idle        ← 之后 app 忙了 5.34 秒才 idle
t=14.60s   开始轮询「关闭」按钮 /「切换主机」StaticText / Sheet 数量
...  45 秒内每 ~0.15s 轮询一次，全部为 false
t=74.72s   截图 02-打开超时 + dump AX 层级
断言失败：SheetCloseLatencyUITests.swift:69 "点击切换主机后 sheet 未出现"
```

- **从超时时的 AX 层级看**：主窗口正常、`当前主机：未选择，切换主机` 按钮仍在原位、**没有 Sheet、没有 Alert**、也没有阻塞性弹窗；但 Application 节点带 `Disabled` 标记。
- **app.log 里只有一行 `touch trace installed`，没有任何 `touch-began` / `touch-ended` / `switcher-button-activated`。** 两种解释必须区分：
  (a) 点击事件根本没送达 app（`sendEvent` 未被调用）——与本机 CGEvent 实验一致（点「设置」也无反应）；
  (b) 事件送达了，但 `log stream` 在 CI 上丢掉了后续 fault 日志（截断/缓冲），埋点本身没生效。

  **这是当前最需要一刀切开的地方**，见第 9 节"决定性实验"。

查看方式：

```bash
gh run list --repo NewbieXvwu/dsh-mobile --limit 3
gh run view <runId> --repo NewbieXvwu/dsh-mobile --log | grep -E "METRIC|Test Case"
gh run download <runId> --repo NewbieXvwu/dsh-mobile -n catalyst-logs -D /tmp/ci-logs
gh run download <runId> --repo NewbieXvwu/dsh-mobile -n xcresult -D /tmp/ci-xcresult   # 里面有失败截图
```

工作流做的事：选最新 Xcode → JDK17 → 恢复 KMP 产物缓存 → 判断 Kotlin 是否需要重编 → （必要时）恢复 Kotlin/Native 工具链缓存 → Metal 工具链探针 → 恢复 DerivedData → `build-for-testing`（`CODE_SIGNING_ALLOWED=NO`）→ ad-hoc 签名 → `log stream` 后跑 `test-without-building -only-testing:DeepSeekHarnessMobileUITests/SheetCloseLatencyUITests` → 打印 `METRIC:` 行与 app 时间线 → 上传 artifact。

**迭代速度（实测：改动前一轮 9m30s / 构建 7m01s → 现在一轮 3–4 分钟 / 构建 50s–1m50s；只改 Swift 时最快 3m06s）**：

| 优化 | 做法 | 效果 |
|---|---|---|
| KMP 输入哈希闸门 | `scripts/kmp_input_hash.sh` 对 `shared/**`、`gradle/**`、根构建文件求哈希，与 `shared/build/.kmp-input-stamp-macosarm64-debug` 比对；相等且 framework 在 → 跳过 Gradle | 构建阶段 180s → ~1s |
| Kotlin 工具链条件恢复 | workflow 里先恢复 14MB 的 `kmp-out` 缓存并跑同一个哈希判断，`skip=true` 时不恢复 1.2G 的 `~/.konan` | 每轮省 35s |
| 源文件 mtime 回拨（已移除） | 曾把文件时间设到 2020 年，导致新源码被旧 DerivedData 缓存掩盖 | 该优化会执行旧代码，必须保留 checkout 的真实时间戳 |
| 缓存写入不再依赖成功 | `cache/restore` + `cache/save`（`if: always()`） | 诊断期测试是红的，缓存照样累积 |
| Metal 探针 | 真编一个 `.metal`；`xcrun -f metal`/`-x` 在缺组件时也会成功 | 需要时才下载，不会误判 |

缓存键：`kmp-toolchain-*`（`~/.konan` + gradle 依赖）、`kmp-out-*`（`.gradle` + `shared/build`，rolling，因为闸门 stamp 必须回存）、`dd-*`（DerivedData `Build` + `SourcePackages`，rolling）。

另外：UI 测试 open/close 超时各 15s（正常路径 100ms 量级，失败时快速返回）；`-showBuildTimingSummary` 打印每个 target 的耗时，用来盯新瓶颈；`workflow_dispatch` 可在不推 commit 的情况下重跑。**注意**：之前测试失败时 job 仍显示成功（`|| true` 把退出码吃了），现已修正——现在红灯就是真的失败。

---

## 5. 已埋好的诊断基建（直接用）

subsystem 统一为 `com.clarklevis.dshmobile`：

| category | 触发条件 | 打点 |
|---|---|---|
| `TouchTrace` | 环境变量 `DSH_TOUCH_TRACE=1` | `UIApplication.sendEvent(_:)` 被 swizzle，记录 `touch-began` / `touch-ended`（`DeepSeekHarnessMobile/Core/TouchTrace.swift`） |
| `TouchTrace` | 同上 | `switcher-button-activated`：切换主机按钮 action 执行时刻（`GatewaySwitcherView.swift:10`） |
| `SheetSelfTest` | 启动参数 `DSH_SHEET_SELFTEST`，或测试里主动打开 | `selftest open-request` / `sheet appeared` / `selftest close-request` / `sheet disappeared`（`GatewaySwitcherView.swift:37`、`:236`） |
| `MacSheetClose` | 总是 | `close button tapped (hasClose=…)`、`outside tap`、`outside-tap catcher disabled by default` |

**这套时间线的意义**：把"点一下要几秒"拆成三段，慢在哪段一目了然——
A) `touch-ended` → `switcher-button-activated`：UIKit 事件派发 + SwiftUI 手势识别
B) `switcher-button-activated` → `sheet appeared`：状态变更 → SwiftUI 呈现管线
C) `close button tapped` → `sheet disappeared`：解散 + 动画

当前 XCUITest（`DeepSeekHarnessMobileUITests/SheetCloseLatencyUITests.swift`）会输出：

```
METRIC: open=…ms
METRIC: close=…ms
METRIC: cycle2 open=…ms close=…ms
METRIC: timeout waiting for …
METRIC: hierarchy after open timeout >>> …app.debugDescription… <<<
```

失败时还会附截图：`01-启动后`、`02-打开超时`、`03-sheet已打开`、`04-关闭超时`。

---

## 6. 关键代码位置

- `DeepSeekHarnessMobile/Core/MacSheetClose.swift:11` `SheetDiagnostics`（自测开关 + 日志器）
- `DeepSeekHarnessMobile/Core/MacSheetClose.swift:24` `MacSheetCloseModifier`：Catalyst 专用，注入右上角「关闭」按钮（`.topBarTrailing` + `.cancelAction`）与外部点击 catcher
- `DeepSeekHarnessMobile/Core/TouchTrace.swift` 事件探针（新增，默认不安装）
- `DeepSeekHarnessMobile/Views/GatewaySwitcherView.swift:5` `@State showsHosts`；`:27` 自测 Task；`:45` 唯一的 `.sheet(isPresented:)`；`:55` `GatewaySwitcherSheet` 本体；`:236` appeared/disappeared 打点
- `GatewaySwitcherSheet` 用 `.presentationDetents([.medium, .large])` + `.presentationDragIndicator(.visible)`，内部是 `NavigationStack { List { … } }`
- `DeepSeekHarnessMobile/Components/HarnessAnimatedBackground.swift:36` 动画背景开关
- 其它 sheet 也走同一个 `macSheetClose` 修饰器；`GatewaySwitcherSheet` 是唯一没有显式关闭入口（用户最常触发）的那个

---

## 7. 硬约束

1. **不要抢用户前台**：禁止在本机激活 app、禁止 CGEvent/System Events 合成点击。本机只允许 `open -g`（后台）+ 无交互采样。
2. **不要 push 到 origin**（上游）；只推 `fork`（`NewbieXvwu/dsh-mobile`）。
3. 改动要**能被上游接受**：Catalyst 差异用 `#if targetEnvironment(macCatalyst)` 或 `#if canImport(...)` 守卫；诊断代码默认关闭、可以整体删除；不要引入第三方依赖。
4. 不要要求用户设置登录密码、不要改系统 TCC/安全设置。
5. 用户会自己决定是否向上游提 PR，不要代他沟通。

---

## 8. 优先假设（按我的判断排序）

1. **主线程在 tap 之后被阻塞**（而不是"动画慢"）。依据：60s 都等不到 sheet 出现，更像整条主线程卡住。最可能的阻塞源：tap 触发的主机切换/刷新路径上，KMP（Realm/网络）同步工作在 main actor 上跑。验证：CI 里测试期间周期性抓主线程栈。
2. **Catalyst 的 sheet 呈现路径本身有坑**：`.presentationDetents` / `.presentationDragIndicator` / 嵌套 `NavigationStack` 三者作用在 Catalyst 上触发 UIKit 的 `UISheetPresentationController` 反复 layout。验证：在 CI 里做变量隔离（逐个去掉再测）。
3. **WFH：hit-test 被别的窗口层挡住**（隐形遮罩/隐私层），点击落在错的位置。验证：看失败截图 + `app.debugDescription` 里元素 frame 与实际屏幕是否一致。
4. sheet 内容初次构建极慢（`displayedProfiles`、`MultiGatewayStore` 相关计算在 body 里跑）。

---

## 9. 建议的第一步

**决定性实验：把"事件有没有送达"这件事变得不依赖日志。** 现在两条证据互相矛盾（XCUITest 的 tap 之后 app 忙了 5.3s，说明有事发生；但埋点一行都没出）。做法：在 `GatewaySwitcherBar` 的按钮 action 里同时把时间戳写进一个**可见的调试标签**（例如 `.accessibilityIdentifier("dsh-tap-probe")` 的 `Text`，内容 `tap@<epoch-ms>`），测试在 tap 之后立刻读这个标签：

- 标签出现了 → 事件送达，问题在"action 执行之后 sheet 为什么不呈现"（假设 1、2、4）
- 标签一直空 → 事件没送到 SwiftUI，问题在更底层：窗口 hit-test / 事件派发 / 前台窗口状态（假设 3）

同一实验还能顺带验证：`waitForIdle` 那 5.3 秒是在做渲染、还是在做 KMP/Realm 的同步工作。

然后按结果分流：

1. 若事件没送达：`sample`/`spindump` 抓 app 进程栈；检查 Catalyst 下窗口是否为 key window（XCUITest 下 app 可能被 runner 抢走 key）、是否有隐形 overlay、`isUserInteractionEnabled` 链。同时把按钮改成 `Button(action:)` 与 `.onTapGesture` 两种形态对比，排除 SwiftUI gesture 层的差异。
2. 若事件送达但 sheet 不呈现：做变量隔离——把 `GatewaySwitcherSheet` 临时换成 20 行最小 sheet（一个 Text + 关闭按钮），逐个去掉 `.presentationDetents` / `.presentationDragIndicator` / 嵌套 `NavigationStack`；若最小 sheet 也慢/不出，问题在 Catalyst 的 `UISheetPresentationController` 呈现路径；若最小 sheet 正常，问题在可切换主机列表的构建（`displayedProfiles` / `MultiGatewayStore` 在 `body` 里做重计算）。
3. 顺带：在 CI 里对 app 进程周期性 `sample <pid> 2 -file`（runner 可 `sudo`），把主线程栈也作为 artifact 上传，这基本能直接看到卡在哪个库。

## 10. 验收标准

- CI 上 `METRIC: open` 与 `METRIC: close` 都 < 100ms，且第二轮无退化；
- 该 UI 测试作为回归门禁常绿；
- 改动对 iOS 行为零影响（iOS 构建与既有测试仍通过）；
- 结论（根因 + 修法）写进 `Docs/macOS-catalyst.md`，注明哪些是 Catalyst 特有、哪些可以回馈上游。
