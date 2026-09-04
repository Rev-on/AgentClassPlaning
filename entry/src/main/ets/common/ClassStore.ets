/**
 * 班级数据存储：班级与其学生名单本地持久化（Preferences，JSON）
 * 所有数据仅保存在本机，不上云
 */
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';

export interface StudentItem {
  /** 学号（可空） */
  no: string;
  /** 姓名 */
  name: string;
  /** 身高 cm（可空） */
  height: string;
  /** 备注（可空，导入的其他列） */
  note: string;
}

export interface ClassItem {
  /** 自增 id */
  id: number;
  /** 班级名称，如：扬帆18班 */
  name: string;
  students: StudentItem[];
}

export class ClassStore {
  private static readonly STORE_NAME: string = 'app_classes';
  private static readonly KEY: string = 'classes';
  private static nextId: number = 1;

  static async loadAll(context: common.UIAbilityContext): Promise<ClassItem[]> {
    try {
      const store = await preferences.getPreferences(context, ClassStore.STORE_NAME);
      const v = await store.get(ClassStore.KEY, '[]');
      const list = JSON.parse(v as string) as ClassItem[];
      let maxId: number = 0;
      for (let i = 0; i < list.length; i++) {
        if (list[i].id > maxId) {
          maxId = list[i].id;
        }
      }
      ClassStore.nextId = maxId + 1;
      return list;
    } catch (e) {
      return [];
    }
  }

  static async saveAll(context: common.UIAbilityContext, list: ClassItem[]): Promise<void> {
    const store = await preferences.getPreferences(context, ClassStore.STORE_NAME);
    await store.put(ClassStore.KEY, JSON.stringify(list));
    await store.flush();
  }

  /** 新建班级，返回带 id 的对象 */
  static async addClass(context: common.UIAbilityContext, name: string, students: StudentItem[]): Promise<ClassItem> {
    const list = await ClassStore.loadAll(context);
    const item: ClassItem = { id: ClassStore.nextId++, name: name, students: students };
    list.push(item);
    await ClassStore.saveAll(context, list);
    return item;
  }

  static async updateClass(context: common.UIAbilityContext, item: ClassItem): Promise<void> {
    const list = await ClassStore.loadAll(context);
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === item.id) {
        list[i] = item;
        break;
      }
    }
    await ClassStore.saveAll(context, list);
  }

  static async deleteClass(context: common.UIAbilityContext, id: number): Promise<void> {
    const list = await ClassStore.loadAll(context);
    const next = list.filter((c: ClassItem) => c.id !== id);
    await ClassStore.saveAll(context, next);
  }
}
