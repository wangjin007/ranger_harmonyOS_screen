# OHScreen

把 HarmonyOS NEXT 设备的屏幕实时镜像到 Mac，方便在电脑上查看真机画面。

HarmonyOS 官方没有 Mac 版多屏协同。本项目走 `hdc` 调试通道（USB 或无线调试），做法接近 [scrcpy](https://github.com/Genymobile/scrcpy)：

1. 手机端 HAP 采集屏幕，编成 H.264，在本机 `27183` 端口等待连接
2. Mac 端用 `hdc fport` 把该端口转到电脑，解码后显示

当前版本只传输画面，不控制手机、不传声音。后续计划见 [TODO.md](TODO.md)。

不支持旧版「安卓底」鸿蒙，那些设备请直接用 scrcpy。

## 能做什么

- 在 Mac 窗口里看 HarmonyOS NEXT 手机 / 平板 / 二合一的实时画面
- 自动发现已连接的 `hdc` 设备
- 一键转发端口、拉起手机端、建立投屏
- 可选安装 DevEco 编出的 Debug HAP；若设备上已经装过，会直接启动 `com.ohscreen.server`
- 投屏窗口可隐藏两侧栏、进入全屏观看
- 诊断截图：从设备拉一张系统截图，用来确认 USB / hdc 是否正常

采集参数（手机端）：最长边不超过 1280、30 fps、约 8 Mbps H.264。

## 怎么工作

```
Mac  OHScreen  --hdc fport-->  设备 :27183  --H.264-->  Mac 解码显示
       |                          |
  hdc list / install / aa start   AVScreenCapture + 硬件编码
```

| 目录 | 说明 |
|------|------|
| `phone/` | 鸿蒙 HAP，用 DevEco Studio 打开 |
| `mac/` | macOS 客户端，用 Xcode 打开 `mac/OHScreen.xcodeproj` |
| `shared/protocol.md` | 两端 TCP 协议 |

包名：`com.ohscreen.server`  
Ability：`EntryAbility`  
端口：`27183`

## 环境要求

- HarmonyOS NEXT 5.0+ 真机，已打开 **开发者模式** 和 **USB 调试**（或无线调试）
- Mac：DevEco Studio（编译 HAP，并提供 `hdc`）、Xcode 15+
- 使用你平时跑鸿蒙工程的那套 **个人 Debug 签名** 即可，不需要另办证书

终端里先确认 `hdc` 可用：

```bash
hdc list targets
```

若提示找不到命令，把 DevEco 的 `toolchains` 加进 `PATH`，或设置环境变量 `HDC` 指向 `hdc` 可执行文件。

## 使用方法

### 1. 编译并安装手机端

1. 用 DevEco Studio 打开 `phone/`
2. 若提示 SDK / `compatibleSdkVersion` 与本机不一致，把 `phone/build-profile.json5` 改成你现有工程同款
3. 签名改成 **自动签名**（不要沿用仓库里别人的证书路径）
4. 顶部运行配置选带 **H** 图标的 `entry`，不要选 Hot Reload（改 native `.so` 后 Hot Reload 不会重新编 C++）
5. Run 到真机

也可以只 Build Hap，产物一般在：

```
phone/entry/build/default/outputs/default/entry-default-signed.hap
```

`hdc install` 只能安装 **Debug** 签名包。

### 2. 运行 Mac 端

1. Xcode 打开 `mac/OHScreen.xcodeproj`
2. Signing 选 **Sign to Run Locally**
3. Run
4. 点「刷新设备」，选中你的设备，再点「连接」
5. 手机弹出录屏 / 共享内容时，选 **屏幕** 并允许

连接后请滑回桌面或打开其它 App。不要停在 OHScreen 页面，也不要用分屏把 OHScreen 留在屏幕上，否则镜像里会一直看到本应用自己。

若 HAP 已经用 DevEco 装过，Mac 找不到 hap 文件也会尝试直接拉起已安装的应用。也可以在左侧点「选择 HAP」，指定刚才编出的 `entry-default-signed.hap`。

### 3. 日常操作

| 操作 | 说明 |
|------|------|
| 刷新设备 | 重新执行 `hdc list targets` |
| 连接 | 转发 `27183`、必要时安装 HAP、启动 Ability、开始收流 |
| 断开 | 关掉本机 TCP，手机端停止本轮采集并重新等待 |
| 诊断截图 | `snapshot_display` 拉一张静态图，不经过投屏链路 |
| 全屏 | 隐藏左右侧栏，只留画面 |

拔线、点断开、或手机上拒绝 / 停止录屏后，可以再点连接重来。每次会话系统都会重新弹录屏授权。

## 当前限制

这些是系统能力和当前版本共同决定的，不是故障：

- 每次连接都要在设备上允许录屏，状态栏会有录屏胶囊
- 锁屏、密码页、部分 DRM 视频会被系统黑掉或暂停
- 没有反向触控、没有声音
- 必须走 `hdc` 调试通道，不能当普通无线投屏器用
- Debug 签名包只能装到已授权的开发机，不能上架

## 协议

画面走自定义 TCP，格式见 [shared/protocol.md](shared/protocol.md)。改编码、分辨率或加音频 / 触控时，两端需要一起改。
