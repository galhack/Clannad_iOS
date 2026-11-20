# CLANNAD · iPhone / iPad / Mac / Apple Vision Pro 移植

把 Key 的《CLANNAD》（Steam 版，SiglusEngine + 官方简体中文资源）原生移植到
**iPhone、iPad、Mac 与 Apple Vision Pro**。使用你已购买的 Steam 游戏目录即可游玩，
中文文本直接来自官方的 `SceneZH.pck` / `GameexeZH.dat`，不需要额外的汉化补丁。

> **本仓库与 Release 不含任何游戏内容。** 游戏程序、剧本、图片、音乐、语音、影片与
> 官方中文资源都不在这里，也不会被打包进应用或安装包。请自行购买正版游戏
> （例如 Steam 版），并把你自己的游戏目录导入设备。本项目仅供已购买正版的玩家
> 个人使用，与 VisualArt's / Key 无关。

本次发布范围：**iPhone / iPad（侧载安装）、Mac（Mac Catalyst）与 Apple Vision Pro
（自行用 Xcode 安装或签名）**。

---

## 它是怎么工作的

- **引擎**：开源的 [siglus_rs](https://github.com/xmoezzz/siglus_rs)（Rust 对
  SiglusEngine 的完整重实现，MPL-2.0），本项目针对 CLANNAD 的中文资源（`SceneZH.pck`
  / `GameexeZH.dat`）、NWA 音频与 WMV/OMV 影片做了接入与构建适配。源码 vendor 在
  `engine/siglus_rs/`（上游 commit `5f358ef1`）。
- **应用外壳**：SwiftUI + UIKit + Metal，一套工程同时构建 iOS / iPadOS、visionOS 与
  Mac Catalyst 版本；启动页负责数据导入、游戏库与播放，触摸、鼠标、键盘、手柄都映射
  到原版的鼠标 / 键盘输入。
- **游戏数据**：应用只读取你导入的游戏目录，不会修改里面的游戏文件；存档写在游戏根目录的
  `savedata/`。
- **不捆绑数据**：应用本体只有十几 MB（引擎 + 外壳 + 图标，不含游戏数据），4.4 GB 的游戏数据由你导入。

验证目标设备：iPhone 16 Pro Max、iPad Pro 13"（M5）、Apple Vision Pro 与 Mac；
实际验证结果、日志与截图位置见 [`docs/VALIDATION.md`](docs/VALIDATION.md)。

当前公开版本为 **v0.1.9（10）**，覆盖 iPhone / iPad、Apple Silicon Mac 与 Vision Pro。
各平台统一使用蓝天白羽毛图标。Vision Pro 右上角仅保留菜单，iPhone / iPad 继续默认隐藏按钮。
当前版本限制 Apple 播放器的合成频率，静止无工作时跳过整帧处理，
并按系统热状态与低电量模式降低刷新。iPad 同存档实测与测量边界见
[`docs/PERFORMANCE.md`](docs/PERFORMANCE.md)。选项分支、32 pt 间距和回看修复继续保留。
此前对 Release 引擎接口被删除、剧情选项截获系统菜单输入的修复继续保留。
iPhone / iPad 默认隐藏右上角“菜单 / 快进”按钮；可在启动页“游戏操作”中开启
“显示游戏操作按钮”。双指轻点打开菜单、长按快进始终可用。Mac 的菜单与快进位于顶部
“游戏”菜单栏中，Vision Pro 默认仅显示菜单按钮。Apple 播放器的 MWND 剧情选择
使用可点击的原生面板，到选择点暂停快进，点击面板外不会默认选择第一个分支。
进入存档、读档、设置或回看界面时，原生“菜单 / 快进”浮层自动隐藏；返回剧情后按用户显示偏好恢复。
回看每次从最新记录打开，可继续向前翻阅。
iPad 已验证设置修改与新建存档的保存、读取。**全路线尚未验收，Windows 原版存档
也尚未完整兼容。** 详细覆盖边界与验证结果见
[`docs/VALIDATION.md`](docs/VALIDATION.md)。

---

## 你需要准备

1. **正版游戏**：Steam 版《CLANNAD》，目录结构大致为：

   ```
   CLANNAD/
     data/                 <- 这就是“游戏根目录”
       SceneZH.pck         <- 官方简体中文剧本包
       GameexeZH.dat       <- 官方简体中文配置
       dat/ g00/ bgm/ koe/ wav/ mov/ gan/
       savedata_zh/ SAVEDATA/   <- 首启存档种子（保留，不要删）
       LICENSE/
   ```

   游戏根目录的判定标准：**包含 `SceneZH.pck` 与 `GameexeZH.dat` 的那一层**，
   也就是 Steam 安装目录里的 `CLANNAD/data`。

2. **设备空间**：游戏数据约 **4.4 GB**，首次导入后应用内还要放存档；建议设备至少
   预留 **6 GB** 可用空间。

3. **一台 Mac**（安装 Xcode；侧载 iPhone/iPad 也可以用 Windows 上的 Sideloadly）。

4. **一个 Apple ID**：免费账户即可，签名 7 天有效，到期重新侧载（见下）。

---

## 下载与安装（iPhone / iPad）

### 1. 下载 IPA

在 [Releases](https://github.com/galhack/Clannad_iOS/releases) 下载
`Clannad-ios.ipa`（**不包含游戏数据**；IPA 本身未签名，由 Sideloadly 用你的
Apple ID 签名后安装）。

### 2. 用 Sideloadly 侧载

1. 在电脑上安装 [Sideloadly](https://sideloadly.io/)（Windows / macOS 均可）。
2. 用数据线连接 iPhone / iPad，解锁并在设备上点「信任」。
3. 打开 Sideloadly，把 `Clannad-ios.ipa` 拖进窗口，选择你的设备和 Apple ID。
4. 点 **Start**，等待出现 `Done.`。

> 免费 Apple ID 签名的应用 **7 天**后过期，到期后重新侧载即可。
> **覆盖安装，不要先卸载**——卸载会同时删除已经导入的 4.4 GB 游戏数据和所有存档。
> 免费账户在每台设备上最多同时保留 3 个侧载应用，装不下时先删掉别的。

### 3. 信任开发者证书

在设备上打开 **设置 › 通用 › VPN 与设备管理 › 开发者 App**，选择你的 Apple ID 并点
「信任」。iOS 16 及以上还需要在 **设置 › 隐私与安全性 › 开发者模式** 中开启开发者模式
（开启后设备会重启一次，重启后再回到这里确认已开启）。

### 4. 导入游戏数据

应用本身不包含游戏。第一次打开会提示「尚未找到游戏文件」，把**整个游戏根目录**
（即 `CLANNAD/data` 里的全部内容）导入应用即可：

| 方式 | 操作 |
|---|---|
| 访达文件共享（推荐，数据线） | 连接 Mac → 访达 › 选中设备 › **文件** ›「CLANNAD」→ 把 `data` 文件夹整个拖进去（放在根目录或 `Clannad` 文件夹里都可以，应用会自动查找） |
| 局域网传输（Wi-Fi） | 在应用启动页打开「局域网接收游戏文件」，记下屏幕上的 **地址** 与 **配对码**，在 Mac 上运行 `python3 tools/push_data.py --host <地址> --code <配对码> /path/to/CLANNAD/data` |
| Vision Pro | 没有访达文件共享：用下面的局域网传输，或把文件夹隔空投送到「文件」App 再移动进「CLANNAD」 |

Wi-Fi 传输的说明：

- 只需要系统自带的 **Python 3**，不用安装任何依赖；
- 目录参数既可以是游戏根目录（含 `SceneZH.pck` 的那一层），也可以是它的**上一级目录**
  （脚本会自动找到其中的 `data/`）；
- 脚本发送 `data/` 里的全部游戏文件（`SceneZH.pck`、`GameexeZH.dat`、`dat/`、`g00/`、
  `bgm/`、`koe/`、`wav/`、`mov/`、`gan/`、`savedata_zh/`、`SAVEDATA/`、`LICENSE/` 等），
  自动跳过 `.DS_Store` 和 Apple 平台用不到的原版 Windows 程序；
- 设备上已有且大小相同的文件会跳过，**中断后重新运行同一条命令即可续传**；
- 4.4 GB 在 Wi-Fi 上通常需要几分钟到十几分钟，取决于路由器速度；
- 传完后回到应用点「重新检查」。

导入完成后启动页会显示检测到的游戏目录，点「开始游戏」。

> 游戏文件本身不会被修改。应用会在游戏根目录创建 `savedata/` 保存存档，并在第一次
> 启动时用你导入的 `savedata_zh/`（没有则用 `SAVEDATA/`）里的内容作为初始存档。

### 5. 开始游戏

确认启动页已识别游戏目录，点「开始游戏」。中文文本来自官方简体中文资源，无需切换语言。

---

## 操作方式

| 输入 | 对应 |
|---|---|
| 右上角“菜单”（可选） | 打开游戏系统菜单，包含保存、读取和系统设置 |
| 右上角“快进”（可选） | 切换引擎快进状态，在选择点等待确认 |
| 轻点 | 推进文字、操作系统菜单；到剧情选择点后点击面板中的具体分支 |
| 双指轻点 | 鼠标右键（游戏菜单 / 隐藏文字框） |
| 双指上下滑动 | 鼠标滚轮（双指向上滑打开历史记录；打开后可单指拖动翻阅） |
| 长按 | 按住 Ctrl（快进），松手停止 |
| 鼠标 / 触控板（iPad、Mac） | 按下、拖动、左右键；向上滚动查看历史对白，向下滚动推进下一条对白，方向遵循系统滚动设置 |
| Mac 菜单栏“游戏” | “游戏菜单…”（⇧⌘M）进入存档、读档和设置；“快进”（⇧⌘F）切换快进并显示勾选状态 |
| 硬件键盘 | Enter、空格、Esc、方向键、Ctrl（按住快进）等 |
| 游戏手柄 | 左摇杆移动指针，A = 左键，B = 右键，RT = 快进，十字键上/下 = 滚轮 |
| Apple Vision Pro | 注视 + 捏合 = 轻点；其余同触控（蓝牙键盘/手柄同样可用） |

具体映射以应用内实际行为为准；如遇到问题请在 Issues 里说明设备与系统版本。

---

## 存档

- 存档保存在**游戏根目录的 `savedata/`** 里（例如应用容器 `Documents/.../savedata/`，
  Mac 上就是你自己游戏目录的 `savedata/`），和游戏文件放在一起，但游戏文件本身不会被改。
- 第一次启动时若还没有 `savedata/`，应用会从 `savedata_zh/`（官方中文存档种子）或
  `SAVEDATA/` 导入设置和已读记录。Windows 的编号剧情存档默认不导入，完整兼容尚未实现。
- 删除应用会同时删除应用容器里的游戏数据与存档；重新侧载请用**同一个 Bundle ID
  覆盖安装**，不要卸载。
- Mac 版的存档就在你选择的游戏目录里，和应用无关，卸载应用不会丢。

---

## Mac 版

Release 同时提供 `Clannad-mac.zip`（Mac Catalyst 构建，未公证）。解压后把
`Clannad.app` 拖到「应用程序」，第一次打开若被系统拦截，请右键 › 打开。

启动后点「选择游戏目录…」指向电脑上的游戏根目录（包含 `SceneZH.pck` 的那一层），
**不需要复制数据**；选择会被记住，下次直接进入。存档写在那个目录的 `savedata/`，
与 iPhone / iPad 上的存档互不影响。

游戏过程中，通过顶部菜单栏的“游戏 → 游戏菜单…”进入原版存档、读档和设置，
通过“游戏 → 快进”切换快进。快捷键分别为 **⇧⌘M** 和 **⇧⌘F**。

需要 macOS 14 或更高版本。Release 的 Mac 版以 **Apple 芯片（arm64）** 构建，
Apple Silicon 推荐使用；Intel Mac 未做保证（可自行从源码构建 x86_64 版本）。

也可以自行构建：

```sh
tools/apple/build_mac.sh          # 生成 build/Clannad-mac.zip
```

---

## Apple Vision Pro

Vision Pro 使用原生 visionOS 应用（同一个工程、同一套数据导入方式）。由于 visionOS
的安装必须经过签名，**推荐用 Xcode 直接安装**（免费 Apple ID 也可以）：

1. 用同一 Apple ID 登录 Xcode（Xcode › Settings › Accounts），并在
   **Xcode › Window › Devices and Simulators** 中配对 Vision Pro；
2. 在 Vision Pro 上开启**开发者模式**（设置 › 隐私与安全性 › 开发者模式）；
3. 生成工程并打开：

   ```sh
   CLANNAD_TEAM=<你的 Team ID> tools/apple/gen_project.sh
   open app/Clannad.xcodeproj
   ```

4. 在 Xcode 顶部选择你的 Vision Pro，点 **Run（▶）**，Xcode 会用你的证书签名并安装；
5. 首次启动前把游戏数据导入（Vision Pro 没有访达文件共享）：用上面的 Wi-Fi 传输，
   或把 `data` 文件夹隔空投送到「文件」App，再移动进「CLANNAD」文件夹。

也可以构建未签名的 visionOS 包：

```sh
tools/apple/build_visionos.sh     # build/Clannad-visionos.ipa（Payload/Clannad.app，未签名）
```

> **限制**：未签名的 visionOS IPA 不能直接安装到 Vision Pro（Apple 要求签名 + 包含设备
> 的描述文件）。Sideloadly 等工具是否支持 visionOS 取决于其版本，本项目不提供证书、
> 账号或签名服务；最可靠的方式仍是 Xcode Run。详细验证状态见 `docs/VALIDATION.md`。

---

## 从源码构建（开发者）

需要 macOS、**Xcode 27**（含 iOS / visionOS SDK）与 Rust nightly 工具链及 `rust-src` 组件。XcodeGen 由脚本自动
下载到 `build/tools/`，不污染系统。

```sh
git clone https://github.com/galhack/Clannad_iOS.git
cd Clannad_iOS

# 1) 准备工具链并编译引擎，产出 build/Siglus.xcframework
rustup toolchain install nightly --component rust-src
#    （iOS 设备/模拟器、Mac Catalyst、visionOS 设备/模拟器的切片；
#      Intel Mac 可加 --with-intel-mac）
tools/apple/build_engine.sh

# 2) 生成 Xcode 工程（Team ID 也可以写进 app/.team，单行，不会提交）
CLANNAD_TEAM=<你的 Team ID> tools/apple/gen_project.sh
open app/Clannad.xcodeproj

# 3) 打包未签名 IPA（交给 Sideloadly 签名安装）
tools/apple/build_ipa.sh ios          # build/Clannad-ios.ipa
tools/apple/build_visionos.sh         # build/Clannad-visionos.ipa

# 4) Mac 版
tools/apple/build_mac.sh              # build/Clannad-mac.zip
```

在 Xcode 里也可以直接选模拟器或真机运行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project app/Clannad.xcodeproj -scheme Clannad \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

调试时可以用环境变量 `CLANNAD_GAME_DIR` 让应用直接读本机的游戏目录，不必先导入
（模拟器上写作 `SIMCTL_CHILD_CLANNAD_GAME_DIR=/path/to/CLANNAD/data`）。

环境变量：

| 变量 | 含义 |
|---|---|
| `CLANNAD_TEAM` | Apple Developer Team ID；自行签名时可设置，或写入被忽略的 `app/.team`。 |
| `CLANNAD_BUNDLE_ID` | 可指定原应用的 Bundle ID 做覆盖更新；未设置时使用稳定的 `org.local.clannad` 或附加 Team ID。 |
| `DEVELOPER_DIR` | 使用的 Xcode，默认 `/Applications/Xcode.app/Contents/Developer`。 |
| `CLANNAD_MAC_ARCHS` | Mac 打包默认 `arm64`；若使用 `x86_64`，先构建对应 Catalyst 引擎切片。 |

### 仓库结构

| 路径 | 内容 |
|---|---|
| `engine/siglus_rs/` | siglus_rs 引擎（MPL-2.0，上游 commit `5f358ef1`）及本项目的移植修改 |
| `app/` | XcodeGen 工程定义与 Swift 外壳（启动页、数据导入、播放器、输入映射） |
| `tools/apple/` | 引擎构建、工程生成、IPA / visionOS / Mac 打包脚本 |
| `tools/push_data.py` | 局域网导入工具（Python 3 标准库，无依赖） |
| `docs/VALIDATION.md` | 真机验证记录与覆盖边界 |
| `THIRD_PARTY_NOTICES.md` | 第三方组件与游戏版权声明 |

---

## 已知限制

- 免费 Apple ID 签名 **7 天**后过期，需要重新侧载；覆盖安装不会删除数据与存档，
  **卸载会删除**。
- iPhone / iPad 上的游戏数据保存在应用容器里：卸载应用 = 丢失 4.4 GB 数据与存档。
- Wi-Fi 导入需要设备与电脑在同一局域网；部分路由器开启「AP 隔离」时无法互连。
  4.4 GB 的导入时间取决于 Wi-Fi 速度。
- Apple Vision Pro 的未签名 IPA 不能直接安装，需要 Xcode 或支持 visionOS 的签名工具。
- Mac 版为 Mac Catalyst 构建，**未做公证**，首次打开需要右键 › 打开。
- 本项目使用引擎重实现（siglus_rs）而非原版可执行文件，极少数系统菜单/边界行为
  可能与 PC 版存在差异；遇到问题请附设备、系统版本与日志提 Issue。
- 本仓库不提供游戏本体、证书或 Apple 开发者账号。

---

## 许可与致谢

- 引擎 **siglus_rs** 及其修改以 **MPL-2.0** 发布：完整源码在本仓库
  `engine/siglus_rs/`，许可全文见 `engine/siglus_rs/LICENSE-MPL-2.0`；上游仓库
  <https://github.com/xmoezzz/siglus_rs>（vendor commit `5f358ef1`）。
  修改过的文件继续保留 MPL-2.0 许可头；分发二进制时请同时提供对应源码。
- 本项目的应用外壳（`app/`）、打包脚本（`tools/`）与文档以 **MIT** 发布，
  见 [`LICENSE`](LICENSE)（Copyright (c) 2026 galhack）；`engine/siglus_rs/` 不被
  MIT 重新授权，仍按 MPL-2.0 发布，移植补丁的说明见 `docs/ENGINE-PATCHES.md`。
- 后备字体为 **Noto Sans SC**（SIL OFL 1.1）；许可证与固定来源见
  `engine/siglus_rs/crates/siglus_scene_vm/assets/fonts/`，游戏自己的本地字体仍优先使用。
- 第三方组件（wgpu、winit、kira、symphonia 等）见
  [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
- 《CLANNAD》及其一切内容（程序、剧本、图片、音乐、语音、影片、官方简体中文资源）
  版权归 **VisualArt's / Key** 所有；Steam 版由 VisualArt's 发行。本项目与上述
  权利人无关，仅供已购买正版的玩家在自己的设备上游玩。
- 感谢 siglus_rs 作者与贡献者。

**作者**：galhack · **联系**：galhack@protonmail.com · **协作**：DeepSeek & Codex
