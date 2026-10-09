/**
 * 科目与满分设置页。
 *
 * 两个使用场景：
 *   ① **首次启动**：引导老师勾选需要分析的科目并填写满分（isFirstRun=true，
 *      此时不显示返回按钮，必须完成或使用默认值才能继续）；
 *   ② **「我的」页随时修改**：isFirstRun=false，可返回。
 *
 * 为什么需要这个配置：
 *   热力图按**得分率**（得分÷满分）着色。不知道满分就无法算得分率 ——
 *   例如物理满分 100 考 90 是优秀，而语文满分 120 考 90 只是中等，
 *   单看分数完全区分不出来。
 */
import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import { SubjectConfig, SubjectStore, CANDIDATE_SUBJECTS, DEFAULT_SUBJECTS } from '../common/SubjectStore';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AppFonts } from '../common/AppFonts';
import { SafeInsets } from '../common/SafeInsets';

@Entry
@Component
struct SubjectSetup {
  /** 首次启动引导：隐藏返回、按钮文案不同 */
  @State isFirstRun: boolean = false;
  /** 已勾选的科目名 */
  @State selected: string[] = [];
  /** 科目 -> 满分文本（保留用户输入原文，便于校验） */
  @State fullTexts: Record<string, string> = {};
  /** 自定义新增的科目名输入 */
  @State customName: string = '';
  @State topInset: number = 0;
  @State errorMsg: string = '';
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';

  aboutToAppear(): void {
    SafeInsets.topInset(getContext(this) as common.UIAbilityContext).then((v: number): void => {
      this.topInset = v;
    }).catch(() => {
      this.topInset = 0;
    });
    const params = router.getParams() as Record<string, Object>;
    if (params !== null && params !== undefined) {
      const f = params['firstRun'];
      this.isFirstRun = f === true;
    }
    this.loadExisting();
  }

  /** 载入已有配置；没有则给一套默认值 */
  private async loadExisting(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    const saved: SubjectConfig[] | null = await SubjectStore.load(ctx);
    const list: SubjectConfig[] = (saved !== null && saved.length > 0) ? saved : DEFAULT_SUBJECTS;
    const names: string[] = [];
    const texts: Record<string, string> = {};
    for (let i: number = 0; i < list.length; i++) {
      names.push(list[i].name);
      texts[list[i].name] = list[i].full.toString();
    }
    this.selected = names;
    this.fullTexts = texts;
  }

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  private isChecked(name: string): boolean {
    return this.selected.indexOf(name) >= 0;
  }

  /** 勾选/取消某科目；勾选时补上默认满分 */
  private toggle(name: string): void {
    const idx: number = this.selected.indexOf(name);
    if (idx >= 0) {
      const next: string[] = [];
      for (let i: number = 0; i < this.selected.length; i++) {
        if (i !== idx) {
          next.push(this.selected[i]);
        }
      }
      this.selected = next;
    } else {
      this.selected = this.selected.concat([name]);
      if (this.fullTexts[name] === undefined || this.fullTexts[name] === '') {
        const t: Record<string, string> = {};
        const keys: string[] = Object.keys(this.fullTexts);
        for (let i: number = 0; i < keys.length; i++) {
          t[keys[i]] = this.fullTexts[keys[i]];
        }
        t[name] = SubjectStore.defaultFull(name).toString();
        this.fullTexts = t;
      }
    }
    this.errorMsg = '';
  }

  /** 修改满分文本 */
  private setFull(name: string, v: string): void {
    const t: Record<string, string> = {};
    const keys: string[] = Object.keys(this.fullTexts);
    for (let i: number = 0; i < keys.length; i++) {
      t[keys[i]] = this.fullTexts[keys[i]];
    }
    t[name] = v;
    this.fullTexts = t;
    this.errorMsg = '';
  }

  /** 新增自定义科目 */
  private addCustom(): void {
    const name: string = this.customName.trim();
    if (name === '') {
      return;
    }
    if (this.selected.indexOf(name) >= 0) {
      this.customName = '';
      return;
    }
    this.selected = this.selected.concat([name]);
    this.setFull(name, SubjectStore.defaultFull(name).toString());
    this.customName = '';
  }

  /** 全部科目名（候选 + 已选中的自定义项） */
  private allNames(): string[] {
    const out: string[] = [];
    for (let i: number = 0; i < CANDIDATE_SUBJECTS.length; i++) {
      out.push(CANDIDATE_SUBJECTS[i]);
    }
    // 已选中的自定义科目（不在候选表里）也要显示，否则用户看不到、无法取消
    for (let i: number = 0; i < this.selected.length; i++) {
      if (out.indexOf(this.selected[i]) < 0) {
        out.push(this.selected[i]);
      }
    }
    return out;
  }

