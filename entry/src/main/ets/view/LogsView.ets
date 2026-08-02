import { EventHub, Xb_EventKey, Xb_GameMenuState, Xb_getPersistence,
  Xb_GlobalContext, Xb_getAppStore,
  Xb_ToastUtil } from "xb_components"
import { fileIo } from "@kit.CoreFileKit";
import { jvmLauncher } from "../core/JVMLauncher";
import { HomlViewModel } from "../core/HomlViewModel";

@ComponentV2
export struct LogsView{
  @Local menuState?: Xb_GameMenuState = Xb_getPersistence(Xb_GameMenuState, ()=> new Xb_GameMenuState())
  @Local logs:string[]= [];

  aboutToDisappear(): void {
    if(this.menuState != null){
      this.menuState!.showLogs = false
    }
  }
  aboutToAppear(): void {
    jvmLauncher.bridge.on_crash_message((message)=>{
      Xb_ToastUtil.showToast({message:message })
      this.logs.push(message)
      this.menuState!.showLogs = true;
    })
    jvmLauncher.bridge.on_log_message((message)=>{
      this.logs.push(message)
    })
    jvmLauncher.bridge.on_nominal_exit((signal)=>{
      this.menuState!.showLogs = true;
    })
    EventHub.on(Xb_EventKey.exportLogs, ()=>{
      this.saveLogs()
    })
  }
  async saveLogs(){
    try {
      if(Xb_GlobalContext.downloadDir == ""){
        await Xb_GlobalContext.initDownloadDir()
      }
      const savePath = Xb_GlobalContext.downloadDir + `/logs.txt`
      const file = await fileIo.open(savePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC)
      await fileIo.write(file.fd, JSON.stringify(this.logs));
      await fileIo.fsync(file.fd)
      await fileIo.close(file.fd)
      // 一并导出游戏运行目录里的崩溃报告和 latest.log（沙箱内可读）
      const vm = Xb_getAppStore(HomlViewModel)
      const id = vm?.current?.id
      if (id) {
        const runDir = vm!.getRunDirectory(id)
        await this.copyIfExists(runDir + "/logs/latest.log", Xb_GlobalContext.downloadDir + "/latest.log")
        try {
          const files = await fileIo.listFile(runDir + "/crash-reports")
          const txts = files.filter(f => f.endsWith(".txt")).sort()
          const last = txts[txts.length - 1]
          if (last) {
            await fileIo.copyFile(runDir + "/crash-reports/" + last, Xb_GlobalContext.downloadDir + "/" + last)
          }
        } catch (_) {
        }
      }
      Xb_ToastUtil.showToast({message: "已保存到下载目录"})
    }catch (e) {
      Xb_ToastUtil.showToast({message:"保存失败" + e.message})
    }
  }
  private async copyIfExists(src: string, dst: string){
    try {
      if (await fileIo.access(src)) {
        await fileIo.copyFile(src, dst)
      }
    } catch (_) {
    }
  }

  build() {
    if(this.menuState!.showLogs){
      List(){
        ForEach(this.logs,(l:string)=>{
          ListItem(){
            Text(`${l}`).fontColor(Color.Red)
          }
        })
      }
    }
  }
}