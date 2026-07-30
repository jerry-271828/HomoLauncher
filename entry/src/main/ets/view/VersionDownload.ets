import { Xb_getAppStore, Xb_SwitchButton } from "xb_components"
import { HomlViewModel } from "../core/HomlViewModel"
import { DownloadViewModel } from "../core/DownloadViewModel"
import { VersionManifestEntry } from "../core/MCDownloader"
import { HOMLState } from "../entryability/AppState"


@Builder
export function VersionDownloadBuilder(name: string, param: Object) {
  VersionDownload()
}

@ComponentV2
struct VersionDownload {

  @Local viewmodel: HomlViewModel = Xb_getAppStore(HomlViewModel)!
  @Local downloadVM: DownloadViewModel = Xb_getAppStore(DownloadViewModel, () => new DownloadViewModel())!

  aboutToAppear(): void {
    this.downloadVM.fetchManifest()
  }

  build() {
    NavDestination() {
      Stack() {
        Column({ space: 10 }) {
          // 搜索 + 快照开关
          Row({ space: 8 }) {
            Search({ placeholder: '搜索版本...' })
              .layoutWeight(1)
              .onChange((value: string) => {
                this.downloadVM.searchText = value
              })
            Row({ space: 4 }) {
              Text('快照')
                .fontSize(14)
                .fontColor($r('sys.color.font_secondary'))
              Toggle({ type: ToggleType.Switch, isOn: this.downloadVM.showSnapshot })
                .onChange((isOn: boolean) => {
                  this.downloadVM.showSnapshot = isOn
                })
            }
          }
          .width('100%')
          .margin({ top: 12 })
          .padding({ left: 12, right: 12 })

          // 下载源选择
          Xb_SwitchButton({
            items: [{ text: 'BMCLAPI 镜像' }, { text: '官方源' }],
            switchOne: this.downloadVM.useMirror ? 0 : 1,
            WidthBp: HOMLState.widthBp,
            onClickUse: (index: number) => {
              this.downloadVM.switchSource(index == 0)
            }
          })
          .padding({ left: 12, right: 12 })
          .enabled(!this.downloadVM.downloading)

          if (this.downloadVM.loading) {
            Column() {
              LoadingProgress()
                .width(69)
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else if (this.downloadVM.loadError != "") {
            Column({ space: 10 }) {
              Text('加载失败:' + this.downloadVM.loadError)
                .fontSize(14)
                .fontColor($r('sys.color.font_secondary'))
              Button('重试')
                .onClick(() => {
                  this.downloadVM.fetchManifest(true)
                })
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            // 版本列表
            List({ space: 10 }) {
              ForEach(this.downloadVM.filtered(), (item: VersionManifestEntry) => {
                ListItem() {
                  Row({ space: 10 }) {
                    Image($r('app.media.icon_normal'))
                      .width(40)
                      .height(40)
                    Column({ space: 2 }) {
                      Text(item.id)
                        .fontWeight(FontWeight.Medium)
                        .fontSize(19)
                      Text(`${item.type == 'release' ? '正式版' : '快照'} · ${item.releaseTime.substring(0, 10)}`)
                        .fontSize(14)
                        .fontColor($r('sys.color.font_secondary'))
                    }
                    .alignItems(HorizontalAlign.Start)
                    Blank()
                    SymbolGlyph($r('sys.symbol.text_and_arrow_down'))
                      .fontSize(20)
                      .fontColor([$r('sys.color.icon_secondary')])
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 12, bottom: 12 })
                }
                .borderRadius(8)
                .onClick(() => {
                  this.downloadVM.startDownload(item, this.viewmodel.gameRootDir)
                })
              }, (item: VersionManifestEntry) => item.id)
            }
            .width('100%')
            .layoutWeight(1)
            .padding({ left: 12, right: 12 })
            .contentEndOffset(100 + HOMLState.bottomRectHeight)
          }
        }
        .width('100%')
        .height('100%')

        // 下载中覆盖层
        if (this.downloadVM.downloading) {
          Column({ space: 12 }) {
            LoadingProgress()
              .width(69)
            Text(`${this.downloadVM.currentVersionId}  ${this.downloadVM.doneCount}/${this.downloadVM.totalCount}`)
              .fontSize(16)
            Text(this.downloadVM.currentFile)
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 24, right: 24 })
            Button('取消')
              .onClick(() => {
                this.downloadVM.cancel()
              })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundBlurStyle(BlurStyle.Thin,
            { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT, scale: 0.3 })
        }
      }
      .width('100%')
      .height('100%')
    }
    .title('下载版本')
    .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
  }
}
