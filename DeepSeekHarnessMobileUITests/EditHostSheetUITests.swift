import XCTest

/// 覆盖"编辑主机"内层弹层：它从窗口内 UIKit 面板里再弹一个 SwiftUI `.sheet`，
/// 正是此前关闭失效的那条呈现路径的嵌套版本。用启动参数注入一台内存假主机构造场景。
final class EditHostSheetUITests: XCTestCase {
    private let timeout: TimeInterval = 15

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

    private func timestamp(_ stage: String, timeline: String) throws -> Int64 {
        let prefix = "\(stage)@"
        let value = timeline.split(separator: " ")
            .first { $0.hasPrefix(prefix) }
            .map { Int64($0.dropFirst(prefix.count)) }
        return try XCTUnwrap(value ?? nil, "缺少 \(stage) 时间戳：\(timeline)")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testEditHostSheetOpensAndClosesInsidePanel() throws {
#if !targetEnvironment(macCatalyst)
        throw XCTSkip("此回归测试针对 Mac Catalyst 的窗口内面板")
#endif
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "DSH_SHEET_MOCK_HOST"]
        app.launchEnvironment["DSH_TOUCH_TRACE"] = "1"
        app.launch()
        defer { app.terminate() }

        let switcher = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "切换主机"))
            .firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 30), "主界面应有切换主机入口")
        _ = app.staticTexts["SelfTest Gateway"].waitForExistence(timeout: 10)

        let closePanel = app.buttons["关闭"].firstMatch
        activate(switcher)
        guard waitFor("主机面板出现", timeout: timeout, { closePanel.exists }) else {
            attach(app, name: "01-面板未出现")
            print("METRIC: hierarchy >>>\n\(app.debugDescription)\n<<<")
            return XCTFail("点击切换主机后面板未出现")
        }

        XCTAssertTrue(app.staticTexts["SelfTest Gateway"].waitForExistence(timeout: 10),
                      "面板里应出现自测主机")

        let probe = app.staticTexts["dsh-tap-probe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "诊断标签应可读取")

        let editButton = app.buttons["编辑"].firstMatch
        XCTAssertTrue(editButton.waitForExistence(timeout: 10), "面板标题栏应有编辑按钮")
        activate(editButton)

        let pencil = app.buttons["编辑 SelfTest Gateway"].firstMatch
        guard waitFor("行内编辑按钮出现", timeout: timeout, { pencil.exists }) else {
            attach(app, name: "02-编辑态未展开")
            print("METRIC: hierarchy >>>\n\(app.debugDescription)\n<<<")
            return XCTFail("进入编辑态后没有出现行内编辑按钮")
        }
        activate(pencil)

        let cancel = app.buttons["取消"].firstMatch
        let editTitle = app.staticTexts["编辑主机"].firstMatch
        guard waitFor("编辑主机弹层出现", timeout: timeout, { cancel.exists || editTitle.exists }) else {
            attach(app, name: "03-编辑弹层未出现")
            print("METRIC: hierarchy >>>\n\(app.debugDescription)\n<<<")
            return XCTFail("点击行内编辑后没有出现编辑主机弹层")
        }
        attach(app, name: "04-编辑主机弹层")

        activate(cancel)
        guard waitFor("编辑主机弹层消失", timeout: timeout, { !cancel.exists && !editTitle.exists }) else {
            attach(app, name: "05-编辑弹层未消失")
            print("METRIC: hierarchy >>>\n\(app.debugDescription)\n<<<")
            return XCTFail("点击取消后编辑主机弹层没有消失")
        }

        attach(app, name: "06-编辑弹层已关闭")
        let timeline = probe.label
        let open = try timestamp("edit-appeared", timeline: timeline)
            - timestamp("edit-open", timeline: timeline)
        let close = try timestamp("edit-disappeared", timeline: timeline)
            - timestamp("edit-close", timeline: timeline)
        print("METRIC: edit-open=\(open)ms edit-close=\(close)ms probe=\(timeline)")
        XCTAssertGreaterThanOrEqual(open, 0)
        XCTAssertGreaterThanOrEqual(close, 0)
        XCTAssertLessThan(open, 300, "编辑弹层打开应小于 300ms")
        XCTAssertLessThan(close, 300, "编辑弹层关闭应小于 300ms")

        // 关掉面板，确认外层仍是干净状态（不含残留遮罩）。
        activate(closePanel)
        XCTAssertTrue(waitFor("面板关闭", timeout: timeout, { !closePanel.exists }), "面板应能关闭")
    }
}
