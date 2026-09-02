/**
 * 教案生成：输入课题信息，AI 生成结构化完整教案（双语界面 + 深浅主题）
 */
import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import { AiService } from '../common/AiService';
import { Prompts } from '../common/Prompts';
import { HistoryStore } from '../common/HistoryStore';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { PageHeader } from '../common/components/PageHeader';
import { ResultPanel } from '../common/components/ResultPanel';

@Entry
@Component
struct Plan {
  @State subject: string = '物理';
  @State version: string = '苏科版';
  @State grade: string = '八年级';
  @State topic: string = '光的反射';
  @State period: string = '第1课时';
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

  async generate(): Promise<void> {
    if (this.topic.trim() === '') {
      promptAction.showToast({ message: this.appLang === 'en' ? 'Please enter a topic' : '请填写课题名称' });
      return;
    }
    this.loading = true;
    this.result = '';
    const remarkPart: string = this.remark.trim() !== '' ? '\n【备注】' + this.remark.trim() : '';
    const user: string = `学科：${this.subject}\n教材版本：${this.version}\n年级：${this.grade}\n课题：${this.topic}\n课时：${this.period}\n\n请生成该课题的完整教案。${remarkPart}`;
    try {
      const content: string = await AiService.chat(Prompts.planSystem(), user, (partial: string) => {
        this.result = partial;
      });
      this.result = content;
    } catch (e) {
      promptAction.showToast({ message: (this.appLang === 'en' ? 'Failed: ' : '生成失败：') + (e as Error).message });
    } finally {
      this.loading = false;
    }
  }

  saveToHistory(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const typeLabel: string = I18n.t('page.plan');
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
      PageHeader({ title: this.t('page.plan') })

      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Text(this.t('label.subject')).fontSize(15).fontColor(this.col('title')).width(86)
          TextInput({ text: this.subject, placeholder: this.t('ph.subject') })
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.subject = v; })
        }
        .width('100%')
        Row({ space: 10 }) {
          Text(this.t('label.version')).fontSize(15).fontColor(this.col('title')).width(86)
          TextInput({ text: this.version, placeholder: this.t('ph.version') })
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.version = v; })
        }
        .width('100%')
        Row({ space: 10 }) {
          Text(this.t('label.grade')).fontSize(15).fontColor(this.col('title')).width(86)
          TextInput({ text: this.grade, placeholder: this.t('ph.grade') })
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.grade = v; })
        }
        .width('100%')
        Row({ space: 10 }) {
          Text(this.t('label.topic')).fontSize(15).fontColor(this.col('title')).width(86)
          TextInput({ text: this.topic, placeholder: this.t('ph.topic') })
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.topic = v; })
        }
        .width('100%')
        Row({ space: 10 }) {
          Text(this.t('label.period')).fontSize(15).fontColor(this.col('title')).width(86)
          TextInput({ text: this.period, placeholder: this.t('ph.period') })
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.period = v; })
        }
        .width('100%')
        Text(this.t('label.remark'))
          .fontSize(12)
          .fontColor(this.col('hint'))
          .width('100%')
        TextInput({ text: this.remark, placeholder: this.t('ph.remark') })
          .width('100%')
          .height(42)
          .fontSize(13)
          .onChange((v: string) => { this.remark = v; })

        Button(this.loading ? this.t('gen.loading') : this.t('act.plan'))
          .width('100%')
          .height(44)
          .backgroundColor(this.loading ? '#9DB8D9' : '#4A90D9')
          .enabled(!this.loading)
          .onClick(() => {
            this.generate();
          })
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.col('card'))
      .borderRadius(14)

      if (this.loading) {
        Row({ space: 10 }) {
          LoadingProgress().width(26).height(26).color('#4A90D9')
          Text(this.t('gen.loading')).fontSize(14).fontColor(this.col('sub'))
        }.width('100%').justifyContent(FlexAlign.Center).padding(20)
      } else if (this.result !== '') {
        ResultPanel({
          result: this.result,
          type: I18n.t('page.plan'),
          title: I18n.t('page.plan') + '-' + this.topic,
          onSave: () => this.saveToHistory()
        })
          .layoutWeight(1)
          .padding(16)
      } else {
        Row() {
          Text(this.t('hint.common'))
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
