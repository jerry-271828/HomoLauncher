import { Xb_GameLayout, Xb_GameMenuState, Xb_getAppStore, Xb_getPersistence, Xb_GlobalContext, Xb_ToastUtil } from "xb_components";
import {KeyboardAvoidMode} from '@kit.ArkUI'
import { KeyCode } from "@kit.InputKit";
import { FCLKeycodes } from "../core/FCLKeycode";
import { GameViewModel } from "../core/GameViewModel";
import { HomlViewModel } from "../core/HomlViewModel";
import { window } from "@kit.ArkUI";
import { LogsView } from "../view/LogsView";
import { NativeInput } from "../core/NativeInput";
import { jvmLauncher } from "../core/JVMLauncher";
import { HOMLState } from "../entryability/AppState";

class GameXComponentController extends XComponentController{
  onSurfaceReady: (width: number, height: number) => void = () => {}

  onSurfaceCreated(surfaceId: string): void {
    console.info(`Game surface created: ${surfaceId}`)
  }
  onSurfaceChanged(surfaceId: string, rect: SurfaceRect): void {
    const width = Math.round(rect.surfaceWidth)
    const height = Math.round(rect.surfaceHeight)
    if (width <= 0 || height <= 0) {
      console.warn(`Ignore invalid game surface size: ${width}x${height}`)
      return
    }
    jvmLauncher.bridge.surfaceChanged(parseInt(surfaceId), width, height)
    this.onSurfaceReady(width, height)
  }
  onSurfaceDestroyed(surfaceId: string): void {
    console.info(`Game surface destroyed: ${surfaceId}`)
  }
}
@Builder
export function GameBuilder(route: string, version:string){
  Game({version})
}

@ComponentV2
struct Game {
  xController = new GameXComponentController();
  launchRequested = false
  @Param @Require version: string
  @Local viewModel: HomlViewModel = Xb_getAppStore(HomlViewModel, ()=> new HomlViewModel())!
  @Local nativeInput: NativeInput = Xb_getAppStore(NativeInput, ()=> new NativeInput())!

  @LocalBuilder
  gameView(){
    XComponent({id:"java-game", type: XComponentType.TEXTURE, controller: this.xController})
      .backgroundColor(Color.Black)
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: '100%', maxHeight: '100%' })
      LogsView()
  }
  build() {
    NavDestination(){
      Xb_GameLayout({gameView: this.gameView, eventHandler: new GameViewModel(), inGame: true, onNormKeyCode: FCLKeycodes.onNormKeyCode})
    }.hideTitleBar(true).onBackPressed(()=>{
      this.nativeInput.sendKeyEvent(KeyCode.KEYCODE_ESCAPE, true)
      return true;
    })
  }
  onBackPress(): boolean | void {
    this.nativeInput.sendKeyEvent(KeyCode.KEYCODE_ESCAPE, true)
    return true;
  }
  aboutToAppear(): void {
    this.launchRequested = false
    this.xController.onSurfaceReady = (width: number, height: number) => {
      if (this.launchRequested) {
        return
      }
      this.launchRequested = true
      // 下一轮 UI 任务再启动，确保 LogsView 已完成回调注册。
      setTimeout(() => {
        try {
          if (!this.viewModel.launch(width, height)) {
            this.launchRequested = false
            HOMLState.pageStack.pop()
          }
        } catch (error) {
          this.launchRequested = false
          console.error(`Launch game failed: ${error.message}`, error.stack)
          Xb_ToastUtil.showToast({message:`启动失败: ${error.message}`})
          HOMLState.pageStack.pop()
        }
      }, 0)
    }
    let orientation = window.Orientation.LANDSCAPE
    this.setScreenOrientation(orientation)
  }

  aboutToDisappear(): void {
    this.xController.onSurfaceReady = () => {}
    let orientation = window.Orientation.AUTO_ROTATION_RESTRICTED
    this.setScreenOrientation(orientation)
  }
  setScreenOrientation(orientation: window.Orientation) {
    let windowClass: window.Window | undefined = undefined;
    const context = this.getUIContext()
    context.setKeyboardAvoidMode(KeyboardAvoidMode.NONE)
    window.getLastWindow(Xb_GlobalContext.getContext()).then((data) => {
      windowClass = data
      windowClass.setWindowSystemBarEnable([])
      windowClass.setPreferredOrientation(orientation).catch((error: BusinessError) => {
        console.error(`setPreferredOrientation error name: ${error.name} message: ${error.message}`)
      })
    }).catch((err: BusinessError) => {
      console.error(`getLastWindow error name: ${err.name} message: ${err.message}`)
    })
  }
}
