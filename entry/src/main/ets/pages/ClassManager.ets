/**
 * 班级管理：班级列表（新建/重命名/删除/进入详情）
 */
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { ClassStore, ClassItem } from '../common/ClassStore';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AppFonts } from '../common/AppFonts';
import { PageHeader } from '../common/components/PageHeader';
import { VerticalMongolianText } from '../common/components/VerticalMongolianText';
import { ClassDetailContent } from './ClassDetail';

@Component
export struct ClassManagerContent {
  @State classes: ClassItem[] = [];
  @State inputName: string = '';
  /** 正在重命名的班级 id（-1 表示新建模式） */
  @State editId: number = -1;
  /** 两栏（平板横屏）模式下当前打开的班级详情 id（-1=仍在班级列表） */
  @State openCid: number = -1;
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  @StorageProp('appWideLayout') wideLayout: boolean = false;

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  aboutToAppear(): void {
    this.reload();
  }

  onPageShow(): void {
    this.reload();
  }

  reload(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    ClassStore.loadAll(ctx).then((list: ClassItem[]) => {
      this.classes = list;
    });
  }

  /** 新建或保存重命名 */
  private saveName(): void {
    const name: string = this.inputName.trim();
    if (name === '') {
      promptAction.showToast({ message: this.t('cls.nameRequired') });
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    if (this.editId >= 0) {
      ClassStore.loadAll(ctx).then((list: ClassItem[]) => {
        for (let i = 0; i < list.length; i++) {
          if (list[i].id === this.editId) {
            list[i].name = name;
            break;
          }
        }
        return ClassStore.saveAll(ctx, list);
      }).then(() => {
        this.editId = -1;
        this.inputName = '';
        this.reload();
      });
    } else {
      ClassStore.addClass(ctx, name, []).then(() => {
        this.inputName = '';
        this.reload();
      });
    }
  }

  private startNew(): void {
    this.editId = -1;
    this.inputName = '';
  }

  private beginRename(item: ClassItem): void {
    this.editId = item.id;
    this.inputName = item.name;
  }

  private removeClass(item: ClassItem): void {
    AlertDialog.show({
      title: this.t('cls.delClass'),
      message: this.t('cls.delClassMsg'),
      primaryButton: {
        value: this.t('btn.close'), action: () => {}
      },
      secondaryButton: {
        value: this.t('btn.clear'), fontColor: '#DC2626',
        action: () => {
          const ctx = getContext(this) as common.UIAbilityContext;
          ClassStore.deleteClass(ctx, item.id).then(() => {
            this.reload();
          });
        }
      }
    });
  }

  private openDetail(item: ClassItem): void {
    if (this.wideLayout) {
      // 两栏模式：右栏内嵌班级详情，不整屏跳转
      this.openCid = item.id;
      return;
    }
    router.pushUrl({ url: 'pages/ClassDetail', params: { cid: item.id.toString() } });
  }

  build() {
    Column({ space: 0 }) {
      if (this.wideLayout && this.openCid >= 0) {
        // 两栏（平板横屏）内嵌班级详情：提供“返回列表”按钮
        Row({ space: 10 }) {
          Button('←')
            .fontFamily(AppFonts.family())
            .fontSize(18)
            .fontColor(this.col('title'))
            .backgroundColor(this.col('card'))
            .width(40)
            .height(40)
            .borderRadius(20)
            .onClick(() => { this.openCid = -1; })
          VerticalMongolianText({
            content: this.t('cls.detail'),
            textSize: 20,
            textColor: this.col('title'),
            isBold: true
          })
        }
        .width('100%')
        .padding({ left: 4, right: 4, top: 6, bottom: 6 })
        ClassDetailContent({ cid: this.openCid })
      } else {
      PageHeader({ title: this.t('page.classes') })

      Column({ space: 12 }) {
        // 新建 / 重命名
        Row({ space: 8 }) {
          TextInput({ text: this.inputName, placeholder: this.t('cls.namePh') })
            .fontFamily(AppFonts.family())
            .layoutWeight(1)
            .backgroundColor(this.col('inputBg'))
            .fontColor(this.col('text'))
            .placeholderColor(this.col('hint'))
            .onChange((v: string) => { this.inputName = v; })
          Button(this.editId >= 0 ? this.t('cls.saveName') : this.t('cls.new'))
            .fontFamily(AppFonts.family())
            .fontSize(14)
            .height(40)
            .backgroundColor('#4A90D9')
            .onClick(() => this.saveName())
          if (this.editId >= 0) {
            Button(this.t('btn.close'))
              .fontFamily(AppFonts.family())
              .fontSize(13)
              .height(40)
              .backgroundColor(this.col('headBg'))
              .fontColor(this.col('sub'))
              .onClick(() => this.startNew())
          }
        }
        .width('100%')

        if (this.classes.length === 0) {
          Text(this.t('cls.empty'))
            .fontFamily(AppFonts.family())
            .fontSize(14)
            .fontColor(this.col('hint'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 60 })
        } else {
          List({ space: 10 }) {
            ForEach(this.classes, (item: ClassItem) => {
              ListItem() {
                Row({ space: 10 }) {
                  Column({ space: 4 }) {
                    Text(item.name)
                      .fontFamily(AppFonts.family())
                      .fontSize(16)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(this.col('title'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.t('cls.students').replace('{n}', item.students.length.toString()))
                      .fontFamily(AppFonts.family())
                      .fontSize(12)
                      .fontColor(this.col('hint'))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  Button(this.t('cls.rename'))
                    .fontFamily(AppFonts.family())
                    .fontSize(12)
                    .height(30)
                    .backgroundColor(this.col('headBg'))
                    .fontColor(this.col('sub'))
                    .onClick(() => this.beginRename(item))
                  Button(this.t('cls.del'))
                    .fontFamily(AppFonts.family())
                    .fontSize(12)
                    .height(30)
                    .backgroundColor('#FDE8E8')
                    .fontColor('#C0392B')
                    .margin({ left: 4 })
                    .onClick(() => this.removeClass(item))
                }
                .width('100%')
                .padding(14)
                .backgroundColor(this.col('card'))
                .borderRadius(12)
                .onClick(() => this.openDetail(item))
              }
            }, (item: ClassItem) => item.id.toString())
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding(16)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.col('bg'))
  }
}


@Entry
@Component
struct ClassManagerEntry {
  build() {
    Column() {
      ClassManagerContent()
    }
    .width('100%')
    .height('100%')
  }

  }
