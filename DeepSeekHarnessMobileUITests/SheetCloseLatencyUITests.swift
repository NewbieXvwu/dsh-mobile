import XCTest

/// Catalyst sheet 打开/关闭延迟的端到端回归测试。
/// XCUIApplication 激活 app（前台、scenePhase=.active、完整渲染管线），
/// tap() 走真实事件管线（含手势识别），可复现用户鼠标点击路径。
final class SheetCloseLatencyUITests: XCTestCase {
    private func ms(_ start: Date, _ end: Date) -> Int {
        Int(end.timeIntervalSince(start) * 1000)
    }

    func testSwitcherSheetOpenAndCloseLatency() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }

        let switcher = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "切换主机"))
            .firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 20), "欢迎页应有切换主机入口")

        // —— 基线：一次普通点击的响应（打开会话抽屉不适用欢迎页，用 sheet 打开代替）——
        var t0 = Date()
        switcher.tap()
        // 关闭按钮由 macSheetClose 注入，只在 sheet 存在时出现 → 同时充当 sheet 存在标记
        let closeButton = app.buttons["关闭"].firstMatch
        let appeared = closeButton.waitForExistence(timeout: 20)
        let tAppear = Date()
        XCTAssertTrue(appeared, "切换主机 sheet 应出现（关闭按钮存在）")
        let openLatency = ms(t0, tAppear)

        // —— 关闭：真实点击右上角关闭按钮，轮询 sheet 消失 ——
        t0 = Date()
        closeButton.tap()
        var gone = false
        var tGone = Date()
        while Date().timeIntervalSince(t0) < 30 {
            if !closeButton.exists {
                tGone = Date()
                gone = true
                break
            }
            usleep(50_000)
        }
        XCTAssertTrue(gone, "点击关闭后 sheet 应消失")
        let closeLatency = ms(t0, tGone)

        // —— 再开再关一次，排除首启冷路径 ——
        switcher.tap()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 20))
        let t2 = Date()
        closeButton.tap()
        var gone2 = false
        var tGone2 = Date()
        while Date().timeIntervalSince(t2) < 30 {
            if !closeButton.exists {
                tGone2 = Date()
                gone2 = true
                break
            }
            usleep(50_000)
        }
        XCTAssertTrue(gone2, "第二次点击关闭后 sheet 应消失")
        let closeLatency2 = ms(t2, tGone2)

        let metrics = "SHEET_LATENCY open=\(openLatency)ms close1=\(closeLatency)ms close2=\(closeLatency2)ms"
        XCTContext.runActivity(named: metrics) { _ in }
        print("METRIC: \(metrics)")
    }
}
