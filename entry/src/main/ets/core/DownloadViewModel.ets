import { Xb_getAppStore, Xb_ToastUtil } from "xb_components"
import { CancelledError, fetchManifest, installVersion, VersionManifestEntry } from "./MCDownloader"
import { HomlViewModel } from "./HomlViewModel"

@ObservedV2
export class DownloadViewModel {

  // true=BMCLAPI 镜像 false=Mojang 官方源
  @Trace useMirror: boolean = true
  @Trace manifest: VersionManifestEntry[] = []
  @Trace loading: boolean = false
  @Trace loadError: string = ""
  @Trace showSnapshot: boolean = false
  @Trace searchText: string = ""

  @Trace downloading: boolean = false
  @Trace doneCount: number = 0
  @Trace totalCount: number = 0
  @Trace currentFile: string = ""
  @Trace currentVersionId: string = ""

  private cancelFlag: boolean = false
  // 已加载清单对应的源，切源后重新拉取
  private manifestLoadedFor: string = ""

  filtered(): VersionManifestEntry[] {
    return this.manifest.filter(d => {
      if (d.type != "release" && !(this.showSnapshot && d.type == "snapshot")) {
        return false
      }
      if (this.searchText != "" && d.id.indexOf(this.searchText) == -1) {
        return false
      }
      return true
    })
  }

  async fetchManifest(force: boolean = false) {
    if (this.loading) {
      return
    }
    const sourceKey = this.useMirror ? "mirror" : "official"
    if (!force && this.manifestLoadedFor == sourceKey && this.manifest.length > 0) {
      return
    }
    this.loading = true
    this.loadError = ""
    try {
      this.manifest = await fetchManifest(this.useMirror)
      this.manifestLoadedFor = sourceKey
    } catch (e) {
      this.manifest = []
      this.loadError = (e as Error).message ?? String(e)
    } finally {
      this.loading = false
    }
  }

  switchSource(useMirror: boolean) {
    if (this.downloading || this.useMirror == useMirror) {
      return
    }
    this.useMirror = useMirror
    this.fetchManifest()
  }

  async startDownload(entry: VersionManifestEntry, gameRootDir: string) {
    if (this.downloading) {
      return
    }
    this.downloading = true
    this.cancelFlag = false
    this.doneCount = 0
    this.totalCount = 0
    this.currentFile = ""
    this.currentVersionId = entry.id
    try {
      const id = await installVersion(entry, gameRootDir, this.useMirror,
        (done, total, current) => {
          this.doneCount = done
          this.totalCount = total
          this.currentFile = current
        },
        () => this.cancelFlag)
      Xb_ToastUtil.showToast({ message: `下载完成:${id}` })
      await Xb_getAppStore(HomlViewModel)?.loadVersions()
    } catch (e) {
      if (e instanceof CancelledError) {
        Xb_ToastUtil.showToast({ message: "已取消下载" })
      } else {
        const message = (e as Error).message ?? String(e)
        Xb_ToastUtil.showToast({ message: `下载失败:${message},可切换下载源重试` })
      }
    } finally {
      this.downloading = false
    }
  }

  cancel() {
    this.cancelFlag = true
  }
}
