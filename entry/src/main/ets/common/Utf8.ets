/**
 * 纯 UTF-8 编解码工具（跨端安全）
 *
 * 背景：ArkUI-X(Android) 跨端编译不支持 util.TextDecoder.decode，
 * 因此附件文档文本读取使用本文件的纯实现；
 * （SSE 客户端 SseClient 内置了同算法的增量解码，避免改动已验证的流式链路）
 */
export class Utf8 {
  /**
   * 计算可安全解码的字节数：从尾部回扫，若存在跨块的不完整 UTF-8 字符则整体截除。
   * 用于增量流式解码（中文 3 字节被 TCP 切分时不乱码）。
   */
  static validLen(bytes: Uint8Array): number {
    if (bytes.length === 0) {
      return 0;
    }
    let continuations: number = 0;
    for (let i: number = bytes.length - 1; i >= 0; i--) {
      const b: number = bytes[i];
      if ((b & 0xC0) === 0x80) {
        continuations++;
        continue;
      }
      let total: number = 0;
      if ((b & 0xE0) === 0xC0) {
        total = 2;
      } else if ((b & 0xF0) === 0xE0) {
        total = 3;
      } else if ((b & 0xF8) === 0xF0) {
        total = 4;
      } else {
        break; // ASCII 或损坏字节：其后不存在未闭合序列
      }
      if (continuations < total - 1) {
        return bytes.length - (continuations + 1);
      }
      break;
    }
    return bytes.length;
  }

  /**
   * UTF-8 解码（输入应为完整字符边界；支持 1~4 字节，4 字节按代理对输出）。
   * @param bytes 原始字节
   * @param strict 为 true 时遇到不完整序列直接停止（用于整段文件读取，默认 false 会跳过非法字节）
   */
  static decode(bytes: Uint8Array): string {
    let out: string = '';
    let i: number = 0;
    const n: number = bytes.length;
    while (i < n) {
      const b: number = bytes[i];
      let cp: number = 0;
      let len: number = 1;
      if (b < 0x80) {
        cp = b;
        len = 1;
      } else if ((b & 0xE0) === 0xC0) {
        cp = b & 0x1F;
        len = 2;
      } else if ((b & 0xF0) === 0xE0) {
        cp = b & 0x0F;
        len = 3;
      } else if ((b & 0xF8) === 0xF0) {
        cp = b & 0x07;
        len = 4;
      } else {
        i++;
        continue; // 非法字节：跳过
      }
      if (i + len > n) {
        break; // 结尾不完整：直接结束
      }
      for (let j: number = 1; j < len; j++) {
        cp = (cp << 6) | (bytes[i + j] & 0x3F);
      }
      i += len;
      if (cp > 0xFFFF && cp <= 0x10FFFF) {
        const v: number = cp - 0x10000;
        out += String.fromCharCode(0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF));
      } else {
        out += String.fromCharCode(cp);
      }
    }
    return out;
  }
}
