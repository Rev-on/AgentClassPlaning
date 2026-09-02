/**
 * 沟通话术建议：老师描述家校沟通困难，AI 生成得体话术与避坑提示（双语界面 + 深浅主题）
 * 说明：下拉选项按界面语言显示中/英；发送给 AI 的字段值保留中文，便于生成内容
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
struct Talk {
  private sceneZh: string[] = ['学习退步沟通', '课堂表现反馈', '作业问题沟通', '考试后安抚', '家长会发言'];
  private sceneEn: string[] = ['Discuss falling grades', 'Classroom behavior feedback', 'Homework issues', 'After-exam reassurance', 'Parents meeting talk'];
  private toneZh: string[] = ['温和沟通', '正式规范', '激励引导'];
  private toneEn: string[] = ['Warm and gentle', 'Formal and professional', 'Encouraging and guiding'];

  @State sceneIndex: number = 0;
  @State toneIndex: number = 0;
  @State situation: string = '小明最近两次数学测验成绩下滑明显，从85分降到68分。家长比较焦虑，希望了解原因。';
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

  /** 界面显示的沟通场景选项（按语言返回中/英） */
  private sceneOptions(): SelectOption[] {
    const labels: string[] = this.appLang === 'en' ? this.sceneEn : this.sceneZh;
    const opts: SelectOption[] = [];
    for (let i = 0; i < labels.length; i++) {
      const opt: SelectOption = { value: labels[i] };
      opts.push(opt);
    }
    return opts;
  }

  /** 界面显示的语气选项（按语言返回中/英） */
  private toneOptions(): SelectOption[] {
    const labels: string[] = this.appLang === 'en' ? this.toneEn : this.toneZh;
    const opts: SelectOption[] = [];
    for (let i = 0; i < labels.length; i++) {
      const opt: SelectOption = { value: labels[i] };
      opts.push(opt);
    }
    return opts;
  }

  /** 当前场景的界面显示文本 */
  private sceneLabel(): string {
    const labels: string[] = this.appLang === 'en' ? this.sceneEn : this.sceneZh;
    return labels[this.sceneIndex];
  }

  /** 当前语气的界面显示文本 */
  private toneLabel(): string {
    const labels: string[] = this.appLang === 'en' ? this.toneEn : this.toneZh;
    return labels[this.toneIndex];
  }

  /** 发送给 AI 的沟通场景（保留中文） */
  private scene(): string {
    return this.sceneZh[this.sceneIndex];
  }

  /** 发送给 AI 的期望语气（保留中文） */
  private tone(): string {
    return this.toneZh[this.toneIndex];
  }

  async generate(): Promise<void> {
    if (this.situation.trim() === '') {
      promptAction.showToast({ message: this.appLang === 'en' ? 'Please describe the student situation' : '请填写学生情况描述' });
      return;
    }
    this.loading = true;
    this.result = '';
    const remarkPart: string = this.remark.trim() !== '' ? '\n【备注】' + this.remark.trim() : '';
    const user: string = `沟通场景：${this.scene()}\n学生情况描述：${this.situation}\n期望语气：${this.tone()}\n\n请生成沟通话术建议。${remarkPart}`;
    try {
      const content: string = await AiService.chat(Prompts.talkSystem(), user, (partial: string) => {
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
    const typeLabel: string = I18n.t('page.talk');
    HistoryStore.addRecord(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + this.sceneLabel(),
      content: this.result,
      time: HistoryStore.formatNow()
    }).then(() => {
      promptAction.showToast({ message: I18n.t('toast.saved') });
    });
  }

  build() {
    Column({ space: 0 }) {
      PageHeader({ title: this.t('page.talk') })

      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Text(this.t('label.scene')).fontSize(15).fontColor(this.col('title')).width(86)
          Select(this.sceneOptions())
            .selected(this.sceneIndex)
            .value(this.sceneLabel())
            .layoutWeight(1)
            .onSelect((index: number) => {
              this.sceneIndex = index;
            })
        }
        .width('100%')
        Row({ space: 10 }) {
          Text(this.t('label.tone')).fontSize(15).fontColor(this.col('title')).width(86)
          Select(this.toneOptions())
            .selected(this.toneIndex)
            .value(this.toneLabel())
            .layoutWeight(1)
            .onSelect((index: number) => {
              this.toneIndex = index;
            })
        }
        .width('100%')
        Text(this.appLang === 'en' ? 'Student situation (describe the difficulty in communication)' : '学生情况描述（说明沟通中遇到的困难）')
          .fontSize(13)
          .fontColor(this.col('title'))
          .width('100%')
        TextArea({ text: this.situation, placeholder: this.t('ph.situation') })
          .width('100%')
          .height(90)
          .fontSize(14)
          .onChange((v: string) => { this.situation = v; })

        Text(this.t('label.remark'))
          .fontSize(12)
          .fontColor(this.col('hint'))
          .width('100%')
        TextInput({ text: this.remark, placeholder: this.t('ph.remark') })
          .width('100%')
          .height(42)
          .fontSize(13)
          .onChange((v: string) => { this.remark = v; })

        Button(this.loading ? this.t('gen.loading') : this.t('act.talk'))
          .width('100%')
          .height(44)
          .backgroundColor(this.loading ? '#E5A3A3' : '#D9534F')
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
          LoadingProgress().width(26).height(26).color('#D9534F')
          Text(this.t('gen.loading')).fontSize(14).fontColor(this.col('sub'))
        }.width('100%').justifyContent(FlexAlign.Center).padding(20)
      } else if (this.result !== '') {
        ResultPanel({
          result: this.result,
          type: I18n.t('page.talk'),
          title: I18n.t('page.talk') + '-' + this.sceneLabel(),
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
