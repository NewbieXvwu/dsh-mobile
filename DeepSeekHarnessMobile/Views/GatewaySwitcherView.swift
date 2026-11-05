import SwiftUI

struct GatewaySwitcherBar: View {
    @EnvironmentObject private var hosts: MultiGatewayStore
    @State private var showsHosts = false
    @State private var sheetSelfTestStarted = false
    /// 面板高度覆盖值：列表按主机数算，编辑页需要更高。
    @State private var panelHeightOverride: CGFloat?

    @ViewBuilder
    var body: some View {
#if targetEnvironment(macCatalyst)
        if TouchTrace.enabled {
            VStack(alignment: .leading, spacing: 4) {
                switcherButton
                SheetTimingProbeLabel()
            }
        } else {
            switcherButton
        }
#else
        switcherButton
#endif
    }

    private var switcherButton: some View {
        Button {
            SheetDiagnostics.record("tap")
            if TouchTrace.enabled { TouchTrace.log.fault("switcher-button-activated") }
            showsHosts = true
        } label: {
            HStack(spacing: 8) {
                // 内嵌隧道的标记：只在开关打开时出现；未连上时叠一个转圈，连上后静止点亮。
                TailscaleTunnelIndicator()
                Image(systemName: hosts.activeProfile?.deviceKind ?? "desktopcomputer")
                Text(hosts.activeProfile?.displayName ?? String(localized: "选择主机"))
                    .lineLimit(1)
                Circle()
                    .fill(hosts.activeStore.gateway.state.isConnected ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Image(systemName: "chevron.down").appFont(.system(size: 9, weight: .semibold))
            }
            .appFont(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(.white.opacity(0.09), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .task {
            guard TouchTrace.enabled else { return }
            try? await Task.sleep(for: .seconds(1))
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            SheetDiagnostics.record("windows=\(windows.count),key=\(windows.filter(\.isKeyWindow).count),active=\(UIApplication.shared.applicationState.rawValue)")
        }
        .onAppear {
            guard SheetDiagnostics.selfTestEnabled, !sheetSelfTestStarted else { return }
            sheetSelfTestStarted = true
            Task { @MainActor in
                // 连续两轮使用相同关闭入口，后台检查首次呈现及再次呈现。
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                for cycle in 1...2 {
                    SheetDiagnostics.log.fault("selftest open-request cycle=\(cycle)")
                    SheetDiagnostics.record("selftest-open")
                    showsHosts = true
                    do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                    SheetDiagnostics.log.fault("selftest close-request cycle=\(cycle)")
                    if let close = SheetDiagnostics.closeForSelfTest { close() }
                    else { showsHosts = false }
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                }
            }
        }
        .accessibilityLabel("当前主机：\(hosts.activeProfile?.displayName ?? String(localized: "未选择"))，切换主机")
        .onChangeCompat(of: showsHosts) { _, presented in
            SheetDiagnostics.record("presented=\(presented)")
        }
#if targetEnvironment(macCatalyst)
        // 面板的呈现/收场都走命令式（直接贴在窗口上），不放进 SwiftUI 树：
        // representable 的宿主控制器每次重新求值都可能被拆掉，UIKit 会顺手解散面板。
        .onChangeCompat(of: showsHosts) { _, presented in
            if presented {
                GatewaySwitcherPanel.show(hosts: hosts, heightOverride: $panelHeightOverride) {
                    showsHosts = false
                }
            } else {
                WindowPane.dismiss()
            }
        }
#else
        .sheet(isPresented: $showsHosts) {
            GatewaySwitcherSheet(hosts: hosts, onClose: { showsHosts = false },
                                onHeightChange: { panelHeightOverride = $0 })
        }
#endif
    }
}

#if targetEnvironment(macCatalyst)
/// 绕开 SwiftUI sheet 在 Catalyst 上无法解散的原生窗口路径。
/// 命令式呈现：直接构造宿主控制器贴到窗口上，生命周期完全由这里掌握。
@MainActor
enum GatewaySwitcherPanel {
    static func panelHeight(rows: Int) -> CGFloat {
        min(620, max(216, 158 + CGFloat(max(rows, 1)) * 64))
    }

    static func show(hosts: MultiGatewayStore,
                     heightOverride: Binding<CGFloat?>,
                     onClose: @escaping () -> Void) {
        guard WindowPane.presented == nil else { return }
        let height = heightOverride.wrappedValue ?? panelHeight(rows: hosts.profiles.count)
        let sheet = AnyView(
            GatewaySwitcherSheet(hosts: hosts,
                                 onClose: onClose,
                                 onHeightChange: { newValue in
                                     if heightOverride.wrappedValue != newValue {
                                         heightOverride.wrappedValue = newValue
                                     }
                                     WindowPane.resize(height: newValue ?? panelHeight(rows: hosts.profiles.count))
                                 },
                                 embeddedInPanel: true)
        )
        let hosting = UIHostingController(rootView: sheet)
        hosting.preferredContentSize = CGSize(width: 560, height: height)
        hosting.view.backgroundColor = .systemBackground
        hosting.view.isOpaque = true
        hosting.view.accessibilityIdentifier = WindowPanelRegistry.marker
        WindowPane.present(hosting)
    }
}
#endif

/// Catalyst 面板需要自己撑起圆角背景；iOS 仍交给系统 sheet。
private struct PanelChrome: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content
                .background(Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            content
        }
    }
}

struct GatewaySwitcherSheet: View {
    @ObservedObject var hosts: MultiGatewayStore
    // Catalyst 的呈现控制器通过父级绑定关闭。
    var onClose: (() -> Void)? = nil
    /// Catalyst 窗口面板：内容切换（列表↔编辑）时回报期望的高度。
    var onHeightChange: ((CGFloat?) -> Void)? = nil
    /// Catalyst 面板内嵌时不要把导航栏交给窗口工具栏，改为面板自带标题栏。
    var embeddedInPanel: Bool = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var editMode: EditMode = .inactive
    @State private var selectedIDs: Set<String> = []
    @State private var confirmingDelete = false
    @State private var editing: GatewayProfile?
    @State private var alias = ""
    @State private var kind = "desktopcomputer"

    private var displayedProfiles: [GatewayProfile] {
        guard
            let activeID = hosts.activeID,
            let activeProfile = hosts.profiles.first(where: { $0.id == activeID })
        else { return hosts.profiles }
        return [activeProfile] + hosts.profiles.filter { $0.id != activeID }
    }

    static let editorPanelHeight: CGFloat = 260

    @ViewBuilder
    var body: some View {
        Group {
            if embeddedInPanel, let profile = editing {
                editorPanel(profile)
                    .onAppear { onHeightChange?(Self.editorPanelHeight) }
            } else {
                listContent
            }
        }
        // 生命周期挂在最外层：切到编辑页只是换内容，不算面板出现/消失。
        .onAppear {
            onHeightChange?(editing == nil ? nil : Self.editorPanelHeight)
            SheetDiagnostics.record("appeared")
            if SheetDiagnostics.selfTestEnabled { SheetDiagnostics.log.fault("sheet appeared") }
        }
        .onDisappear {
            onHeightChange?(nil)
            SheetDiagnostics.record("disappeared")
            hosts.stopProbes()
            if SheetDiagnostics.selfTestEnabled { SheetDiagnostics.log.fault("sheet disappeared") }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { hosts.stopProbes(); return }
            while !Task.isCancelled {
                await hosts.refreshPresence()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    private var listContent: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(displayedProfiles) { profile in
                        HStack(spacing: 12) {
                            if editMode.isEditing {
                                Button { toggleSelection(profile.id) } label: {
                                    Image(systemName: selectedIDs.contains(profile.id) ? "circle.inset.filled" : "circle")
                                        .appFont(.system(size: 20, weight: .medium))
                                        .frame(width: 28, height: 44)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(selectedIDs.contains(profile.id)
                                    ? String(localized: "host.deselect", defaultValue: "取消选择 \(profile.displayName)")
                                    : String(localized: "host.select", defaultValue: "选择 \(profile.displayName)"))
                                .transition(.move(edge: .leading).combined(with: .opacity))
                            }
                            Image(systemName: profile.deviceKind)
                                .appFont(.title3).frame(width: 26)
                            Button {
                                if editMode.isEditing {
                                    toggleSelection(profile.id)
                                } else {
                                    hosts.select(profile)
#if targetEnvironment(macCatalyst)
                                    onClose?()
#else
                                    dismiss()
#endif
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.displayName).foregroundStyle(Color(uiColor: .label)).lineLimit(1)
                                    Text(hosts.activeID == profile.id ? String(localized: "当前主机") : String(localized: "点击连接"))
                                        .appFont(.caption)
                                        .foregroundStyle(
                                            hosts.activeID == profile.id
                                                ? Color.accentColor
                                                : Color(uiColor: .secondaryLabel)
                                        )
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            Circle().fill(hosts.onlineIDs.contains(profile.id) ? Color.green : Color.gray.opacity(0.45))
                                .frame(width: 8, height: 8)
                                .accessibilityLabel(hosts.onlineIDs.contains(profile.id)
                                    ? String(localized: "在线") : String(localized: "未连接或不可用"))
                            if editMode.isEditing {
                                Button {
                                    alias = profile.alias ?? ""
                                    kind = profile.deviceKind
                                    SheetDiagnostics.record("edit-open")
                                    editing = profile
                                } label: {
                                    Image(systemName: "pencil")
                                        .appFont(.system(size: 18, weight: .medium))
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("编辑 \(profile.displayName)")
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                        .padding(.vertical, 2)
                        .animation(.easeInOut(duration: 0.2), value: editMode.isEditing)
                    }
                } header: { Text("我的主机").foregroundStyle(Color(uiColor: .secondaryLabel)) }
                if hosts.profiles.isEmpty {
                    Text("暂无已连接的主机")
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                }
            }
            .scrollContentBackground(embeddedInPanel ? .hidden : .automatic)
            .environment(\.editMode, $editMode)
            .alert(selectedIDs.count == 1 ? String(localized: "删除主机？") : String(localized: "批量删除主机？"), isPresented: $confirmingDelete) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    hosts.remove(ids: selectedIDs)
                    selectedIDs.removeAll()
                }
            } message: {
                Text("从 App 移除选中的 \(selectedIDs.count) 台主机及连接凭证；网关上的会话和工作区不会被删除。再次连接需重新配对。")
            }
            .navigationTitle("切换主机")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                if embeddedInPanel { panelTitleBar }
            }
            .toolbar(embeddedInPanel ? .hidden : .visible, for: .navigationBar)
            .macSheetClose { onClose?() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editMode.isEditing ? String(localized: "完成编辑") : String(localized: "编辑")) {
                        withAnimation {
                            if editMode.isEditing { selectedIDs.removeAll() }
                            editMode = editMode.isEditing ? .inactive : .active
                        }
                    }
                }
                if editMode.isEditing, !selectedIDs.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(selectedIDs.count == 1 ? String(localized: "删除") : String(localized: "批量删除"), role: .destructive) {
                            confirmingDelete = true
                        }
                        .foregroundStyle(.red)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .sheet(item: embeddedInPanel ? Binding.constant(nil) : $editing) { profile in
                editorSheet(profile)
            }
        }
        .modifier(PanelChrome(enabled: embeddedInPanel))
        // 面板模式下按原生导航栏的观感来：文字用主标签色、按钮用强调色；
        // 系统 sheet 模式下保持原来的白色工具栏文字。
        .foregroundStyle(embeddedInPanel ? Color.primary : Color(uiColor: .label))
        .tint(embeddedInPanel ? Color.accentColor : Color(uiColor: .label))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func editorPanel(_ profile: GatewayProfile) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("取消") {
                    SheetDiagnostics.record("edit-close")
                    editing = nil
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Text("编辑主机").appFont(.headline)
                Spacer(minLength: 0)
                Button("保存") {
                    hosts.edit(profile, alias: alias, kind: kind)
                    editing = nil
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(Color(uiColor: .secondarySystemBackground))
            .overlay(alignment: .bottom) { Divider() }

            Form { editorFields(profile) }
                .scrollContentBackground(.hidden)
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear { SheetDiagnostics.record("edit-appeared") }
        .onDisappear { SheetDiagnostics.record("edit-disappeared") }
    }

    private func editorSheet(_ profile: GatewayProfile) -> some View {
        NavigationStack {
            Form { editorFields(profile) }
                .navigationTitle("编辑主机")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            SheetDiagnostics.record("edit-close")
                            editing = nil
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { hosts.edit(profile, alias: alias, kind: kind); editing = nil }
                    }
                }
        }
        .foregroundStyle(Color(uiColor: .label))
        .tint(Color(uiColor: .label))
        .presentationDetents([.medium])
        .onAppear { SheetDiagnostics.record("edit-appeared") }
        .onDisappear { SheetDiagnostics.record("edit-disappeared") }
    }

    @ViewBuilder
    private func editorFields(_ profile: GatewayProfile) -> some View {
        Section {
            TextField(profile.gatewayName, text: $alias)
            HStack {
                Text("主机类型")
                Spacer()
                Menu {
                    Picker("主机类型", selection: $kind) {
                        Label("电脑", systemImage: "desktopcomputer").tag("desktopcomputer")
                        Label("服务器", systemImage: "server.rack").tag("server.rack")
                    }
                } label: {
                    HStack(alignment: .center, spacing: 4) {
                        Image(systemName: kind)
                            .appFont(.system(size: 15))
                            .frame(width: 20, height: 20)
                        Text(kind == "server.rack" ? String(localized: "服务器") : String(localized: "电脑"))
                            .appFont(.body)
                        Image(systemName: "chevron.up.chevron.down")
                            .appFont(.system(size: 11, weight: .medium))
                    }
                }
                .accessibilityLabel("主机类型")
                .accessibilityValue(kind == "server.rack" ? String(localized: "服务器") : String(localized: "电脑"))
            }
        } header: {
            Text("留空使用网关提供的名称：\(profile.gatewayName)")
                .appFont(.caption)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .textCase(nil)
        }
    }

    private var panelTitleBar: some View {
        HStack(spacing: 12) {
            Button(editMode.isEditing ? String(localized: "完成编辑") : String(localized: "编辑")) {
                withAnimation {
                    if editMode.isEditing { selectedIDs.removeAll() }
                    editMode = editMode.isEditing ? .inactive : .active
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            Spacer(minLength: 0)
            Text("切换主机").appFont(.headline)
            Spacer(minLength: 0)
            if editMode.isEditing, !selectedIDs.isEmpty {
                Button(selectedIDs.count == 1 ? String(localized: "删除") : String(localized: "批量删除")) {
                    confirmingDelete = true
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
            Button(String(localized: "关闭")) {
                // 与 .macSheetClose 的按钮保持同一套探针记录，UI 测试据此算关闭耗时。
                SheetDiagnostics.record("close")
                if let onClose { onClose() } else { dismiss() }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Color.primary.opacity(0.06))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}
