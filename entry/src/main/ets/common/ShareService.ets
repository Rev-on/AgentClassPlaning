/**
 * 分享服务：把 Agent 生成的某一步产物通过鸿蒙 Share Kit 系统分享面板分发。
 * 实现路径：
 *  1. 导出为文件写入应用沙箱 filesDir（课件→.pptx；其余→.docx）；
 *  2. 用 fileUri.getUriFromPath() 把沙箱路径转换为系统可识别的 file:// URI；
 *  3. 用 systemShare.SharedData + ShareController.show() 拉起系统分享面板，
 *     由用户选择微信/邮件/WPS/保存到文件等目标，接收方通过该 URI 直接读取文件。
 * 说明：Share Kit 为商业 HarmonyOS SDK（@kit.ShareKit）能力，host 分享的是 URI 而非文件副本。
 */
import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import zlib from '@ohos.zlib';
import { systemShare } from '@kit.ShareKit';
import { fileUri, fileIo as fs } from '@kit.CoreFileKit';
import { DocxExporter } from './DocxExporter';
import { PptxExporter } from './PptxExporter';
import { I18n } from './I18n';

/** 参与打包分享的单份产物 */
export interface ShareItem {
  /** 产物类型：'courseware' → PPTX；其余 → Word（docx） */
  kind: string;
  label: string;
  content: string;
}

export class ShareService {
  /** PPTX 统一类型描述符 */
  private static readonly UTD_PPTX: string = 'org.openxmlformats.presentationml.presentation';
  /** DOCX 统一类型描述符 */
  private static readonly UTD_DOCX: string = 'org.openxmlformats.wordprocessingml.document';
  /** ZIP 压缩包统一类型描述符（单文件分享，接收方按其通用文件类型处理） */
  private static readonly UTD_ZIP: string = 'general.file';

  /**
   * 导出产物并通过系统分享面板分享。
   * @param ctx 上下文
   * @param kind 产物类型：'courseware' → PPTX；其余 → Word（docx）
   * @param label 产物名（用于分享标题与文件名）
   * @param content 产物内容（目标格式的原文）
   * @param anchorId 可选：锚点组件 id，让分享面板贴近触发按钮
   */
  static async exportAndShare(ctx: common.UIAbilityContext, kind: string, label: string,
    content: string, anchorId?: string): Promise<void> {
    const safe: string = ShareService.fileNameOf(label);
    try {
      let filePath: string = '';
      let utd: string = '';
      if (kind === 'courseware') {
        filePath = await PptxExporter.exportPptxToFile(ctx, content, safe + '.pptx');
        utd = ShareService.UTD_PPTX;
      } else {
        filePath = await DocxExporter.exportDocxToFile(ctx, content, safe + '.docx');
        utd = ShareService.UTD_DOCX;
      }
      // 沙箱路径 → 系统可识别 URI
      const uri: string = fileUri.getUriFromPath(filePath);
      const record: systemShare.SharedRecord = {
        utd: utd,
        uri: uri,
        title: label,
        label: label,
        description: ''
      };
      const data: systemShare.SharedData = new systemShare.SharedData(record);
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      const options: systemShare.ShareControllerOptions = {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL
      };
      if (anchorId !== undefined && anchorId !== '') {
        options.anchor = anchorId;
      }
      await controller.show(ctx, options);
    } catch (e) {
      const msg: string = e instanceof Error && e.message !== '' ?
        e.message : I18n.t('err.export');
      void promptAction.showToast({ message: msg });
    }
  }

  /**
   * 把多份产物打包为一个 ZIP 压缩包，再以"单个文件"方式分享：
   * 逐份导出为沙箱文件（课件→.pptx；其余→.docx）→ zlib.compressFiles 压缩为 ≤1 个 zip →
   * 以 SINGLE 模式拉起系统分享面板分发，接收方一次性拿到全部备课产物。
   * 完成后清理临时产物与压缩包。
   * @param ctx 上下文
   * @param items 待打包分享的多份产物
   * @param anchorId 可选：锚点组件 id，让分享面板贴近触发按钮
   */
  static async exportAndShareBatch(ctx: common.UIAbilityContext, items: ShareItem[],
    anchorId?: string): Promise<void> {
    if (items.length === 0) {
      return;
    }
    let zipPath: string = '';
    const produced: string[] = [];
    try {
      // 1) 逐份导出为沙箱文件
      for (let i: number = 0; i < items.length; i++) {
        const it: ShareItem = items[i];
        const safe: string = ShareService.fileNameOf(it.label);
        let filePath: string = '';
        if (it.kind === 'courseware') {
          filePath = await PptxExporter.exportPptxToFile(ctx, it.content, safe + '.pptx');
        } else {
          filePath = await DocxExporter.exportDocxToFile(ctx, it.content, safe + '.docx');
        }
        produced.push(filePath);
      }
      // 2) 打包为单个 ZIP（文件名用共享文案，经 fileNameOf 过滤掉文件名非法字符）
      zipPath = ctx.filesDir + '/' + ShareService.fileNameOf(I18n.t('share.bundleName')) +
        '_' + Date.now() + '.zip';
      await zlib.compressFiles(produced, zipPath, {
        level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION
      });
      // 3) 分享单个压缩包
      const uri: string = fileUri.getUriFromPath(zipPath);
      const record: systemShare.SharedRecord = {
        utd: ShareService.UTD_ZIP,
        uri: uri,
        title: I18n.t('share.bundleName'),
        label: I18n.t('share.bundleName'),
        description: I18n.t('share.bundleDesc').replace('{n}', items.length.toString())
      };
      const data: systemShare.SharedData = new systemShare.SharedData(record);
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      const options: systemShare.ShareControllerOptions = {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL
      };
      if (anchorId !== undefined && anchorId !== '') {
        options.anchor = anchorId;
      }
      await controller.show(ctx, options);
    } catch (e) {
      const msg: string = e instanceof Error && e.message !== '' ?
        e.message : I18n.t('err.export');
      void promptAction.showToast({ message: msg });
    } finally {
      // 4) 清理临时产物与压缩包，避免沙箱堆积
      for (let i: number = 0; i < produced.length; i++) {
        try {
          if (fs.accessSync(produced[i])) {
            fs.unlinkSync(produced[i]);
          }
        } catch (e) {
          // 单个文件清理失败不影响其它
        }
      }
      if (zipPath !== '') {
        try {
          if (fs.accessSync(zipPath)) {
            fs.unlinkSync(zipPath);
          }
        } catch (e) {
          // 忽略
        }
      }
    }
  }

  private static fileNameOf(label: string): string {
    // 去空、去换行、去系统文件名非法字符
    return label.replace(/[\s\r\n\\/:*?"<>|]/g, '_');
  }
}