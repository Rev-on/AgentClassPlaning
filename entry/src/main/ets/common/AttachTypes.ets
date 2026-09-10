/**
 * 附件数据模型（生成页"图片/文档/拍照"上传功能共用）
 *  - AttachFile：本地待提交附件（图片带 dataURL，文档带解析文本）
 *  - TaskAttachment：提交给服务端的结构，字段与 server/src/server.js normalizeAttachments 对齐
 */
export interface AttachFile {
  /** 本地唯一 id（列表 key 与删除用） */
  id: string;
  /** 文件名（含扩展名） */
  name: string;
  /** 小写扩展名（如 png / jpg / docx / txt） */
  ext: string;
  /** image=图片（走多模态视觉）；text=已解析出文本；file=暂不支持解析的二进制 */
  kind: string;
  /** 字节数（展示用） */
  size: number;
  /** 图片：完整 dataURL（含 mime 前缀）；非图片为空串 */
  dataUrl: string;
  /** 文档：解析出的纯文本；无则空串 */
  text: string;
}

/** 提交给服务端的附件 */
export interface TaskAttachment {
  kind: string;
  name: string;
  data?: string;
  text?: string;
}
