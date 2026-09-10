/**
 * 附件服务：把"选择/拍照 -> 处理 -> 列表管理 -> 提交结构"串起来（两端共用）
 *  - 上限 10 个（MAX）；超限时提示并截断
 *  - 图片压缩为 JPEG dataURL；文档提取纯文本；不支持解析的按文件名附带
 */
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { I18n } from './I18n';
import { AttachFile, TaskAttachment } from './AttachTypes';
import { AttachPicker, PickedItem } from './AttachPicker';
import { AttachCodec } from './AttachCodec';
import { AttachDoc } from './AttachDoc';

export class AttachService {
  /** 单次生成最多可带附件数（与服务端 MAX_ATTACH 一致） */
  static readonly MAX: number = 10;

  /** 相册选图 -> 合并进列表 */
  static async pickImages(cur: AttachFile[]): Promise<AttachFile[]> {
    try {
      const items: PickedItem[] = await AttachPicker.pickImages(AttachService.slot(cur));
      return await AttachService.build(items, cur);
    } catch (e) {
      return cur; // 用户取消或选择器异常：保持原列表
    }
  }

  /** 选择文档 -> 合并进列表 */
  static async pickDocs(cur: AttachFile[]): Promise<AttachFile[]> {
    try {
      const items: PickedItem[] = await AttachPicker.pickDocs(AttachService.slot(cur));
      return await AttachService.build(items, cur);
    } catch (e) {
      return cur;
    }
  }

  /** 拍照 -> 合并进列表 */
  static async takePhoto(ctx: common.UIAbilityContext, cur: AttachFile[]): Promise<AttachFile[]> {
    try {
      const items: PickedItem[] = await AttachPicker.takePhoto(ctx);
      return await AttachService.build(items, cur);
    } catch (e) {
      return cur;
    }
  }

  /** 剩余可选数量（至少 1，实际截断在 build 内统一处理） */
  private static slot(cur: AttachFile[]): number {
    const left: number = AttachService.MAX - cur.length;
    return left > 0 ? left : 1;
  }

  /** 处理并合并选择结果（统一做上限校验与解析） */
  private static async build(items: PickedItem[], cur: AttachFile[]): Promise<AttachFile[]> {
    const out: AttachFile[] = [];
    for (let i: number = 0; i < cur.length; i++) {
      out.push(cur[i]);
    }
    let skipped: number = 0;
    for (let i: number = 0; i < items.length; i++) {
      if (out.length >= AttachService.MAX) {
        skipped++;
        continue;
      }
      const f: AttachFile | null = await AttachService.make(items[i]);
      if (f !== null) {
        out.push(f);
      }
    }
    if (skipped > 0) {
      promptAction.showToast({ message: I18n.t('attach.limit') });
    }
    return out;
  }

  /** 单个文件 -> 附件记录 */
  private static async make(it: PickedItem): Promise<AttachFile | null> {
    try {
      const ext: string = AttachDoc.extOf(it.name);
      const bytes: Uint8Array = AttachCodec.readBytes(it.uri);
      if (AttachDoc.isImageExt(ext)) {
        const dataUrl: string = await AttachCodec.imageToDataUrl(it.uri, ext);
        const img: AttachFile = {
          id: AttachCodec.newId(), name: it.name, ext: ext, kind: 'image',
          size: bytes.length, dataUrl: dataUrl, text: ''
        };
        return img;
      }
      if (AttachDoc.isExtractable(ext)) {
        const text: string = await AttachDoc.extract(it.name, bytes);
        const doc: AttachFile = {
          id: AttachCodec.newId(), name: it.name, ext: ext,
          kind: text.trim() !== '' ? 'text' : 'file',
          size: bytes.length, dataUrl: '', text: text
        };
        return doc;
      }
      const other: AttachFile = {
        id: AttachCodec.newId(), name: it.name, ext: ext, kind: 'file',
        size: bytes.length, dataUrl: '', text: ''
      };
      return other;
    } catch (e) {
      promptAction.showToast({ message: I18n.t('attach.fail') });
      return null;
    }
  }

  /** 列表中移除指定项 */
  static removeAt(list: AttachFile[], id: string): AttachFile[] {
    const out: AttachFile[] = [];
    for (let i: number = 0; i < list.length; i++) {
      if (list[i].id !== id) {
        out.push(list[i]);
      }
    }
    return out;
  }

  /** 转为提交给服务端的结构（与 server normalizeAttachments 对齐） */
  static toTask(list: AttachFile[]): TaskAttachment[] {
    const out: TaskAttachment[] = [];
    for (let i: number = 0; i < list.length; i++) {
      const f: AttachFile = list[i];
      if (f.kind === 'image' && f.dataUrl !== '') {
        const t: TaskAttachment = { kind: 'image', name: f.name, data: f.dataUrl };
        out.push(t);
      } else if (f.kind === 'text' && f.text !== '') {
        const t: TaskAttachment = { kind: 'text', name: f.name, text: f.text };
        out.push(t);
      } else {
        const t: TaskAttachment = { kind: 'file', name: f.name };
        out.push(t);
      }
    }
    return out;
  }
}
