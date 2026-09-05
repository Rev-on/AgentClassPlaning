/**
 * 通用结果展示组件：渲染 AI 生成结果，提供复制、导出 Word、保存到历史、整屏编辑
 * 编辑态直接在结果区以全屏文本框呈现，可修改后复制/导出/保存（组件内切换，不依赖弹窗，避免兼容性崩溃）
 * 支持中英双语与深浅主题
 */
import pasteboard from '@ohos.pasteboard';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { I18n } from '../I18n';
import { AppTheme } from '../AppTheme';
import { AppFonts } from '../AppFonts';
import { MdView } from './MdView';
import { DocxExporter } from '../DocxExporter';

@Component
export struct ResultPanel {
  /** 生成结果文本 */
  @Prop result: string = '';
  /** 功能类型（保存历史用） */
  type: string = '';
  /** 记录标题（保存历史用） */
  title: string = '';
  /** 保存回调（由父页面实现写入历史库） */
  onSave: (() => void) = () => {};
  /** 整屏编辑后的文本回写（父页面据此更新 result） */
  onEdited: ((t: string) => void) = (t: string): void => {
  };
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';

  /** 是否处于整屏编辑态 */
  @State editing: boolean = false;
  /** 编辑中的文本 */
  @State editText: string = '';

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  /** 复制指定文本到剪贴板 */
  private copyText(content: string): void {
    if (content === '') {
      return;
    }
    const sysPaste = pasteboard.getSystemPasteboard();
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, content);
    sysPaste.setData(data).then(() => {
      promptAction.showToast({ message: I18n.t('toast.copied') });
    }).catch(() => {
      promptAction.showToast({ message: I18n.t('err.copyFail') });
    });
  }

  /** 导出指定文本为 Word 文档 */
  private exportWord(content: string): void {
    if (content === '') {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const safeTitle: string = this.title === '' ? 'Result' : this.title;
    DocxExporter.exportDocx(ctx, content, safeTitle + '.docx').catch((err: Error) => {
      promptAction.showToast({ message: I18n.t('err.exportFail') + err.message });
    });
  }

  /** 进入编辑态 */
  private openEditor(): void {
    this.editText = this.result;
    this.editing = true;
  }

  /** 完成编辑：回写父页面并退出编辑态 */
  private doneEdit(): void {
    this.onEdited(this.editText);
    this.editing = false;
  }

  /** 编辑态保存：先回写再入库（保存编辑后的版本） */
  private saveEdited(): void {
    this.onEdited(this.editText);
    this.onSave();
  }

  /** 编辑态整屏视图 */
  @Builder
  editorView() {
    Column() {
      // 顶栏：标题 + 完成
      Row() {
        Text(this.t('editor.title'))
          .fontFamily(AppFonts.family())
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.col('title'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.t('btn.done'))
          .fontFamily(AppFonts.family())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#4A90D9')
          .padding({ left: 14, right: 4, top: 6, bottom: 6 })
          .onClick(() => {
            this.doneEdit();
          })
      }
      .width('100%')
      .padding({ left: 4, right: 4, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      // 可直接编辑的大文本框
      TextArea({ text: this.editText })
        .fontFamily(AppFonts.family())
        .fontSize(15)
        .fontColor(this.col('text'))
        .backgroundColor(this.col('bg'))
        .width('100%')
        .layoutWeight(1)
        .borderRadius(10)
        .onChange((v: string) => {
          this.editText = v;
        })

      // 底部操作
      Row({ space: 10 }) {
        Button(this.t('btn.copy'))
          .fontFamily(AppFonts.family())
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .backgroundColor('#4A90D9')
          .onClick(() => this.copyText(this.editText))
        Button(this.t('btn.exportWord'))
          .fontFamily(AppFonts.family())
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .backgroundColor('#2F6DB5')
          .onClick(() => this.exportWord(this.editText))
        Button(this.t('btn.saveHist'))
          .fontFamily(AppFonts.family())
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .backgroundColor('#5BA8A0')
          .onClick(() => this.saveEdited())
      }
      .width('100%')
      .padding({ top: 12 })
    }
    .width('100%')
    .height('100%')
  }

  /** 只读预览视图 */
  @Builder
  previewView() {
    Column({ space: 8 }) {
      Row() {
        if (this.result !== '') {
          Button(this.t('btn.edit'))
            .fontFamily(AppFonts.family())
            .fontSize(13)
            .height(30)
            .backgroundColor('#7A6BC4')
            .onClick(() => this.openEditor())
        }
        Blank()
        Button(this.t('btn.copy'))
          .fontFamily(AppFonts.family())
          .fontSize(13)
          .height(30)
          .backgroundColor('#4A90D9')
          .onClick(() => this.copyText(this.result))
        Button(this.t('btn.exportWord'))
          .fontFamily(AppFonts.family())
          .fontSize(13)
          .height(30)
          .backgroundColor('#2F6DB5')
          .margin({ left: 8 })
          .onClick(() => this.exportWord(this.result))
        Button(this.t('btn.saveHist'))
          .fontFamily(AppFonts.family())
          .fontSize(13)
          .height(30)
          .backgroundColor('#5BA8A0')
          .margin({ left: 8 })
          .onClick(() => {
            if (this.result !== '') {
              this.onSave();
            }
          })
      }
      .width('100%')
      .padding({ left: 4, right: 4 })

      Scroll() {
        if (this.result === '') {
          Text('（结果将在这里显示）')
            .fontFamily(AppFonts.family())
            .fontSize(15)
            .fontColor(this.col('hint'))
            .width('100%')
        } else {
          MdView({ markdown: this.result })
            .width('100%')
        }
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(this.col('card'))
      .borderRadius(12)
      .padding(12)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
  }

  build() {
    if (this.editing) {
      this.editorView()
    } else {
      this.previewView()
    }
  }
}
