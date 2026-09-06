/**
 * 课件大纲：输入课题，AI 生成逐页 PPT 大纲（含配图建议）（双语界面 + 深浅主题）
 */
import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import { AiService } from '../common/AiService';
import { Prompts } from '../common/Prompts';
import { HistoryStore } from '../common/HistoryStore';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AppFonts } from '../common/AppFonts';
import { PageHeader } from '../common/components/PageHeader';
import { ResultPanel } from '../common/components/ResultPanel';

@Entry
@Component
struct Courseware {
  @State subject: string = I18n.t('def.subject');
  @State grade: string = I18n.t('def.grade');
  @State topic: string = I18n.t('def.topic');
  @State usage: string = I18n.t('def.usage');
  @State remark: string = '';
  @State loading: boolean = false;
  @State result: string = '';
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  /** 从原始输出中提取合法 JSON 并格式化为缩进文本；失败返回 null */
  private normalizeJson(raw: string): string | null {
    let text: string = raw.trim();
    const fenceStart: number = text.indexOf('```');
    if (fenceStart >= 0) {
      const fenceEnd: number = text.lastIndexOf('```');
      if (fenceEnd > fenceStart) {
        text = text.substring(fenceStart + 3, fenceEnd).trim();
      }
    }
    const s: number = text.indexOf('[');
    const e: number = text.lastIndexOf(']');
    if (s < 0 || e <= s) {
      return null;
    }
    text = text.substring(s, e + 1);
    let obj: object | null = null;
    try {
      obj = JSON.parse(text) as object;
    } catch (err) {
      return null;
    }
    if (obj === null || !Array.isArray(obj)) {
      return null;
    }
    return JSON.stringify(obj, null, 2);
  }

  async generate(): Promise<void> {
    if (this.topic.trim() === '') {
      promptAction.showToast({ message: this.t('err.noTopic') });
      return;
    }
    this.loading = true;
    this.result = '';
    const remarkPart: string = this.remark.trim() !== '' ? '\n【备注】' + this.remark.trim() : '';
    const user: string = `学科：${this.subject}\n年级：${this.grade}\n课题：${this.topic}\n课型/用途：${this.usage}\n\n请生成该课题的逐页课件大纲（JSON 格式）。${remarkPart}`;
    try {
      const content: string = await AiService.chat(Prompts.coursewareSystem(), user, (partial: string) => {
        this.result = partial;
      }, true, {
        ctx: getContext(this) as common.UIAbilityContext,
        type: 'courseware',
        label: I18n.t('page.courseware')
      });
      const pretty: string | null = this.normalizeJson(content);
      const finalText: string = pretty !== null ? pretty : content;
      if (pretty !== null) {
        this.result = pretty;
      } else {
        this.result = content;
        promptAction.showToast({ message: this.t('err.jsonInvalid') });
      }
      this.autoSaveHistory(finalText);
    } catch (e) {
      promptAction.showToast({ message: this.t('err.genFail') + (e as Error).message });
    } finally {
      this.loading = false;
    }
  }

  /** 自动保存到历史（开关开启且内容非空时静默保存；content 用于页面已离开时的兜底） */
  private autoSaveHistory(content?: string): void {
    const text: string = content !== undefined && content !== '' ? content : this.result;
    if (text === '') {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const typeLabel: string = I18n.t('page.courseware');
    HistoryStore.autoAdd(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + this.topic,
      content: text,
      time: HistoryStore.formatNow()
    });
  }

  saveToHistory(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const typeLabel: string = I18n.t('page.courseware');
    HistoryStore.addRecord(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + this.topic,
      content: this.result,
      time: HistoryStore.formatNow()
    }).then(() => {
      promptAction.showToast({ message: I18n.t('toast.saved') });
    });
  }

  build() {
    Column({ space: 0 }) {
      PageHeader({ title: this.t('page.courseware') })

      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Text(this.t('label.subject')).fontSize(15).fontColor(this.col('title')).width(86)
            .fontFamily(AppFonts.family())
          TextInput({ text: this.subject, placeholder: this.t('ph.subject') })
            .fontFamily(AppFonts.family())
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.subject = v; })
        }
        .width('100%')
        Row({ space: 10 }) {
          Text(this.t('label.grade')).fontSize(15).fontColor(this.col('title')).width(86)
            .fontFamily(AppFonts.family())
          TextInput({ text: this.grade, placeholder: this.t('ph.grade') })
            .fontFamily(AppFonts.family())
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.grade = v; })
        }
        .width('100%')
        Row({ space: 10 }) {
          Text(this.t('label.topic')).fontSize(15).fontColor(this.col('title')).width(86)
            .fontFamily(AppFonts.family())
          TextInput({ text: this.topic, placeholder: this.t('ph.topic') })
            .fontFamily(AppFonts.family())
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.topic = v; })
        }
        .width('100%')
        Row({ space: 10 }) {
          Text(this.t('label.usage')).fontSize(15).fontColor(this.col('title')).width(86)
            .fontFamily(AppFonts.family())
          TextInput({ text: this.usage, placeholder: this.t('ph.usage') })
            .fontFamily(AppFonts.family())
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.usage = v; })
        }
        .width('100%')
        Text(this.t('label.remark'))
          .fontFamily(AppFonts.family())
          .fontSize(12)
          .fontColor(this.col('hint'))
          .width('100%')
        TextInput({ text: this.remark, placeholder: this.t('ph.remark') })
          .fontFamily(AppFonts.family())
          .width('100%')
          .height(42)
          .fontSize(13)
          .onChange((v: string) => { this.remark = v; })

        Button(this.loading ? this.t('gen.loading') : this.t('act.courseware'))
          .fontFamily(AppFonts.family())
          .width('100%')
          .height(44)
          .backgroundColor(this.loading ? '#E9C98F' : '#F0A93F')
          .enabled(!this.loading)
          .onClick(() => {
            this.generate();
          })
        Text(this.t('hint.coursewareJson'))
          .fontFamily(AppFonts.family())
          .fontSize(11)
          .fontColor(this.col('hint'))
          .width('100%')
          .lineHeight(16)
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.col('card'))
      .borderRadius(14)

      if (this.loading) {
        Row({ space: 10 }) {
          LoadingProgress().width(26).height(26).color('#F0A93F')
          Text(this.t('gen.loading')).fontSize(14).fontColor(this.col('sub'))
            .fontFamily(AppFonts.family())
        }.width('100%').justifyContent(FlexAlign.Center).padding(20)
      } else if (this.result !== '') {
        ResultPanel({
          result: this.result,
          type: I18n.t('page.courseware'),
          title: I18n.t('page.courseware') + '-' + this.topic,
          exportMode: 'json',
          onSave: () => this.saveToHistory(),
          onEdited: (t: string): void => {
            this.result = t;
          }
        })
          .layoutWeight(1)
          .padding(16)
      } else {
        Row() {
          Text(this.t('hint.common'))
            .fontFamily(AppFonts.family())
            .fontSize(12)
            .fontColor(this.col('hint'))
            .lineHeight(18)
        }
        .width('100%')
        .padding(16)
        .layoutWeight(1)
        .alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor(this.col('bg'))
  }
}
