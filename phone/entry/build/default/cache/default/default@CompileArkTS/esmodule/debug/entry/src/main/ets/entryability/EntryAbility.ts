import type AbilityConstant from "@ohos:app.ability.AbilityConstant";
import UIAbility from "@ohos:app.ability.UIAbility";
import type Want from "@ohos:app.ability.Want";
import hilog from "@ohos:hilog";
import type window from "@ohos:window";
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
