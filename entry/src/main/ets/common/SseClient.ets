/**
 * SSE 客户端（基于 @ohos.net.http.requestInStream 自研封装）
 *  - dataReceive 增量块拼接 -> \n\n 分帧 -> event/data 解析
 *  - UTF-8 增量解码为纯本地实现（ArkUI-X 跨端不支持 util.TextDecoder.decode），
 *    多字节中文字符被网络切分到两个数据块时不会乱码
 *  - 心跳注释行(: ping)自动忽略；服务器关闭时回调 onEnd
 */
import http from '@ohos.net.http';
import { ApiConfig } from './ApiConfig';

/** 解析后的 SSE 事件 */
export interface SseEvent {
  event: string;
  /** data 内容（多行 data: 时以换行拼接；无 data 时为空串） */
  payload: string;
}

/** 事件监听回调 */
export interface SseListener {
  onEvent: (evt: SseEvent) => void;
  /** 服务端主动结束连接（正常 done/error 后由服务端关闭） */
  onEnd: () => void;
  /** 连接建立失败或传输层异常 */
  onError: (msg: string) => void;
}

export class SseClient {
  private req: http.HttpRequest | null = null;
  private buffer: string = '';
  /** 跨数据块保留的 UTF-8 不完整尾部字节（中文 3 字节被 TCP 切分时不乱码） */
  private tail: Uint8Array = new Uint8Array(0);
  private closedFlag: boolean = false;
  private evtName: string = 'message';
  private dataLines: string[] = [];
  private listener: SseListener;

  constructor(listener: SseListener) {
    this.listener = listener;
  }

  /** 打开 SSE 连接（path 以 / 开头）；返回 HTTP 状态码（200 即成功建立） */
  async open(path: string): Promise<number> {
    const headers: Record<string, string> = { 'Accept': 'text/event-stream' };
    if (ApiConfig.PROXY_TOKEN !== '') {
      headers['x-proxy-token'] = ApiConfig.PROXY_TOKEN;
    }
    const req = http.createHttp();
    this.req = req;
    req.on('dataReceive', (data: ArrayBuffer) => {
      this.onData(data);
    });
    req.on('dataEnd', () => {
      this.finish();
    });
    try {
      const code: number = await req.requestInStream(ApiConfig.SERVER_BASE_URL + path, {
        method: http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 10000,
        readTimeout: 600000
      });
      if (code !== 200) {
        this.destroy();
      }
      return code;
    } catch (e) {
      this.destroy();
      const msg: string = e instanceof Error ? e.message : 'SSE 连接失败';
      this.listener.onError(msg);
      return -1;
    }
  }

  private onData(data: ArrayBuffer): void {
    if (this.closedFlag) {
      return;
    }
    const chunk: Uint8Array = new Uint8Array(data);
    if (chunk.length === 0) {
      return;
    }
    // 拼接上一块可能不完整的 UTF-8 尾部字节，先解码完整部分，再保留残余
    const combined: Uint8Array = new Uint8Array(this.tail.length + chunk.length);
    combined.set(this.tail, 0);
    combined.set(chunk, this.tail.length);
    const good: number = SseClient.validUtf8Len(combined);
    try {
      this.buffer += SseClient.decodeUtf8(combined.subarray(0, good));
    } catch (e) {
      // 解码异常忽略该块，避免卡死
    }
    this.tail = combined.subarray(good);
    this.parseBuffer();
  }

  /** 计算可安全解码的字节数：从尾部回扫，若存在跨块的不完整 UTF-8 字符则整体截除 */
  private static validUtf8Len(bytes: Uint8Array): number {
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
        // 该字符不完整：把它的所有字节整体留到下一块
        return bytes.length - (continuations + 1);
      }
      break;
    }
    return bytes.length;
  }

  /**
   * 纯 UTF-8 解码（输入必须是完整字符边界，见 validUtf8Len）。
   * 支持 1~4 字节编码，4 字节（emoji 等增补平面）按代理对输出。
   */
  private static decodeUtf8(bytes: Uint8Array): string {
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
        break; // 不完整（调用方已保证，防御处理）
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

  private parseBuffer(): void {
    for (;;) {
      const idx: number = this.buffer.indexOf('\n\n');
      if (idx < 0) {
        return;
      }
      const block: string = this.buffer.substring(0, idx);
      this.buffer = this.buffer.substring(idx + 2);
      this.parseBlock(block);
    }
  }

  private parseBlock(block: string): void {
    const lines: string[] = block.split('\n');
    for (let i: number = 0; i < lines.length; i++) {
      const ln: string = lines[i];
      if (ln === '') {
        continue;
      }
      if (ln.startsWith(':')) {
        continue; // 注释/心跳行
      }
      if (ln.startsWith('event:')) {
        this.evtName = ln.substring(6).trim();
      } else if (ln.startsWith('data:')) {
        this.dataLines.push(ln.substring(5).trim());
      }
    }
    const name: string = this.evtName;
    const payload: string = this.dataLines.join('\n');
    this.evtName = 'message';
    this.dataLines = [];
    if (name !== 'message' || payload !== '') {
      this.listener.onEvent({ event: name, payload: payload });
    }
  }

  private finish(): void {
    if (this.closedFlag) {
      return;
    }
    this.closedFlag = true;
    if (this.buffer !== '') {
      this.parseBuffer();
    }
    this.destroy();
    this.listener.onEnd();
  }

  /** 主动关闭（调用方在 done/error/cancelled 事件或超时后调用） */
  close(): void {
    if (this.closedFlag) {
      return;
    }
    this.closedFlag = true;
    this.destroy();
  }

  private destroy(): void {
    const req = this.req;
    if (req !== null) {
      try {
        req.off('dataReceive');
        req.off('dataEnd');
        req.destroy();
      } catch (e) {
        // ignore
      }
      this.req = null;
    }
  }
}
