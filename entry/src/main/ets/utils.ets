
import { archiveLib } from '@mysoft/archive'
import { application, common } from '@kit.AbilityKit'
import { fileIo } from '@kit.CoreFileKit'
import { Xb_ToastUtil } from 'xb_components'


export const resolveJreArchive = async (context: common.Context, version: string): Promise<string> => {
  // resourceDir 属于当前 Module，不能通过替换 entry 路径来推导 HSP 的目录。
  // 让 Bundle Manager 创建目标 HSP 的 ModuleContext，既能确认模块实际可见，
  // 也能适配不同系统版本和安装形态下的真实资源路径。
  const moduleContext = await application.createModuleContext(context, version)
  const target = moduleContext.resourceDir + "/" + version + "-ohos-arm64.tar.xz"
  if (!await fileIo.access(target)) {
    throw new Error(`runtime archive missing in module ${version}`)
  }
  return target
}
export const installJre = async (context: common.Context, version: string)=> {
  const target = await resolveJreArchive(context, version)
  let out = context.filesDir +"/" + version
  if (!await fileIo.access(out)){
    Xb_ToastUtil.showToast({message:`${version}安装中...`})
    await decompressXz(target, out)
  }

}

export async function decompressXz(target: string, dir: string){
  try {
    await archiveLib.decompress({
      inFile: target,
      outFile: dir,
      onProgress: (current, total) => {
        console.log(`解压进度: ${current}/${total} 字节`)
      }
    })
  }catch (e) {
    console.error("decompressXz err:" + e.message)
    throw e
  }
}
