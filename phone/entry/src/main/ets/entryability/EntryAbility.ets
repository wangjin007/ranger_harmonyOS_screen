import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x3200;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'OHScreen', 'EntryAbility onCreate');
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
