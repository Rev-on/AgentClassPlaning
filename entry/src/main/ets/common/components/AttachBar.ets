/**
 * 附件条（生成页共用）：+ 号菜单（图片/文档/拍照）+ 已选文件列表（上限 10）
 *  - 图片：@kit.CoreFileKit 的 picker.PhotoViewPicker
 *  - 文档：picker.DocumentViewPicker（docx/pptx/xlsx/txt 等自动提取文本）
 *  - 拍照：cameraPicker 调起相机（Android 侧接缝降级为相册单选）
 */
import common from '@ohos.app.ability.common';
import { I18n } from '../../common/I18n';
import { AppTheme } from '../../common/AppTheme';
import { AppFonts } from '../../common/AppFonts';
import { AttachFile } from '../../common/AttachTypes';
import { AttachService } from '../../common/AttachService';

@Component
export struct AttachBar {
  /** 已选附件（双向绑定到页面状态） */
  @Link files: AttachFile[];
  /** 上限（默认与服务端一致：10） */
  @Prop max: number = AttachService.MAX;
  /** 生成中锁定：整条置灰且不可交互 */
  @Prop disabled: boolean = false;
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  /** 选择/解析中：避免重复触发 */
  @State busy: boolean = false;

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  private menuItems(): MenuElement[] {
    const arr: MenuElement[] = [];
    const a1: MenuElement = { value: this.t('attach.image'), action: () => { this.doImages(); } };
    const a2: MenuElement = { value: this.t('attach.doc'), action: () => { this.doDocs(); } };
    const a3: MenuElement = { value: this.t('attach.camera'), action: () => { this.doCamera(); } };
    arr.push(a1);
    arr.push(a2);
    arr.push(a3);
    return arr;
  }

  private async doImages(): Promise<void> {
    if (this.busy || this.disabled) {
      return;
    }
    this.busy = true;
    try {
      this.files = await AttachService.pickImages(this.files);
    } finally {
      this.busy = false;
    }
  }

  private async doDocs(): Promise<void> {
    if (this.busy || this.disabled) {
      return;
    }
    this.busy = true;
    try {
      this.files = await AttachService.pickDocs(this.files);
    } finally {
      this.busy = false;
    }
  }

  private async doCamera(): Promise<void> {
    if (this.busy || this.disabled) {
      return;
    }
    this.busy = true;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      this.files = await AttachService.takePhoto(ctx, this.files);
    } finally {
      this.busy = false;
    }
  }

  private removeOne(id: string): void {
    if (this.disabled) {
      return;
    }
    this.files = AttachService.removeAt(this.files, id);
  }

  build() {
    Column({ space: 6 }) {
      Row() {
        Text(this.t('attach.title'))
          .fontFamily(AppFonts.family())
          .fontSize(12)
          .fontColor(this.col('hint'))
        Blank()
        Text(this.files.length + '/' + this.max)
          .fontFamily(AppFonts.family())
          .fontSize(12)
          .fontColor(this.col('hint'))
      }
      .width('100%')

      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.files, (f: AttachFile) => {
            Column({ space: 2 }) {
              Stack({ alignContent: Alignment.TopEnd }) {
                if (f.kind === 'image' && f.dataUrl !== '') {
                  Image(f.dataUrl)
                    .width(48)
                    .height(48)
                    .borderRadius(8)
                    .objectFit(ImageFit.Cover)
                } else {
                  Column() {
                    Text(f.ext.toUpperCase())
                      .fontFamily(AppFonts.family())
                      .fontSize(11)
                      .fontColor('#FFFFFF')
                  }
                  .width(48)
                  .height(48)
                  .borderRadius(8)
                  .backgroundColor('#6B7280')
                  .justifyContent(FlexAlign.Center)
                }
                Text('×')
                  .fontSize(12)
                  .fontColor('#FFFFFF')
                  .width(16)
                  .height(16)
                  .textAlign(TextAlign.Center)
                  .borderRadius(8)
                  .backgroundColor('#00000099')
                  .onClick(() => {
                    this.removeOne(f.id);
                  })
              }
              .width(48)
              .height(48)

              Text(f.name)
                .fontFamily(AppFonts.family())
                .fontSize(9)
                .fontColor(this.col('hint'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width(48)
            }
            .width(48)
          }, (f: AttachFile) => f.id)

          // + 号：点击弹出"图片 / 文档 / 拍照"
          Text('+')
            .fontSize(26)
            .fontColor(this.disabled ? '#C4CBD4' : (this.busy ? '#9DB8D9' : this.col('title')))
            .width(48)
            .height(48)
            .textAlign(TextAlign.Center)
            .borderRadius(8)
            .borderWidth(1)
            .borderColor(this.col('hint'))
            .borderStyle(BorderStyle.Dashed)
            .enabled(!this.disabled)
            .onClick(() => {
              // 菜单由 bindMenu 弹出（见下）
            })
            .bindMenu(this.menuItems())
        }
        .alignItems(VerticalAlign.Top)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .opacity(this.disabled ? 0.5 : 1)
  }
}
