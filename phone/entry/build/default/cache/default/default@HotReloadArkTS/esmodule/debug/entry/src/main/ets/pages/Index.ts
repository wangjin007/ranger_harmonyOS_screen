if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface Index_Params {
    statusText?: string;
    detailText?: string;
    running?: boolean;
    ticks?: number;
    timerId?: number;
    keepAlive?: boolean;
    cancelCb?: ((info: backgroundTaskManager.ContinuousTaskCancelInfo) => void) | undefined;
}
import type common from "@ohos:app.ability.common";
import wantAgent from "@ohos:app.ability.wantAgent";
import type { WantAgent as WantAgent } from "@ohos:app.ability.wantAgent";
import display from "@ohos:display";
import backgroundTaskManager from "@ohos:resourceschedule.backgroundTaskManager";
import type { BusinessError as BusinessError } from "@ohos:base";
import hilog from "@ohos:hilog";
import ohscreen from "@normalized:Y&&&libohscreen.so&";
const DOMAIN = 0x3200;
const PORT = 27183;
const MAX_SIDE = 1280;
const FPS = 30;
const BITRATE = 8000000;
function even(n: number): number {
    return n & ~1;
}
class Index extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__statusText = new ObservedPropertySimplePU('正在启动…', this, "statusText");
        this.__detailText = new ObservedPropertySimplePU('请用 Mac 端连接本机', this, "detailText");
        this.__running = new ObservedPropertySimplePU(false, this, "running");
        this.__ticks = new ObservedPropertySimplePU(0, this, "ticks");
        this.timerId = -1;
        this.keepAlive = false;
        this.cancelCb = undefined;
        this.setInitiallyProvidedValue(params);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: Index_Params) {
        if (params.statusText !== undefined) {
            this.statusText = params.statusText;
        }
        if (params.detailText !== undefined) {
            this.detailText = params.detailText;
        }
        if (params.running !== undefined) {
            this.running = params.running;
        }
        if (params.ticks !== undefined) {
            this.ticks = params.ticks;
        }
        if (params.timerId !== undefined) {
            this.timerId = params.timerId;
        }
        if (params.keepAlive !== undefined) {
            this.keepAlive = params.keepAlive;
        }
        if (params.cancelCb !== undefined) {
            this.cancelCb = params.cancelCb;
        }
    }
    updateStateVars(params: Index_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__statusText.purgeDependencyOnElmtId(rmElmtId);
        this.__detailText.purgeDependencyOnElmtId(rmElmtId);
        this.__running.purgeDependencyOnElmtId(rmElmtId);
        this.__ticks.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__statusText.aboutToBeDeleted();
        this.__detailText.aboutToBeDeleted();
        this.__running.aboutToBeDeleted();
        this.__ticks.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    private __statusText: ObservedPropertySimplePU<string>;
    get statusText() {
        return this.__statusText.get();
    }
    set statusText(newValue: string) {
        this.__statusText.set(newValue);
    }
    private __detailText: ObservedPropertySimplePU<string>;
    get detailText() {
        return this.__detailText.get();
    }
    set detailText(newValue: string) {
        this.__detailText.set(newValue);
    }
    private __running: ObservedPropertySimplePU<boolean>;
    get running() {
        return this.__running.get();
    }
    set running(newValue: boolean) {
        this.__running.set(newValue);
    }
    private __ticks: ObservedPropertySimplePU<number>;
    get ticks() {
        return this.__ticks.get();
    }
    set ticks(newValue: number) {
        this.__ticks.set(newValue);
    }
    private timerId: number;
    private keepAlive: boolean;
    private cancelCb: ((info: backgroundTaskManager.ContinuousTaskCancelInfo) => void) | undefined;
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
        }
        catch (err) {
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
            }
            catch (err) {
                hilog.error(DOMAIN, 'OHScreen', 'off continuousTaskCancel failed');
            }
            this.cancelCb = undefined;
        }
    }
    private abilityContext(): common.UIAbilityContext | undefined {
        try {
            return getContext(this) as common.UIAbilityContext;
        }
        catch (err) {
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
        }
        catch (err) {
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
        }
        catch (err) {
            const e = err as BusinessError;
            hilog.error(DOMAIN, 'OHScreen', `stopBackgroundRunning ${e.code} ${e.message}`);
        }
        this.keepAlive = false;
    }
    private scaledSize(): [
        number,
        number,
        number
    ] {
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
        }
        catch (err) {
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
        }
        else {
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
        }
        else if (s === 2) {
            this.statusText = '正在投屏';
            this.detailText = '授权后请滑回桌面或打开其它 App。不要停在本页，也不要用分屏把 OHScreen 留在屏幕上。';
            this.startKeepAlive();
        }
        else if (s === 3) {
            this.statusText = '录屏没启动';
            this.detailText = '授权被取消，或采集启动失败。请在 Mac 再点连接，弹窗里选「屏幕」并允许。';
        }
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.width('100%');
            Column.height('100%');
            Column.padding({ top: 80, bottom: 48 });
            Column.backgroundColor({ "id": 16777222, "type": 10001, params: [], "bundleName": "com.ohscreen.server", "moduleName": "entry" });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('OHScreen');
            Text.fontSize(28);
            Text.fontWeight(FontWeight.Bold);
            Text.fontColor('#E5E7EB');
            Text.margin({ bottom: 8 });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.statusText);
            Text.fontSize(20);
            Text.fontColor('#2EC4B6');
            Text.margin({ bottom: 12 });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.detailText);
            Text.fontSize(14);
            Text.fontColor('#9CA3AF');
            Text.textAlign(TextAlign.Center);
            Text.padding({ left: 24, right: 24 });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(`${Math.floor(this.ticks / 2)}s`);
            Text.fontSize(12);
            Text.fontColor('#6B7280');
            Text.margin({ top: 16 });
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Blank.create();
        }, Blank);
        Blank.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.running) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Button.createWithLabel('停止');
                        Button.width('60%');
                        Button.backgroundColor('#374151');
                        Button.onClick(() => {
                            this.stopService();
                        });
                    }, Button);
                    Button.pop();
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Button.createWithLabel('开始等待');
                        Button.width('60%');
                        Button.backgroundColor('#2EC4B6');
                        Button.fontColor('#111827');
                        Button.onClick(() => {
                            this.startService();
                        });
                    }, Button);
                    Button.pop();
                });
            }
        }, If);
        If.pop();
        Column.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
    static getEntryName(): string {
        return "Index";
    }
}
registerNamedRoute(() => new Index(undefined, {}), "", { bundleName: "com.ohscreen.server", moduleName: "entry", pagePath: "pages/Index", pageFullPath: "entry/src/main/ets/pages/Index", integratedHsp: "false", moduleType: "followWithHap" });
