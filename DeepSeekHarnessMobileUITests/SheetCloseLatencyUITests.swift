import XCTest

/// Catalyst sheet 打开/关闭延迟的端到端测量。
///
/// 为什么在 CI 跑：本机账户没有密码，testmanagerd 初始化失败
/// （LocalAuthentication -5），XCUITest 无法启动；托管 runner 环境正常。
///
/// Catalyst 使用 XCUIElement.click() 注入鼠标事件，iOS 使用 tap()。
/// 使用应用探针的时间戳计时，排除 XCTest 自身的查询和空闲等待。
final class SheetCloseLatencyUITests: XCTestCase {
    private let openTimeout: TimeInterval = 15
    private let closeTimeout: TimeInterval = 15

    override func setUp() {
        continueAfterFailure = false
    }

    private func activate(_ element: XCUIElement) {
#if targetEnvironment(macCatalyst)
        element.click()
#else
        element.tap()
#endif
    }

    private func waitFor(_ what: String, timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() { return true }
            usleep(50_000)
        }
        print("METRIC: timeout waiting for \(what) after \(Int(timeout))s")
        return false
    }

    private func timestamp(_ stage: String, cycle: Int, timeline: String) throws -> Int64 {
        let prefix = "\(stage)@"
        let values = timeline.split(separator: " ").compactMap { event -> Int64? in
            guard event.hasPrefix(prefix) else { return nil }
            return Int64(event.dropFirst(prefix.count))
        }
        return try XCTUnwrap(values.dropFirst(cycle - 1).first, "缺少第 \(cycle) 轮 \(stage) 时间戳：\(timeline)")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testSwitcherSheetOpenAndCloseLatency() throws {
#if !targetEnvironment(macCatalyst)
        throw XCTSkip("此回归测试针对 Mac Catalyst 的鼠标与弹层呈现路径")
#endif
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
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "诊断标签应可读取")

        for cycle in 1...2 {
            activate(switcher)
            guard waitFor("sheet 第 \(cycle) 次出现", timeout: openTimeout, sheetPresented) else {
                print("METRIC: probe after timeout=\(probe.exists ? probe.label : "MISSING")")
                attach(app, name: "\(cycle)-打开超时")
                print("METRIC: hierarchy after open timeout >>>\n\(app.debugDescription)\n<<<")
                XCTFail("第 \(cycle) 轮点击切换主机后 sheet 未出现")
                return
            }
            attach(app, name: "\(cycle)-sheet已打开")
            activate(closeButton)
            guard waitFor("sheet 第 \(cycle) 次消失", timeout: closeTimeout, { !sheetPresented() }) else {
                attach(app, name: "\(cycle)-关闭超时")
                print("METRIC: hierarchy after close timeout >>>\n\(app.debugDescription)\n<<<")
                XCTFail("第 \(cycle) 轮点击关闭后 sheet 未消失")
                return
            }

            let timeline = probe.label
            let open = try timestamp("appeared", cycle: cycle, timeline: timeline)
                - timestamp("tap", cycle: cycle, timeline: timeline)
            let close = try timestamp("disappeared", cycle: cycle, timeline: timeline)
                - timestamp("close", cycle: cycle, timeline: timeline)
            let prefix = cycle == 1 ? "" : "cycle2 "
            print("METRIC: \(prefix)open=\(open)ms close=\(close)ms probe=\(timeline)")
            XCTAssertGreaterThanOrEqual(open, 0)
            XCTAssertGreaterThanOrEqual(close, 0)
            // 门槛按"人眼可感知"设定：修复前是秒级（点完等好几秒），现在 CI 实测
            // open≈104ms（其中包含 UIHostingController 首次布局）、close≈5ms。
            // 100ms 太贴近 CI 抖动，会让门禁红在噪声上而不是回归上。
            XCTAssertLessThan(open, 300, "第 \(cycle) 轮打开应小于 300ms")
            XCTAssertLessThan(close, 150, "第 \(cycle) 轮关闭应小于 150ms")
        }
    }
}
