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
import { systemShare } from '@kit.ShareKit';
import { fileUri } from '@kit.CoreFileKit';
import { DocxExporter } from './DocxExporter';
import { PptxExporter } from './PptxExporter';
import { I18n } from './I18n';

export class ShareService {
  /** PPTX 统一类型描述符 */
  private static readonly UTD_PPTX: string = 'org.openxmlformats.presentationml.presentation';
  /** DOCX 统一类型描述符 */
  private static readonly UTD_DOCX: string = 'org.openxmlformats.wordprocessingml.document';

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

  private static fileNameOf(label: string): string {
    // 去空、去换行、去系统文件名非法字符
    return label.replace(/[\s\r\n\\/:*?"<>|]/g, '_');
  }
}