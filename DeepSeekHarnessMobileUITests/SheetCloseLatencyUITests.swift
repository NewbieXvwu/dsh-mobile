import XCTest

/// Catalyst sheet 打开/关闭延迟的端到端测量。
///
/// 为什么在 CI 跑：本机账户没有密码，testmanagerd 初始化失败
/// （LocalAuthentication -5），XCUITest 无法启动；托管 runner 环境正常。
///
/// Catalyst 使用 XCUIElement.click() 注入鼠标事件，iOS 使用 tap()。
/// 配合 app 内的
/// TouchTrace（DSH_TOUCH_TRACE=1）可把延迟拆成
///   触摸抬起 → 按钮 action → sheet 出现 / 关闭请求 → sheet 消失
/// 三段，慢在哪一段一目了然。
///
/// 注意：CI 上测试失败就是真失败（工作流已修掉 `|| true` 吞退出码的问题），
/// 诊断期关注 METRIC 行与 artifact 里的 app.log。
final class SheetCloseLatencyUITests: XCTestCase {
    // 失败要快：CI 上一轮"没出现"能省 90 秒（原来各 60s）。正常路径是 100ms 量级，
    // 15s 已经给了 150 倍余量；真慢到 15s 以上，无论如何都要单独诊断。
    private let openTimeout: TimeInterval = 15
    private let closeTimeout: TimeInterval = 15

    override func setUp() {
        continueAfterFailure = false
    }

    private func ms(_ from: Date) -> Int { Int(Date().timeIntervalSince(from) * 1000) }

    private func activate(_ element: XCUIElement) {
#if targetEnvironment(macCatalyst)
        element.click()
#else
        element.tap()
#endif
    }

    /// 轮询直到条件成立，返回耗时毫秒；超时返回 nil。
    private func waitFor(_ what: String, timeout: TimeInterval, _ condition: () -> Bool) -> Int? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() { return ms(start) }
            usleep(50_000)
        }
        print("METRIC: timeout waiting for \(what) after \(Int(timeout))s")
        return nil
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testSwitcherSheetOpenAndCloseLatency() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["DSH_TOUCH_TRACE"] = "1"
        app.launch()
        defer { app.terminate() }

        let switcher = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "切换主机"))
            .firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 30), "主界面应有切换主机入口")
        attach(app, name: "01-启动后")

        // 关闭按钮由 macSheetClose 注入，只在 sheet 存在时出现；
        // 同时用导航标题与 sheets 容器作为旁证，避免单个查询失败就误判。
        let closeButton = app.buttons["关闭"].firstMatch
        let navTitle = app.staticTexts["切换主机"].firstMatch
        let sheetPresented: () -> Bool = {
            closeButton.exists || navTitle.exists || app.sheets.count > 0
        }
        let probe = app.staticTexts["dsh-tap-probe"].firstMatch
        print("METRIC: probe before tap=\(probe.exists ? probe.label : "MISSING")")

        // —— 打开 ——
        let clickStart = Date()
        activate(switcher)
        print("METRIC: tap call=\(ms(clickStart))ms probe=\(probe.exists ? probe.label : "MISSING")")
        let openLatency = waitFor("sheet 出现", timeout: openTimeout, sheetPresented)
        print("METRIC: open=\(openLatency.map(String.init) ?? "TIMEOUT")ms")
        if openLatency == nil {
            print("METRIC: probe after timeout=\(probe.exists ? probe.label : "MISSING")")
            attach(app, name: "02-打开超时")
            print("METRIC: hierarchy after open timeout >>>\n\(app.debugDescription)\n<<<")
            XCTFail("点击切换主机后 sheet 未出现")
            return
        }
        attach(app, name: "03-sheet已打开")

        // —— 关闭（真实点击右上角关闭按钮）——
        activate(closeButton)
        let closeLatency = waitFor("sheet 消失", timeout: closeTimeout) { !sheetPresented() }
        print("METRIC: close=\(closeLatency.map(String.init) ?? "TIMEOUT")ms")
        if closeLatency == nil {
            attach(app, name: "04-关闭超时")
            print("METRIC: hierarchy after close timeout >>>\n\(app.debugDescription)\n<<<")
            XCTFail("点击关闭后 sheet 未消失")
            return
        }

        // —— 第二轮：排除首启冷路径 ——
        activate(switcher)
        let open2 = waitFor("sheet 第二次出现", timeout: openTimeout, sheetPresented)
        guard open2 != nil else {
            print("METRIC: cycle2 open=TIMEOUT")
            return
        }
        activate(closeButton)
        let close2 = waitFor("sheet 第二次消失", timeout: closeTimeout) { !sheetPresented() }
        print("METRIC: cycle2 open=\(open2!)ms close=\(close2.map(String.init) ?? "TIMEOUT")ms")
    }
}
