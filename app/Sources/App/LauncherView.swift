import SwiftUI
import UniformTypeIdentifiers

/// The first screen: whether the player's own game data is there, how to
/// import it (Files / Finder, or Wi-Fi from a Mac), and the start button.
struct LauncherView: View {
    @EnvironmentObject private var library: GameLibrary
    @EnvironmentObject private var transfer: TransferServer

    @State private var showingPicker = false
    @State private var pickAction: PickAction = .importCopy
    @AppStorage(PlayerControlPreferences.visibilityKey)
    private var showControlButtons = PlayerControlPreferences.defaultVisible

    private enum PickAction {
        case importCopy   // copy into the app's own storage
        case inPlace      // play a Mac folder where it is
    }

    var body: some View {
        ZStack {
            background
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    statusCard
                    if library.gameFolder != nil {
                        startSection
                    }
                    playerControlsCard
                    importCard
                    transferCard
                    if let error = library.errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if library.engineHasRun {
                        engineEndedCard
                    }
                    footer
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 30)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { library.refresh() }
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            switch pickAction {
            case .importCopy: library.importFolder(url)
            case .inPlace: library.chooseGameFolderInPlace(url)
            }
        }
    }

    // MARK: - chrome

    private var background: some View {
        LinearGradient(
            colors: [Color(red: 0.05, green: 0.07, blue: 0.13),
                     Color(red: 0.02, green: 0.03, blue: 0.06)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CLANNAD")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("SiglusEngine · Apple 平台移植")
                .foregroundStyle(.secondary)
            Text("版本 \(library.versionText)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - game data status

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                if let folder = library.gameFolder {
                    Label(library.isComplete ? "已找到游戏数据" : "已找到目录，但游戏数据不完整",
                          systemImage: library.isComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(library.isComplete ? Color.green : Color.orange)
                    Text(folder.path)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)

                    fileChecklist

                    if !library.gameFolderWritable {
                        Label("游戏目录当前不可写", systemImage: "lock.fill")
                            .foregroundStyle(.orange)
                        Text("引擎需要在该目录写入 key.toml 与 savedata。请用「导入游戏数据」复制到 App 自己的存储，或选择可写目录。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !library.isComplete {
                        Label("缺少：\(library.missingFiles.joined(separator: "、"))",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("游戏数据不完整，可能无法启动。请重新导入完整的游戏目录（包含 SceneZH.pck 与 GameexeZH.dat）。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if !library.missingDirectories.isEmpty {
                        Label("缺少资源目录：\(library.missingDirectories.joined(separator: "、"))",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("可以启动，但部分画面、语音或影片可能缺失。建议重新导入完整的 data 目录。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("资源目录完整，可以开始游戏", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                    if library.archiveCount > 0 {
                        Text("共 \(library.archiveCount) 个数据包（.pck / .dat）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("尚未找到游戏数据", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("本应用不包含任何游戏内容。请使用你自己购买的 Steam 版《CLANNAD》中的 data 目录（包含 SceneZH.pck、GameexeZH.dat、g00、bgm、koe 等），通过下方任一方式导入。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("游戏数据")
        }
    }

    private var fileChecklist: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(library.fileChecklist) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.present ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(item.present ? Color.green : Color.secondary)
                    Text(item.name)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(item.present ? Color.primary : Color.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], alignment: .leading, spacing: 3) {
                ForEach(library.directoryChecklist) { item in
                    HStack(spacing: 4) {
                        Image(systemName: item.present ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(item.present ? Color.green : Color.secondary)
                        Text(item.name)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(item.present ? Color.primary : Color.secondary)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: - start

    private var startSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                library.start()
            } label: {
                Text("开始游戏")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!library.isComplete || !library.gameFolderWritable || library.importing || library.engineHasRun)
            if library.engineHasRun {
                Text("本次运行中游戏已结束，请退出并重新打开应用后再开始。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var playerControlsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                #if os(visionOS)
                Toggle("显示菜单按钮", isOn: $showControlButtons)
                    .accessibilityIdentifier("launcher.showControlButtons")
                Text("开启后在游戏右上角显示“菜单”，可进入设置、存档和读档。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                #else
                Toggle("显示游戏操作按钮", isOn: $showControlButtons)
                    .accessibilityIdentifier("launcher.showControlButtons")
                Text("开启后在游戏右上角显示“菜单”和“快进”。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                #endif
                #if os(iOS) && !targetEnvironment(macCatalyst)
                Text("默认使用双指轻点打开菜单、长按屏幕快进；双指向上滑可回看对白。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                #endif
            }
        } label: {
            Text("游戏操作")
        }
    }

    // MARK: - importing

    private var importCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                #if targetEnvironment(macCatalyst)
                Text("「导入游戏数据」把游戏目录复制到 App 自己的存储中（推荐）。也可以直接使用电脑上已有的游戏目录，不复制文件。")
                #elseif os(visionOS)
                Text("方式一：用隔空投送或「文件」App 把整个游戏 data 目录拷贝到本设备，再点「导入游戏数据」。")
                Text("方式二：在同一个 Wi-Fi 下从 Mac 通过局域网发送（见下方「局域网接收」）。")
                #else
                Text("方式一：用数据线连接 Mac，在访达 › 设备 › 文件 中把游戏 data 目录拖进本应用，再点「导入游戏数据」。")
                Text("方式二：先把游戏目录存到「文件」App，再点「导入游戏数据」。")
                Text("方式三：在同一个 Wi-Fi 下从 Mac 通过局域网发送（见下方「局域网接收」）。")
                #endif
                HStack(spacing: 12) {
                    Button("导入游戏数据") {
                        pickAction = .importCopy
                        showingPicker = true
                    }
                    .disabled(library.importing)
                    #if targetEnvironment(macCatalyst)
                    Button("使用电脑上的游戏目录…") {
                        pickAction = .inPlace
                        showingPicker = true
                    }
                    .disabled(library.importing)
                    #endif
                    Button("重新检查") { library.refresh() }
                        .disabled(library.importing)
                }
                if library.importing {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView()
                        Text(library.importStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(library.gameFolder == nil ? "导入游戏数据" : "更换游戏数据")
        }
    }

    // MARK: - Wi-Fi transfer

    private var transferCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("局域网接收游戏文件（同一 Wi-Fi）", isOn: Binding(
                    get: { transfer.running },
                    set: { $0 ? transfer.start() : transfer.stop() }))
                if transfer.running {
                    Text("配对码：\(transfer.code)")
                        .font(.title3.monospacedDigit().bold())
                    let addresses = TransferServer.addresses()
                    if addresses.isEmpty {
                        Text("未检测到局域网地址，请确认设备已连接 Wi-Fi。")
                            .foregroundStyle(.orange)
                    }
                    ForEach(addresses, id: \.self) { ip in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("在 Mac 上运行：").font(.footnote).foregroundStyle(.secondary)
                            Text("python3 tools/push_data.py --host \(ip) --code \(transfer.code) <游戏目录>")
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    if transfer.bytesReceived > 0 {
                        Text("已接收 \(ByteCountFormatter.string(fromByteCount: transfer.bytesReceived, countStyle: .file))")
                            .foregroundStyle(.secondary)
                    }
                    if !transfer.lastEvent.isEmpty {
                        Text(transfer.lastEvent)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("开启后，在 Mac 上运行 tools/push_data.py，把游戏目录发送到本设备。传输会直接写入游戏目录，支持断点续传（按文件大小跳过已收到的文件）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("局域网接收")
        }
    }

    // MARK: - end / footer

    private var engineEndedCard: some View {
        Card {
            HStack(spacing: 12) {
                Text("游戏引擎已结束，需重新打开应用才能再次游玩。")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("退出应用") { library.quitApp() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("游戏已结束")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            #if targetEnvironment(macCatalyst)
            Text("操作：鼠标与键盘同 PC 版 · 左键 = 确定 · 右键 = 菜单 · 滚轮 = 回想 · 按住 Control = 快进")
            #else
            Text("操作：轻点 = 确定 · 双指轻点 = 右键（菜单）· 单指拖动 = 移动 · 双指上下滑 = 滚轮（回想）· 长按 = 快进（Ctrl）")
            Text("也支持硬件键盘与手柄：A = 确定 · B = 菜单 · RT = 快进 · 十字键上下 = 滚轮。")
            #endif
            Text("本应用不包含任何游戏内容与美术素材，游戏数据需由玩家自行购买（Steam 版《CLANNAD》）后导入。")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

/// A titled panel (GroupBox's styling is not flexible enough across the three
/// platforms).
struct Card<Content: View, Label: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var label: Label

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            label.font(.headline)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}
