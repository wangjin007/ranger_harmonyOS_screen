# OHScreen

[中文](#ohscreen-中文) | [English](#ohscreen-english)

## OHScreen 中文

把 HarmonyOS NEXT 设备的屏幕实时镜像到 Mac，方便在电脑上查看真机画面。

HarmonyOS 官方没有 Mac 版多屏协同。本项目做法接近 [scrcpy](https://github.com/Genymobile/scrcpy)，提供两种连接方式：

- **USB**：走 `hdc` 调试通道转发画面
- **无线扫码**：手机扫 Mac 上的二维码，同一 Wi-Fi（或电脑连手机热点）直接传画面，日常不必再插线

当前版本只传输画面，不控制手机、不传声音。后续计划见 [TODO.md](TODO.md)。

不支持旧版「安卓底」鸿蒙，那些设备请直接用 scrcpy。

## 能做什么

- 在 Mac 窗口里看 HarmonyOS NEXT 手机 / 平板 / 二合一的实时画面
- **USB**：自动发现 `hdc` 设备，一键转发、拉起手机端、开始投屏
- **无线**：Mac 显示二维码和 6 位配对码，手机 OHScreen 扫码连接
- 横竖屏切换时 Mac 窗口跟着转，**不会再次弹出录屏授权**
- 可选安装 DevEco 编出的 Debug HAP；若设备上已经装过，USB 连接会直接启动 `com.ohscreen.server`
- 投屏窗口可隐藏两侧栏、进入全屏观看
- 诊断截图：从设备拉一张系统截图，用来确认 USB / hdc 是否正常

采集参数（手机端）：最长边不超过 1280、30 fps、约 8 Mbps H.264。

## 怎么工作

**USB**（手机当服务器，Mac 当客户端）：

```
Mac  OHScreen  --hdc fport-->  设备 :27183  --H.264-->  Mac 解码显示
       |                          |
  hdc list / install / aa start   AVScreenCapture + 硬件编码
```

**无线扫码**（Mac 当服务器，手机当客户端）：

```
Mac 监听 :27184  显示二维码  <---TCP---  手机扫码后连过来（先发配对码，再发 H.264）
```

两种模式端口分开，避免 USB 的 `hdc fport` 占着 27183 之后扫码失败：

| 用途 | 端口 | 谁监听 |
|------|------|--------|
| USB | `27183` | 手机 HAP，Mac 用 `hdc fport` 转过来 |
| 无线 | `27184` | Mac，二维码里带 IP 和端口 |

| 目录 | 说明 |
|------|------|
| `phone/` | 鸿蒙 HAP，用 DevEco Studio 打开 |
| `mac/` | macOS 客户端，用 Xcode 打开 `mac/OHScreen.xcodeproj` |
| `shared/protocol.md` | 两端 TCP 协议（含 USB / 扫码方向、配对、旋转控制包） |

包名：`com.ohscreen.server`  
Ability：`EntryAbility`

首次把 HAP 装到手机仍需要 USB / `hdc`（或 DevEco Run）。装好之后，日常可以只扫码，不必再开转发。

## 环境要求

- HarmonyOS NEXT 5.0+ 真机，已打开 **开发者模式** 和 **USB 调试**（第一次安装 HAP 用）
- Mac：DevEco Studio（编译 HAP，并提供 `hdc`）、Xcode 15+
- 无线：手机和电脑同一 Wi-Fi，或电脑加入手机热点
- 使用你平时跑鸿蒙工程的那套 **个人 Debug 签名** 即可，不需要另办证书

终端里先确认 `hdc` 可用（USB 模式需要）：

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

`hdc install` 只能安装 **Debug** 签名包。改过 C++ / 扫码 / 旋转相关代码后，必须重新 Run，不能只热重载。

### 2. 运行 Mac 端

1. Xcode 打开 `mac/OHScreen.xcodeproj`
2. Signing 选 **Sign to Run Locally**
3. Run
4. 左侧选择 **USB** 或 **无线**

### 3. USB 投屏

1. 点「刷新设备」，选中设备，再点「连接」
2. 手机弹出录屏 / 共享内容时，选 **屏幕** 并允许
3. 连接后请滑回桌面或打开其它 App。不要停在 OHScreen 页面，也不要用分屏把 OHScreen 留在屏幕上，否则镜像里会一直看到本应用自己

若 HAP 已经用 DevEco 装过，Mac 找不到 hap 文件也会尝试直接拉起已安装的应用。也可以在左侧点「选择 HAP」，指定刚才编出的 `entry-default-signed.hap`。

| 操作 | 说明 |
|------|------|
| 刷新设备 | 重新执行 `hdc list targets` |
| 连接 | 转发 `27183`、必要时安装 HAP、启动 Ability、开始收流 |
| 断开 | 关掉本机 TCP，并清掉 `hdc fport` |
| 诊断截图 | `snapshot_display` 拉一张静态图，不经过投屏链路 |
| 全屏 | 隐藏左右侧栏，只留画面 |

拔线后面面会停，状态为「USB 已断开」，并自动刷新设备列表。换机：新设备插上并授权调试 → 刷新设备 → 选中 → 连接。同一台再插回去，刷新后点连接即可。

### 4. 无线扫码

1. Mac 切到 **无线**，侧栏出现二维码和 6 位配对码（本机在听 `27184`）
2. 若系统询问防火墙，请允许 OHScreen 传入连接
3. 手机和电脑同一 Wi-Fi（或电脑连手机热点）
4. 手机点 **扫码连接电脑**，允许相机，扫 Mac 上的码
5. 弹出录屏时选 **屏幕** 并允许，然后滑回桌面

二维码内容形如：

```
ohscreen://<ip>:27184?pin=<6位数字>&alt=<其它IP>
```

手机按主 IP、再按 `alt` 依次尝试。连上后先发配对码，对不上 Mac 会断开。

| 操作 | 说明 |
|------|------|
| 刷新二维码 | 换新的配对码并重新监听 |
| 断开 | 结束当前投屏，回到等待扫码（会换新码） |
| 换机 | 当前手机点「停止」（或 Mac 点断开）后，新手机扫 **同一个码**。正在投屏时第二台扫码会被拒绝 |

USB 用完再切无线：拔线后可在手机上点停止，Mac 切到无线再扫。无线端口是 27184，不再和 USB 的 hdc 转发抢 27183。

### 5. 手机端按钮

| 按钮 | 说明 |
|------|------|
| 开始等待 USB | 在 `27183` 上等待 Mac 经 hdc 连过来 |
| 扫码连接电脑 | 打开扫码，连 Mac 无线模式 |
| 停止 | 结束当前 USB 等待或无线投屏 |

## 当前限制

这些是系统能力和当前版本共同决定的，不是故障：

- 每次**新开**投屏会话都要在设备上允许录屏，状态栏会有录屏胶囊；旋转屏幕不会再要一次授权
- 锁屏、密码页、部分 DRM 视频会被系统黑掉或暂停
- 没有反向触控、没有声音
- 第一次安装 HAP 仍要开发者模式 + Debug 签名，不能当普通投屏器给未开发的设备用，也不能上架
- 无线要求同一局域网；电脑若开了防火墙，需要允许 OHScreen
- 同一时刻无线只接受一台设备

## 协议

画面走自定义 TCP，格式见 [shared/protocol.md](shared/protocol.md)。改编码、分辨率、端口或加音频 / 触控时，两端需要一起改。

---

## OHScreen English

Mirror a HarmonyOS NEXT device screen to a Mac in real time.

HarmonyOS has no official Multi-Screen Collaboration client for Mac. This project is similar to [scrcpy](https://github.com/Genymobile/scrcpy) and supports two link modes:

- **USB**: video over the `hdc` debug channel
- **Wireless QR**: the phone scans a QR code on the Mac and streams over the same Wi-Fi (or the Mac joined to the phone hotspot). Day-to-day use does not need a cable

This version sends video only: no remote control, no audio. See [TODO.md](TODO.md) for planned work.

AOSP-based (old) HarmonyOS devices are not supported. Use scrcpy for those.

### Features

- Live view of a HarmonyOS NEXT phone / tablet / 2-in-1 in a Mac window
- **USB**: discover `hdc` devices, forward the port, launch the on-device app, start mirroring
- **Wireless**: Mac shows a QR code and a 6-digit PIN; the phone app scans it to connect
- Rotation follows the device **without asking for screen-recording permission again**
- Optionally install a Debug HAP built by DevEco; if it is already installed, USB connect starts `com.ohscreen.server` directly
- Hide the sidebars or enter a fullscreen view
- Diagnostic screenshot: pull a system snapshot over `hdc` to confirm USB / hdc is working

Capture settings (device side): longest edge ≤ 1280, 30 fps, ~8 Mbps H.264.

### How it works

**USB** (phone is the TCP server, Mac is the client):

```
Mac  OHScreen  --hdc fport-->  device :27183  --H.264-->  Mac decode & display
       |                          |
  hdc list / install / aa start   AVScreenCapture + hardware encoder
```

**Wireless QR** (Mac is the TCP server, phone is the client):

```
Mac listens :27184  shows QR  <---TCP---  phone scans and connects (PIN, then H.264)
```

The two modes use different ports so a leftover USB `hdc fport` on 27183 cannot block scanning:

| Mode | Port | Who listens |
|------|------|-------------|
| USB | `27183` | Phone HAP; Mac forwards it with `hdc fport` |
| Wireless | `27184` | Mac; IP and port are in the QR code |

| Path | Description |
|------|-------------|
| `phone/` | HarmonyOS HAP, open in DevEco Studio |
| `mac/` | macOS client, open `mac/OHScreen.xcodeproj` in Xcode |
| `shared/protocol.md` | TCP protocol (USB vs QR direction, PIN, rotation control) |

Bundle ID: `com.ohscreen.server`  
Ability: `EntryAbility`

The first HAP install still needs USB / `hdc` (or DevEco Run). After that, daily wireless use does not need forwarding.

### Requirements

- A HarmonyOS NEXT 5.0+ device with **Developer mode** and **USB debugging** (needed for the first HAP install)
- Mac: DevEco Studio (to build the HAP and provide `hdc`) and Xcode 15+
- Wireless: phone and Mac on the same Wi-Fi, or the Mac joined to the phone hotspot
- Use the same **personal Debug signing** you already use for HarmonyOS projects. No extra certificate is required.

Confirm `hdc` works in a terminal (required for USB):

```bash
hdc list targets
```

If the command is not found, add DevEco’s `toolchains` directory to `PATH`, or set the `HDC` environment variable to the `hdc` executable.

### Usage

#### 1. Build and install the device app

1. Open `phone/` in DevEco Studio
2. If the SDK / `compatibleSdkVersion` does not match your machine, change `phone/build-profile.json5` to the same values as your other projects
3. Switch signing to **automatic signing** (do not reuse another developer’s certificate paths in this repo)
4. In the run configuration, pick the `entry` target with the **H** icon, not Hot Reload (Hot Reload will not rebuild native `.so` after C++ changes)
5. Run on a physical device

You can also Build Hap only. The output is usually:

```
phone/entry/build/default/outputs/default/entry-default-signed.hap
```

`hdc install` accepts **Debug**-signed packages only. After C++ / QR / rotation changes, Run again; Hot Reload is not enough.

#### 2. Run the Mac app

1. Open `mac/OHScreen.xcodeproj` in Xcode
2. Set Signing to **Sign to Run Locally**
3. Run
4. Choose **USB** or **无线** (Wireless) in the sidebar

#### 3. USB mirroring

1. Click **Refresh devices**, select the device, then **Connect**
2. When the device asks for screen recording / content sharing, choose **Screen** and allow it
3. After connecting, swipe home or open another app. Do not stay on the OHScreen page, and do not keep OHScreen on screen in split view, or the mirror will only show this app

If the HAP is already installed via DevEco, the Mac app will try to launch it even when it cannot find a local `.hap` file. You can also click **Choose HAP** and point it at `entry-default-signed.hap`.

| Action | What it does |
|--------|----------------|
| Refresh devices | Runs `hdc list targets` again |
| Connect | Forwards `27183`, installs the HAP if needed, starts the Ability, and begins receiving frames |
| Disconnect | Closes local TCP and removes `hdc fport` |
| Diagnostic screenshot | Pulls a still image with `snapshot_display`, bypassing the video pipeline |
| Fullscreen | Hides both sidebars and shows only the picture |

Unplugging stops the picture (status **USB 已断开**) and refreshes the device list. To switch phones: plug in the new device, authorize debugging, refresh, select it, Connect. The same device can Connect again after you plug it back in.

#### 4. Wireless QR

1. Switch the Mac app to **无线**. The sidebar shows a QR code and a 6-digit PIN (Mac listens on `27184`)
2. Allow incoming connections if macOS asks about the firewall
3. Put the phone and Mac on the same Wi-Fi (or join the Mac to the phone hotspot)
4. On the phone tap **扫码连接电脑**, allow the camera, and scan the Mac QR code
5. Choose **Screen** when asked to record, then swipe home

QR payload:

```
ohscreen://<ip>:27184?pin=<6-digit>&alt=<other IPs>
```

The phone tries the primary IP, then `alt`. It sends the PIN before video; the Mac drops the connection if the PIN does not match.

| Action | What it does |
|--------|----------------|
| Refresh QR | New PIN and a fresh listener |
| Disconnect | Ends the current session and waits for a scan (new PIN) |
| Switch phones | Stop on the current phone (or Disconnect on the Mac), then scan **the same QR**. A second phone is rejected while one session is live |

After USB, unplug, optionally tap Stop on the phone, switch the Mac to Wireless, and scan. Wireless uses 27184 so it does not collide with a leftover `hdc` forward on 27183.

#### 5. Phone buttons

| Button | What it does |
|--------|----------------|
| 开始等待 USB | Listen on `27183` for Mac over hdc |
| 扫码连接电脑 | Scan the Mac QR and connect wirelessly |
| 停止 | Stop USB wait or the wireless session |

### Current limits

These come from the OS and this version. They are not bugs:

- Every **new** mirroring session needs on-device screen-recording permission, and a recording pill appears in the status bar. Rotating the device does not prompt again
- Lock screen, password screens, and some DRM video are blacked out or paused by the system
- No reverse control, no audio
- The first HAP install still needs Developer mode and a Debug signature. This is not a consumer caster for unsigned devices, and it cannot be published to an app store
- Wireless needs the same LAN; the Mac firewall must allow OHScreen
- Wireless accepts only one device at a time

### Protocol

Video uses a custom TCP protocol. See [shared/protocol.md](shared/protocol.md). If you change the codec, resolution, ports, or add audio / touch, update both sides together.
