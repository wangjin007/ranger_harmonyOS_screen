import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display, window } from '@kit.ArkUI';
import ohscreen from 'libohscreen.so';
import { scaledCaptureSize } from '../utils/CaptureSize';

const DOMAIN = 0x3200;

export default class EntryAbility extends UIAbility {
  private displayCallback: ((id: number) => void) | undefined = undefined;
  private rotateTimer: number = -1;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'OHScreen', 'EntryAbility onCreate');
    this.displayCallback = (_id: number): void => {
      if (this.rotateTimer >= 0) {
        clearTimeout(this.rotateTimer);
      }
      this.rotateTimer = setTimeout((): void => {
        this.rotateTimer = -1;
        const size = scaledCaptureSize();
        ohscreen.updateSize(size[0], size[1], size[2], size[3]);
        hilog.info(DOMAIN, 'OHScreen', `display size ${size[0]}x${size[1]} rot ${size[3]}`);
      }, 300);
    };
    try {
      display.on('change', this.displayCallback);
    } catch (err) {
      hilog.error(DOMAIN, 'OHScreen', 'display.on change failed');
    }
  }

  onDestroy(): void {
    if (this.rotateTimer >= 0) {
      clearTimeout(this.rotateTimer);
      this.rotateTimer = -1;
    }
    if (this.displayCallback !== undefined) {
      try {
        display.off('change', this.displayCallback);
      } catch (err) {
        hilog.error(DOMAIN, 'OHScreen', 'display.off change failed');
      }
      this.displayCallback = undefined;
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'OHScreen', 'loadContent failed %{public}d', err.code);
        return;
      }
      hilog.info(DOMAIN, 'OHScreen', 'content loaded');
    });
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'OHScreen', 'onBackground');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'OHScreen', 'onForeground');
  }
}
