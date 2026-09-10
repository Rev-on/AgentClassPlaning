/**
 * 附件编解码（HarmonyOS 实现）
 *  - readBytes：读取 picker/相机返回的文件（fileIo）
 *  - toBase64：纯实现 base64（跨端安全，不依赖 util.Base64Helper）
 *  - imageToDataUrl：图片压缩为 JPEG dataURL（长边 ≤1600、质量 78），失败回退原图
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { Utf8 } from './Utf8';

export class AttachCodec {
  /** 生成附件 id */
  static newId(): string {
    return 'a' + Date.now().toString(36) + Math.floor(Math.random() * 46656).toString(36);
  }

  /** 读取文件字节 */
  static readBytes(uri: string): Uint8Array {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(file.fd);
      const buffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      return new Uint8Array(buffer);
    } finally {
      try {
        fs.closeSync(file);
      } catch (e) {
        // ignore
      }
    }
  }

  /** 字节 -> base64（纯实现，避免跨端 API 限制） */
  static toBase64(bytes: Uint8Array): string {
    const table: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let out: string = '';
    let i: number = 0;
    const n: number = bytes.length;
    while (i + 2 < n) {
      const b0: number = bytes[i];
      const b1: number = bytes[i + 1];
      const b2: number = bytes[i + 2];
      out += table.charAt(b0 >> 2);
      out += table.charAt(((b0 & 0x03) << 4) | (b1 >> 4));
      out += table.charAt(((b1 & 0x0F) << 2) | (b2 >> 6));
      out += table.charAt(b2 & 0x3F);
      i += 3;
    }
    if (i < n) {
      const b0: number = bytes[i];
      out += table.charAt(b0 >> 2);
      if (i + 1 < n) {
        const b1: number = bytes[i + 1];
        out += table.charAt(((b0 & 0x03) << 4) | (b1 >> 4));
        out += table.charAt((b1 & 0x0F) << 2);
      } else {
        out += table.charAt((b0 & 0x03) << 4);
        out += '=';
      }
      out += '=';
    }
    return out;
  }

  /** 扩展名 -> MIME */
  static mimeOf(ext: string): string {
    if (ext === 'png') {
      return 'image/png';
    }
    if (ext === 'webp') {
      return 'image/webp';
    }
    if (ext === 'bmp') {
      return 'image/bmp';
    }
    if (ext === 'gif') {
      return 'image/gif';
    }
    if (ext === 'heic' || ext === 'heif') {
      return 'image/heic';
    }
    return 'image/jpeg';
  }

  /** 图片 -> dataURL（默认压缩为 JPEG，失败回退原始字节） */
  static async imageToDataUrl(uri: string, ext: string): Promise<string> {
    try {
      const src = image.createImageSource(uri);
      const info = await src.getImageInfo();
      const w: number = info.size.width;
      const h: number = info.size.height;
      const max: number = 1600;
      let tw: number = w;
      let th: number = h;
      const long: number = w > h ? w : h;
      if (long > max) {
        const scale: number = max / long;
        tw = Math.round(w * scale);
        th = Math.round(h * scale);
      }
      const dec: image.DecodingOptions = { desiredSize: { width: tw, height: th } };
      const pm: image.PixelMap = await src.createPixelMap(dec);
      const packer: image.ImagePacker = image.createImagePacker();
      const pk: image.PackingOption = { format: 'image/jpeg', quality: 78 };
      const ab: ArrayBuffer = await packer.packToData(pm, pk);
      try {
        packer.release();
      } catch (e) {
        // ignore
      }
      try {
        pm.release();
      } catch (e) {
        // ignore
      }
      try {
        src.release();
      } catch (e) {
        // ignore
      }
      return 'data:image/jpeg;base64,' + AttachCodec.toBase64(new Uint8Array(ab));
    } catch (e) {
      const raw: Uint8Array = AttachCodec.readBytes(uri);
      return 'data:' + AttachCodec.mimeOf(ext) + ';base64,' + AttachCodec.toBase64(raw);
    }
  }

  /** 文档文本（供 AttachDoc 使用时的统一入口，便于后续替换实现） */
  static readText(uri: string): string {
    return Utf8.decode(AttachCodec.readBytes(uri));
  }

  /** 字节数 -> 人类可读 */
  static humanSize(size: number): string {
    if (size < 1024) {
      return size + 'B';
    }
    if (size < 1024 * 1024) {
      return (size / 1024).toFixed(0) + 'KB';
    }
    return (size / 1024 / 1024).toFixed(1) + 'MB';
  }
}
