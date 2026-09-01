import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showLeftSidebar = true
    @State private var showRightSidebar = true
    @State private var isFullScreenMode = false
    @State private var savedLeftSidebarState = true
    @State private var savedRightSidebarState = true

    var body: some View {
        HStack(spacing: 0) {
            // 左侧：设备控制
            if showLeftSidebar {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("OHScreen")
                            .font(.title2.bold())
                        Spacer()
                        Button(action: {
                            withAnimation { showLeftSidebar = false }
                        }) {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("隐藏侧边栏")
                    }

                    Text(model.status)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if !model.hdcPath.isEmpty {
                        Text("hdc: \(model.hdcPath)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }

                    Picker("设备", selection: $model.selectedDevice) {
                        if model.devices.isEmpty {
                            Text("无设备").tag("")
                        }
                        ForEach(model.devices, id: \.self) { id in
                            Text(id).tag(id)
                        }
                    }

                    HStack {
                        Button("刷新设备") { model.refreshDevices() }
                            .disabled(model.busy)
                        Button("诊断截图") { model.snapshot() }
                            .disabled(model.busy || model.selectedDevice.isEmpty)
                    }

                    HStack {
                        if model.connected {
                            Button("断开") { model.disconnect() }
                        } else {
                            Button("连接") { model.connect() }
                                .disabled(model.busy || model.selectedDevice.isEmpty)
                                .keyboardShortcut(.defaultAction)
                        }
                    }

                    Divider()
                    Text("HAP（可选）")
                        .font(.headline)
                    Text(model.hapPath.isEmpty ? "未选择。可先用 DevEco 安装。" : model.hapPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Button("选择 HAP") { model.pickHap() }

                    Spacer()
                    Text("第一期只看画面。连接后请在手机上允许录屏。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(width: 260)
                .background(Color(nsColor: .controlBackgroundColor))
            }

            // 中间：投屏画面
            ZStack {
                VideoCanvas(layer: model.renderer.displayLayer)
                    .background(Color.black)
                    .aspectRatio(model.videoSize, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)

                // 控制按钮
                VStack {
                    HStack {
                        // 左侧：显示左侧栏按钮（当左侧栏隐藏时）
                        if !showLeftSidebar {
                            Button(action: {
                                withAnimation { showLeftSidebar = true }
                            }) {
                                Image(systemName: "sidebar.left")
                                    .font(.system(size: 18))
                                    .foregroundColor(.white)
                                    .padding(10)
                                    .background(Color.black.opacity(0.7))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .help("显示左侧栏")
                            .padding(.leading, 12)
                        }

                        Spacer()

                        // 右侧：全屏按钮
                        Button(action: {
                            if isFullScreenMode {
                                // 退出全屏模式：恢复侧边栏状态
                                withAnimation {
                                    showLeftSidebar = savedLeftSidebarState
                                    showRightSidebar = savedRightSidebarState
                                    isFullScreenMode = false
                                }
                            } else {
                                // 进入全屏模式：保存当前状态并隐藏侧边栏
                                savedLeftSidebarState = showLeftSidebar
                                savedRightSidebarState = showRightSidebar
                                withAnimation {
                                    showLeftSidebar = false
                                    showRightSidebar = false
                                    isFullScreenMode = true
                                }
                            }
                        }) {
                            Image(systemName: isFullScreenMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.black.opacity(0.7))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .help(isFullScreenMode ? "退出全屏" : "全屏")
                        .padding(.trailing, 12)
                    }
                    .padding(.top, 12)

                    Spacer()
                }

                // 右侧栏按钮（当右侧栏隐藏且非全屏模式时，显示在左上角）
                if !showRightSidebar && !isFullScreenMode {
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: {
                                withAnimation { showRightSidebar = true }
                            }) {
                                Image(systemName: "sidebar.right")
                                    .font(.system(size: 18))
                                    .foregroundColor(.white)
                                    .padding(10)
                                    .background(Color.black.opacity(0.7))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .help("显示右侧栏")
                            .padding(.trailing, 12)
                            .padding(.top, 60)
                        }
                        Spacer()
                    }
                }
            }

            // 右侧：日志
            if showRightSidebar {
                VStack(spacing: 0) {
                    HStack {
                        Text("日志")
                            .font(.headline)
                        Spacer()
                        Button(action: {
                            withAnimation { showRightSidebar = false }
                        }) {
                            Image(systemName: "sidebar.right")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("隐藏日志")
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
                .frame(width: 300)
            }
        }
        .onAppear { model.refreshDevices() }
    }
}
