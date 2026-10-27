import { abilityAccessCtrl, common, Permissions, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import ohscreen from 'libohscreen.so';
import { scaledCaptureSize } from '../utils/CaptureSize';
import { parsePairPayload } from '../utils/PairUrl';

const DOMAIN = 0x3200;
const PORT = 27183;
const FPS = 30;
const BITRATE = 8_000_000;

@Entry
@Component
struct Index {
  @State statusText: string = '正在启动…';
  @State detailText: string = '请用 Mac 端连接本机';
  @State running: boolean = false;
  @State ticks: number = 0;
  @State streaming: boolean = false;
  private clientMode: boolean = false;
  private timerId: number = -1;
  private keepAlive: boolean = false;
  private cancelCb: ((info: backgroundTaskManager.ContinuousTaskCancelInfo) => void) | undefined = undefined;
  private audioManager: audio.AudioManager = audio.getAudioManager();
  private volumeManager: audio.AudioVolumeManager = this.audioManager.getVolumeManager();
  private originalMediaMuted: boolean | undefined = undefined;
  private macOnlyAudioActive: boolean = false;
  private volumeCb: (event: audio.StreamVolumeEvent) => void = (event: audio.StreamVolumeEvent): void => {
    if (!this.macOnlyAudioActive || event.streamUsage !== audio.StreamUsage.STREAM_USAGE_MUSIC) {
      return;
    }
    this.sendMediaVolume(event.volume);
  };

  aboutToAppear(): void {
    this.cancelCb = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      hilog.error(DOMAIN, 'OHScreen', `continuous task cancelled ${info.reason}`);
      this.keepAlive = false;
      if (this.running) {
        this.startKeepAlive();
      }
    };
    try {
      backgroundTaskManager.on('continuousTaskCancel', this.cancelCb);
    } catch (err) {
      hilog.error(DOMAIN, 'OHScreen', 'on continuousTaskCancel failed');
    }
    try {
      this.volumeManager.on('streamVolumeChange', audio.StreamUsage.STREAM_USAGE_MUSIC, this.volumeCb);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, 'OHScreen', `listen media volume ${e.code} ${e.message}`);
    }
    this.startService();
    this.timerId = setInterval((): void => {
      this.ticks += 1;
      this.refreshState();
    }, 500);
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    if (this.cancelCb !== undefined) {
      try {
        backgroundTaskManager.off('continuousTaskCancel', this.cancelCb);
      } catch (err) {
        hilog.error(DOMAIN, 'OHScreen', 'off continuousTaskCancel failed');
      }
      this.cancelCb = undefined;
    }
    try {
      this.volumeManager.off('streamVolumeChange', this.volumeCb);
    } catch (err) {
      hilog.error(DOMAIN, 'OHScreen', 'off streamVolumeChange failed');
    }
    this.disableMacOnlyAudio();
  }

  private abilityContext(): common.UIAbilityContext | undefined {
    try {
      return getContext(this) as common.UIAbilityContext;
    } catch (err) {
      hilog.error(DOMAIN, 'OHScreen', 'getContext failed');
      return undefined;
    }
  }

  private async startKeepAlive(): Promise<void> {
    if (this.keepAlive) {
      return;
    }
    const context = this.abilityContext();
    if (context === undefined) {
      return;
    }
    const info: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    try {
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], agent);
      this.keepAlive = true;
      hilog.info(DOMAIN, 'OHScreen', 'background running started');
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, 'OHScreen', `startBackgroundRunning ${e.code} ${e.message}`);
    }
  }

  private async stopKeepAlive(): Promise<void> {
    if (!this.keepAlive) {
      return;
    }
    const context = this.abilityContext();
    if (context === undefined) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      hilog.info(DOMAIN, 'OHScreen', 'background running stopped');
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, 'OHScreen', `stopBackgroundRunning ${e.code} ${e.message}`);
    }
    this.keepAlive = false;
  }

  private startService(): void {
    const size = scaledCaptureSize();
    const rc = ohscreen.startServer(PORT, size[0], size[1], FPS, BITRATE, size[2], size[3]);
    this.running = rc === 0;
    this.clientMode = false;
    this.streaming = false;
    if (rc === 0) {
      this.statusText = '等待 Mac 连接';
      this.detailText = `端口 ${PORT} · ${size[0]}×${size[1]} · 连接后请允许整屏录制`;
    } else {
      this.statusText = '启动失败';
      this.detailText = `startServer 返回 ${rc}`;
    }
  }

  private stopService(): void {
    this.disableMacOnlyAudio();
    ohscreen.stopServer();
    this.stopKeepAlive();
    this.running = false;
    this.streaming = false;
    this.clientMode = false;
    this.statusText = '已停止';
    this.detailText = '可点「开始等待」使用 USB，或扫码连接电脑';
  }

  private startWirelessClient(hosts: string, port: number, pin: number): void {
    ohscreen.stopServer();
    this.stopKeepAlive();
    const size = scaledCaptureSize();
    const rc = ohscreen.startClient(hosts, port, size[0], size[1], FPS, BITRATE, size[2], size[3], pin);
    this.running = rc === 0;
    this.clientMode = rc === 0;
    this.streaming = false;
    if (rc === 0) {
      this.statusText = '正在连接电脑';
      this.detailText = `${hosts} · 连接后请允许整屏录制`;
    } else {
      this.statusText = '连接失败';
      this.detailText = `startClient 返回 ${rc}。请先点停止再扫码。`;
    }
  }

  private async scanMac(): Promise<void> {
    const context = this.abilityContext();
    if (context === undefined) {
      return;
    }
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const permissions: Array<Permissions> = ['ohos.permission.CAMERA'];
      const grant = await atManager.requestPermissionsFromUser(context, permissions);
      if (grant.authResults.length > 0 && grant.authResults[0] !== 0) {
        this.detailText = '需要相机权限才能扫码';
        return;
      }
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, 'OHScreen', `camera permission ${e.code} ${e.message}`);
    }
    const options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.QR_CODE],
      enableMultiMode: false,
      enableAlbum: true
    };
    try {
      const result: scanBarcode.ScanResult = await scanBarcode.startScanForResult(context, options);
      const target = parsePairPayload(result.originalValue);
      if (target === undefined) {
        this.statusText = '二维码无效';
        this.detailText = '请扫描 Mac 端 OHScreen 无线模式显示的二维码';
        return;
      }
      this.startWirelessClient(target.hosts, target.port, target.pin);
    } catch (err) {
      const e = err as BusinessError;
      if (e.code !== 10005001) {
        this.detailText = `扫码失败 ${e.code} ${e.message}`;
        hilog.error(DOMAIN, 'OHScreen', `scan failed ${e.code} ${e.message}`);
      }
    }
  }

  private refreshState(): void {
    if (!this.running) {
      return;
    }
    const size = scaledCaptureSize();
    ohscreen.updateSize(size[0], size[1], size[2], size[3]);
    const s = ohscreen.getState();
    if (s === 1) {
      const wasStreaming = this.streaming;
      if (wasStreaming) {
        this.disableMacOnlyAudio();
      }
      this.statusText = this.clientMode ? '正在连接电脑' : '等待 Mac 连接';
      this.streaming = false;
      if (this.clientMode) {
        this.detailText = '正在连接电脑，连接后请允许整屏录制';
      } else if (wasStreaming) {
        this.detailText = '电脑已断开。可继续等待 USB；换机请在电脑刷新设备后再点连接。也可扫码改用无线。';
        this.stopKeepAlive();
      }
    } else if (s === 2) {
      const wasStreaming = this.streaming;
      this.streaming = true;
      if (!wasStreaming) {
        this.enableMacOnlyAudio();
      }
      this.statusText = '正在投屏';
      this.detailText = '仅电脑发声。手机音量键会调节电脑端投屏音量；结束投屏后自动恢复手机声音。授权后请打开其它 App。';
      this.startKeepAlive();
    } else if (s === 3) {
      this.disableMacOnlyAudio();
      this.streaming = false;
      this.statusText = this.clientMode ? '无线连接失败' : '录屏没启动';
      this.detailText = this.clientMode
        ? '电脑正在给其它设备投屏，或网络不通。请先让当前投屏的手机点停止（或电脑点断开），再扫同一个码。'
        : '授权被取消，或采集启动失败。请在 Mac 再点连接，弹窗里选「屏幕」并允许。';
    } else if (s === 0 && this.clientMode) {
      this.disableMacOnlyAudio();
      this.running = false;
      this.streaming = false;
      this.statusText = '已断开';
      this.detailText = '可再次扫同一个二维码，或点「开始等待」使用 USB';
    }
  }

  private sendMediaVolume(level: number): void {
    try {
      const max = this.volumeManager.getMaxVolumeByStream(audio.StreamUsage.STREAM_USAGE_MUSIC);
      const min = this.volumeManager.getMinVolumeByStream(audio.StreamUsage.STREAM_USAGE_MUSIC);
      const percent = max > min ? Math.round((level - min) * 100 / (max - min)) : 100;
      ohscreen.sendVolume(Math.max(0, Math.min(100, percent)));
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, 'OHScreen', `send media volume ${e.code} ${e.message}`);
    }
  }

  private async enableMacOnlyAudio(): Promise<void> {
    if (this.macOnlyAudioActive) {
      return;
    }
    this.macOnlyAudioActive = true;
    try {
      const original = await this.audioManager.isMute(audio.AudioVolumeType.MEDIA);
      if (!this.macOnlyAudioActive) {
        return;
      }
      this.originalMediaMuted = original;
      const level = this.volumeManager.getVolumeByStream(audio.StreamUsage.STREAM_USAGE_MUSIC);
      this.sendMediaVolume(level);
      await this.audioManager.mute(audio.AudioVolumeType.MEDIA, true);
      if (!this.macOnlyAudioActive) {
        await this.audioManager.mute(audio.AudioVolumeType.MEDIA, original);
        this.originalMediaMuted = undefined;
        return;
      }
      hilog.info(DOMAIN, 'OHScreen', 'phone media muted for Mac-only audio');
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, 'OHScreen', `mute phone media ${e.code} ${e.message}`);
      this.originalMediaMuted = undefined;
    }
  }

  private async disableMacOnlyAudio(): Promise<void> {
    if (!this.macOnlyAudioActive) {
      return;
    }
    this.macOnlyAudioActive = false;
    const restore = this.originalMediaMuted;
    this.originalMediaMuted = undefined;
    if (restore === undefined) {
      return;
    }
    try {
      await this.audioManager.mute(audio.AudioVolumeType.MEDIA, restore);
      hilog.info(DOMAIN, 'OHScreen', `phone media mute restored ${restore}`);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, 'OHScreen', `restore phone media ${e.code} ${e.message}`);
    }
  }

  build() {
    Column() {
      Text('OHScreen')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor('#E5E7EB')
        .margin({ bottom: 8 })
      Text(this.statusText)
        .fontSize(20)
        .fontColor('#2EC4B6')
        .margin({ bottom: 12 })
      Text(this.detailText)
        .fontSize(14)
        .fontColor('#9CA3AF')
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })
      Text(`${Math.floor(this.ticks / 2)}s`)
        .fontSize(12)
        .fontColor('#6B7280')
        .margin({ top: 16 })
      Blank()
      if (this.running) {
        Button('停止')
          .width('60%')
          .backgroundColor('#374151')
          .onClick(() => {
            this.stopService();
          })
      } else {
        Button('开始等待 USB')
          .width('60%')
          .backgroundColor('#2EC4B6')
          .fontColor('#111827')
          .onClick(() => {
            this.startService();
          })
      }
      if (!this.streaming) {
        Button('扫码连接电脑')
          .width('60%')
          .margin({ top: 12 })
          .backgroundColor('#1F2937')
          .fontColor('#E5E7EB')
          .onClick(() => {
            this.scanMac();
          })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: 80, bottom: 48 })
    .backgroundColor($r('app.color.page_background'))
  }
}
