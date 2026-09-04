/**
 * 班级详情：学生名单管理（增删）与 Excel / Word 名单导入
 * 所有改动即时保存到本机，不上云
 */
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { ClassStore, ClassItem, StudentItem } from '../common/ClassStore';
import { ClassImport } from '../common/ClassImport';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { PageHeader } from '../common/components/PageHeader';

@Entry
@Component
struct ClassDetail {
  @State cur: ClassItem = { id: -1, name: '', students: [] };
  @State loaded: boolean = false;
  @State inNo: string = '';
  @State inName: string = '';
  @State inHeight: string = '';
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

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const params = router.getParams() as Record<string, string>;
    const cid: number = params['cid'] === undefined ? -1 : Number(params['cid']);
    ClassStore.loadAll(ctx).then((list: ClassItem[]) => {
      for (let i = 0; i < list.length; i++) {
        if (list[i].id === cid) {
          this.cur = list[i];
          break;
        }
      }
      this.loaded = true;
    });
  }

  private persist(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const copy: ClassItem = {
      id: this.cur.id,
      name: this.cur.name,
      students: this.cur.students.slice()
    };
    ClassStore.updateClass(ctx, copy);
  }

  private saveName(): void {
    const name: string = this.cur.name.trim();
    if (name === '') {
      promptAction.showToast({ message: this.t('cls.nameRequired') });
      return;
    }
    this.persist();
  }

  private addStudent(): void {
    const name: string = this.inName.trim();
    if (name === '') {
      promptAction.showToast({ message: this.t('cls.nameNeed') });
      return;
    }
    const no: string = this.inNo.trim();
    const stu: StudentItem = { no: no, name: name, height: this.inHeight.trim(), note: '' };
    if (no !== '') {
      for (let i = 0; i < this.cur.students.length; i++) {
        if (this.cur.students[i].no === no) {
          promptAction.showToast({ message: this.t('cls.dupNo').replace('{n}', no) });
          return;
        }
      }
    }
    const next: StudentItem[] = this.cur.students.slice();
    next.push(stu);
    this.cur = { id: this.cur.id, name: this.cur.name, students: next };
    this.inNo = '';
    this.inName = '';
    this.inHeight = '';
    this.persist();
  }

  private removeStudent(index: number): void {
    AlertDialog.show({
      title: this.t('cls.removeStudent'),
      message: this.cur.students[index].name,
      primaryButton: {
        value: this.t('btn.close'), action: () => {}
      },
      secondaryButton: {
        value: this.t('cls.del'), fontColor: '#DC2626',
        action: () => {
          const next: StudentItem[] = this.cur.students.slice();
          next.splice(index, 1);
          this.cur = { id: this.cur.id, name: this.cur.name, students: next };
          this.persist();
        }
      }
    });
  }

  private doImport(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    ClassImport.pickAndParse(ctx).then((list: StudentItem[]) => {
      if (list.length === 0) {
        promptAction.showToast({ message: this.t('cls.noData') });
        return;
      }
      const next: StudentItem[] = this.cur.students.slice();
      let added: number = 0;
      let skipped: number = 0;
      for (let i = 0; i < list.length; i++) {
        const stu: StudentItem = list[i];
        let dup: boolean = false;
        if (stu.no !== '') {
          for (let j = 0; j < next.length; j++) {
            if (next[j].no === stu.no) {
              dup = true;
              break;
            }
          }
        }
        if (dup) {
          skipped++;
        } else {
          next.push(stu);
          added++;
        }
      }
      this.cur = { id: this.cur.id, name: this.cur.name, students: next };
      this.persist();
      promptAction.showToast({
        message: this.t('cls.importDone')
          .replace('{n}', added.toString())
          .replace('{m}', skipped.toString())
      });
    });
  }

  build() {
    Column({ space: 0 }) {
      PageHeader({ title: this.t('cls.detail') })

      if (this.loaded) {
        Scroll() {
          Column({ space: 12 }) {
            // 班级名称
            Column({ space: 8 }) {
              Row({ space: 8 }) {
                TextInput({ text: this.cur.name, placeholder: this.t('cls.namePh') })
                  .layoutWeight(1)
                  .backgroundColor(this.col('inputBg'))
                  .fontColor(this.col('text'))
                  .placeholderColor(this.col('hint'))
                  .onChange((v: string) => {
                    this.cur = { id: this.cur.id, name: v, students: this.cur.students };
                  })
                Button(this.t('cls.saveName'))
                  .fontSize(13)
                  .height(40)
                  .backgroundColor('#4A90D9')
                  .onClick(() => this.saveName())
              }
              .width('100%')
              Text(this.t('cls.students').replace('{n}', this.cur.students.length.toString()))
                .fontSize(12)
                .fontColor(this.col('sub'))
                .width('100%')
            }
            .width('100%')
            .padding(14)
            .backgroundColor(this.col('card'))
            .borderRadius(14)
            .alignItems(HorizontalAlign.Start)

            // 导入
            Column({ space: 8 }) {
              Button(this.t('cls.importBtn'))
                .width('100%')
                .height(40)
                .backgroundColor('#D97706')
                .onClick(() => this.doImport())
              Text(this.t('cls.importHint'))
                .fontSize(12)
                .fontColor(this.col('hint'))
                .width('100%')
              Text(this.t('mine.local'))
                .fontSize(11)
                .fontColor(this.col('faint'))
                .width('100%')
            }
            .width('100%')
            .padding(14)
            .backgroundColor(this.col('card'))
            .borderRadius(14)
            .alignItems(HorizontalAlign.Start)

            // 手动添加
            Column({ space: 8 }) {
              Row({ space: 8 }) {
                TextInput({ text: this.inNo, placeholder: this.t('cls.colNo') })
                  .layoutWeight(1)
                  .backgroundColor(this.col('inputBg'))
                  .fontColor(this.col('text'))
                  .placeholderColor(this.col('hint'))
                  .onChange((v: string) => { this.inNo = v; })
                TextInput({ text: this.inName, placeholder: this.t('cls.colName') })
                  .layoutWeight(1.4)
                  .backgroundColor(this.col('inputBg'))
                  .fontColor(this.col('text'))
                  .placeholderColor(this.col('hint'))
                  .onChange((v: string) => { this.inName = v; })
                TextInput({ text: this.inHeight, placeholder: this.t('cls.colHeight') })
                  .layoutWeight(1)
                  .type(InputType.Number)
                  .backgroundColor(this.col('inputBg'))
                  .fontColor(this.col('text'))
                  .placeholderColor(this.col('hint'))
                  .onChange((v: string) => { this.inHeight = v; })
              }
              .width('100%')
              Button(this.t('cls.add'))
                .width('100%')
                .height(38)
                .backgroundColor('#3E9B6F')
                .onClick(() => this.addStudent())
            }
            .width('100%')
            .padding(14)
            .backgroundColor(this.col('card'))
            .borderRadius(14)
            .alignItems(HorizontalAlign.Start)

            // 名单
            Column({ space: 6 }) {
              Row() {
                Text(this.t('cls.colNo')).fontSize(12).fontColor(this.col('hint')).layoutWeight(0.8)
                Text(this.t('cls.colName')).fontSize(12).fontColor(this.col('hint')).layoutWeight(1.4)
                Text(this.t('cls.colHeight')).fontSize(12).fontColor(this.col('hint')).layoutWeight(1)
                Text('').layoutWeight(0.6)
              }
              .width('100%')

              if (this.cur.students.length === 0) {
                Text(this.t('cls.noStudents'))
                  .fontSize(13)
                  .fontColor(this.col('hint'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding(12)
              } else {
                ForEach(this.cur.students, (stu: StudentItem, idx: number) => {
                  Row() {
                    Text(stu.no === '' ? '-' : stu.no).fontSize(13).fontColor(this.col('sub')).layoutWeight(0.8)
                    Text(stu.name).fontSize(14).fontColor(this.col('title')).layoutWeight(1.4)
                    Text(stu.height === '' ? '-' : stu.height).fontSize(13).fontColor(this.col('sub')).layoutWeight(1)
                    Button(this.t('cls.del'))
                      .fontSize(11)
                      .height(26)
                      .backgroundColor('#FDE8E8')
                      .fontColor('#C0392B')
                      .onClick(() => this.removeStudent(idx))
                  }
                  .width('100%')
                  .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                  .backgroundColor(this.col('card'))
                  .borderRadius(10)
                }, (stu: StudentItem, idx: number) => stu.no + '_' + idx)
              }
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .backgroundColor(this.col('bg'))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.col('bg'))
  }
}
