/**
 * 页面结果草稿（文件落盘）
 *
 * 用途：把每个生成页最后一次的结果（富文本 HTML）写入应用沙箱文件，
 * 在"会话状态异常/页面被销毁/进程被杀"等情况下重进页面仍能恢复预览，
 * 彻底避免"底部预览框凭空消失"。
 * 说明：用文件而非 preferences（preferences 的字符串值有 8KB 上限，长教案会写失败）。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import common from '@ohos.app.ability.common';
import { Utf8 } from './Utf8';

export class PageDraft {
  private static path(ctx: common.UIAbilityContext, key: string): string {
    return ctx.filesDir + '/draft_' + key + '.html';
  }

  /** 保存草稿（同步，失败静默） */
  static save(ctx: common.UIAbilityContext, key: string, text: string): void {
    if (key === '' || text === '') {
      return;
    }
    try {
      const f = fs.openSync(PageDraft.path(ctx, key),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, text);
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      // 忽略：草稿失败不影响主流程
    }
  }

  /** 读取草稿（无草稿返回空串） */
  static load(ctx: common.UIAbilityContext, key: string): string {
    if (key === '') {
      return '';
    }
    try {
      const f = fs.openSync(PageDraft.path(ctx, key), fs.OpenMode.READ_ONLY);
      try {
        const st = fs.statSync(f.fd);
        if (st.size <= 0) {
          return '';
        }
        const buf = new ArrayBuffer(st.size);
        fs.readSync(f.fd, buf);
        return Utf8.decode(new Uint8Array(buf));
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      return '';
    }
  }

  /** 清除草稿（开始新的生成时调用，避免旧结果回魂） */
  static clear(ctx: common.UIAbilityContext, key: string): void {
    if (key === '') {
      return;
    }
    try {
      fs.unlink(PageDraft.path(ctx, key));
    } catch (e) {
      // 文件不存在等情况忽略
    }
  }
}