  /** 校验并保存 */
  private save(): void {
    if (this.selected.length === 0) {
      this.errorMsg = this.t('subj.errNoSubject');
      return;
    }
    const out: SubjectConfig[] = [];
    for (let i: number = 0; i < this.selected.length; i++) {
      const name: string = this.selected[i];
      const raw: string = (this.fullTexts[name] === undefined ? '' : this.fullTexts[name]).trim();
      const v: number = Number(raw);
      if (raw === '' || isNaN(v) || v <= 0) {
        this.errorMsg = I18n.t('subj.errBadFull').replace('{s}', name);
        return;
      }
      out.push({ name: name, full: v });
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    SubjectStore.save(ctx, out).then(() => {
      router.back();
    }).catch(() => {
      router.back();
    });
  }

  /** 使用默认配置（仅首次启动时提供，避免卡住用户） */
  private useDefault(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    SubjectStore.save(ctx, DEFAULT_SUBJECTS).then(() => {
      router.back();
    }).catch(() => {
      router.back();
    });
  }

  build() {
    Column() {
      // ---- 标题栏 ----
      Row({ space: 10 }) {
        if (!this.isFirstRun) {
          Button('←')
            .fontFamily(AppFonts.family())
            .fontSize(18)
            .fontColor(this.col('title'))
            .backgroundColor(this.col('card'))
            .width(40)
            .height(40)
            .borderRadius(20)
            .onClick(() => router.back())
        }
        Column({ space: 2 }) {
          Text(this.isFirstRun ? this.t('subj.welcomeTitle') : this.t('subj.title'))
            .fontFamily(AppFonts.family())
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.col('title'))
            .width('100%')
          Text(this.t('subj.sub'))
            .fontFamily(AppFonts.family())
            .fontSize(12)
            .fontColor(this.col('hint'))
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          // ---- 说明卡片 ----
          Text(this.t('subj.why'))
            .fontFamily(AppFonts.family())
            .fontSize(12)
            .fontColor(this.col('hint'))
            .width('100%')
            .padding(12)
            .backgroundColor(this.col('card'))
            .borderRadius(10)

          // ---- 科目勾选 ----
          Text(this.t('subj.pick'))
            .fontFamily(AppFonts.family())
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.col('title'))
            .width('100%')

          Column({ space: 8 }) {
            ForEach(this.allNames(), (name: string) => {
              Row({ space: 10 }) {
                // 勾选框
                Text(this.isChecked(name) ? '✓' : '')
                  .fontFamily(AppFonts.family())
                  .fontSize(14)
                  .fontColor('#FFFFFF')
                  .width(22)
                  .height(22)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(this.isChecked(name) ? '#4A90D9' : this.col('inputBg'))
                  .borderRadius(6)
                  .border({ width: 1, color: this.isChecked(name) ? '#4A90D9' : this.col('line') })
                  .onClick(() => this.toggle(name))

                Text(name)
                  .fontFamily(AppFonts.family())
                  .fontSize(14)
                  .fontColor(this.col('text'))
                  .layoutWeight(1)
                  .onClick(() => this.toggle(name))

                if (this.isChecked(name)) {
                  TextInput({ text: this.fullTexts[name] === undefined ? '' : this.fullTexts[name] })
                    .fontFamily(AppFonts.family())
                    .fontSize(14)
                    .type(InputType.Number)
                    .width(72)
                    .height(36)
                    .backgroundColor(this.col('inputBg'))
                    .placeholderColor(this.col('hint'))
                    .caretColor('#4A90D9')
                    .borderRadius(8)
                    .onChange((v: string) => this.setFull(name, v))
                  Text(this.t('subj.fullUnit'))
                    .fontFamily(AppFonts.family())
                    .fontSize(12)
                    .fontColor(this.col('hint'))
                }
              }
              .width('100%')
              .padding({ top: 4, bottom: 4 })
            }, (name: string) => 'sb_' + name)
          }
          .width('100%')
          .padding(12)
          .backgroundColor(this.col('card'))
          .borderRadius(10)

          // ---- 自定义科目 ----
          Row({ space: 8 }) {
            TextInput({ text: this.customName, placeholder: this.t('subj.customHint') })
              .fontFamily(AppFonts.family())
              .fontSize(14)
              .layoutWeight(1)
              .height(38)
              .backgroundColor(this.col('inputBg'))
              .placeholderColor(this.col('hint'))
              .caretColor('#4A90D9')
              .borderRadius(8)
              .onChange((v: string) => {
                this.customName = v;
              })
            Button(this.t('subj.add'))
              .fontFamily(AppFonts.family())
              .fontSize(13)
              .height(38)
              .backgroundColor('#3E948A')
              .onClick(() => this.addCustom())
          }
          .width('100%')

          // ---- 错误提示 ----
          if (this.errorMsg !== '') {
            Text(this.errorMsg)
              .fontFamily(AppFonts.family())
              .fontSize(12)
              .fontColor('#D93025')
              .width('100%')
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 12 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)

      // ---- 底部按钮 ----
      Row({ space: 10 }) {
        if (this.isFirstRun) {
          Button(this.t('subj.useDefault'))
            .fontFamily(AppFonts.family())
            .fontSize(14)
            .height(44)
            .layoutWeight(1)
            .backgroundColor(this.col('inputBg'))
            .fontColor(this.col('text'))
            .onClick(() => this.useDefault())
        }
        Button(this.t('subj.save'))
          .fontFamily(AppFonts.family())
          .fontSize(15)
          .height(44)
          .layoutWeight(2)
          .backgroundColor('#4A90D9')
          .onClick(() => this.save())
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.col('bg'))
    .padding({ top: this.topInset })
  }
}
