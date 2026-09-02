/**
 * 个性化学情报告：输入学生成绩与课堂观察，AI 生成给家长的学情报告（双语界面 + 深浅主题）
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
struct Report {
  @State studentName: string = '李同学';
  @State className: string = '八年级2班';
  @State grades: string = '语文 88（班级均分 82）、数学 92（班级均分 78）、英语 85（班级均分 80）、物理 90（班级均分 76）';
  @State observation: string = '课堂积极发言，作业完成质量高；性格开朗，与同学相处融洽。最近一次周测物理满分，数学进步明显。';
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
    if (this.studentName.trim() === '') {
      promptAction.showToast({ message: this.appLang === 'en' ? 'Please enter the student name' : '请填写学生姓名' });
      return;
    }
    this.loading = true;
    this.result = '';
    const remarkPart: string = this.remark.trim() !== '' ? '\n【备注】' + this.remark.trim() : '';
    const user: string = `学生姓名：${this.studentName}\n班级：${this.className}\n各科成绩：${this.grades}\n课堂观察记录：${this.observation}\n\n请生成给家长的个性化学情报告。${remarkPart}`;
    try {
      const content: string = await AiService.chat(Prompts.studentReportSystem(), user, (partial: string) => {
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
    const typeLabel: string = I18n.t('page.report');
    HistoryStore.addRecord(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + this.studentName,
      content: this.result,
      time: HistoryStore.formatNow()
    }).then(() => {
      promptAction.showToast({ message: I18n.t('toast.saved') });
    });
  }

  build() {
    Column({ space: 0 }) {
      PageHeader({ title: this.t('page.report') })

      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Text(this.t('label.student')).fontSize(15).fontColor(this.col('title')).width(86)
          TextInput({
            text: this.studentName,
            placeholder: this.appLang === 'en' ? 'e.g. Student Name' : '如：李同学'
          })
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.studentName = v; })
        }
        .width('100%')
        Row({ space: 10 }) {
          Text(this.t('label.class')).fontSize(15).fontColor(this.col('title')).width(86)
          TextInput({
            text: this.className,
            placeholder: this.appLang === 'en' ? 'e.g. Class 2, Grade 8' : '如：八年级2班'
          })
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.className = v; })
        }
        .width('100%')
        Text(this.t('label.grades'))
          .fontSize(13)
          .fontColor(this.col('title'))
          .width('100%')
        TextArea({ text: this.grades, placeholder: this.t('ph.scores') })
          .width('100%')
          .height(70)
          .fontSize(13)
          .onChange((v: string) => { this.grades = v; })
        Text(this.t('label.observation'))
          .fontSize(13)
          .fontColor(this.col('title'))
          .width('100%')
        TextArea({ text: this.observation, placeholder: this.t('ph.observation') })
          .width('100%')
          .height(80)
          .fontSize(13)
          .onChange((v: string) => { this.observation = v; })

        Text(this.t('label.remark'))
          .fontSize(12)
          .fontColor(this.col('hint'))
          .width('100%')
        TextInput({ text: this.remark, placeholder: this.t('ph.remark') })
          .width('100%')
          .height(42)
          .fontSize(13)
          .onChange((v: string) => { this.remark = v; })

        Button(this.loading ? this.t('gen.loading') : this.t('act.report'))
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
          type: I18n.t('page.report'),
          title: I18n.t('page.report') + '-' + this.studentName,
          onSave: () => this.saveToHistory()
        })
          .layoutWeight(1)
          .padding(16)
      } else {
        Row() {
          Text(this.t('hint.safety'))
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
