import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import ohscreen from 'libohscreen.so';

const DOMAIN = 0x3200;
const PORT = 27183;
const MAX_SIDE = 1280;
const FPS = 30;
const BITRATE = 8_000_000;

function even(n: number): number {
  return n & ~1;
}

@Entry
@Component
struct Index {
  @State statusText: string = '正在启动…';
  @State detailText: string = '请用 Mac 端连接本机';
  @State running: boolean = false;
  @State ticks: number = 0;
  private timerId: number = -1;
  private keepAlive: boolean = false;
  private cancelCb: ((info: backgroundTaskManager.ContinuousTaskCancelInfo) => void) | undefined = undefined;

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

  private scaledSize(): [number, number, number] {
    try {
      const d = display.getDefaultDisplaySync();
      let w = d.width;
      let h = d.height;
      const longest = Math.max(w, h);
      if (longest > MAX_SIDE) {
        const scale = MAX_SIDE / longest;
        w = Math.floor(w * scale);
        h = Math.floor(h * scale);
      }
      return [even(w), even(h), d.id];
    } catch (err) {
      return [720, 1280, 0];
    }
  }

  private startService(): void {
    const size = this.scaledSize();
    const rc = ohscreen.startServer(PORT, size[0], size[1], FPS, BITRATE, size[2]);
    this.running = rc === 0;
    if (rc === 0) {
      this.statusText = '等待 Mac 连接';
      this.detailText = `端口 ${PORT} · ${size[0]}×${size[1]} · 连接后请允许整屏录制`;
    } else {
      this.statusText = '启动失败';
      this.detailText = `startServer 返回 ${rc}`;
    }
  }

  private stopService(): void {
    ohscreen.stopServer();
    this.stopKeepAlive();
    this.running = false;
    this.statusText = '已停止';
    this.detailText = '可点「开始等待」再次监听';
  }

  private refreshState(): void {
    if (!this.running) {
      return;
    }
    const s = ohscreen.getState();
    if (s === 1) {
      this.statusText = '等待 Mac 连接';
    } else if (s === 2) {
      this.statusText = '正在投屏';
      this.detailText = '授权后请滑回桌面或打开其它 App。不要停在本页，也不要用分屏把 OHScreen 留在屏幕上。';
      this.startKeepAlive();
    } else if (s === 3) {
      this.statusText = '录屏没启动';
      this.detailText = '授权被取消，或采集启动失败。请在 Mac 再点连接，弹窗里选「屏幕」并允许。';
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
        Button('开始等待')
          .width('60%')
          .backgroundColor('#2EC4B6')
          .fontColor('#111827')
          .onClick(() => {
            this.startService();
          })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: 80, bottom: 48 })
    .backgroundColor($r('app.color.page_background'))
  }
}
