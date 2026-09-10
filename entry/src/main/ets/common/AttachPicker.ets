/**
 * 附件选择器（HarmonyOS 实现）
 *  - pickImages：@kit.CoreFileKit 的 picker.PhotoViewPicker（相册多选）
 *  - pickDocs：picker.DocumentViewPicker（文档多选）
 *  - takePhoto：cameraPicker 调起系统相机拍照（拍完返回图片 uri）
 * Android 侧为同名文件（ArkUI-X 无相机插件，拍照降级为相册单选），公开 API 完全一致。
 */
import { picker } from '@kit.CoreFileKit';
import cameraPicker from '@ohos.multimedia.cameraPicker';
import { camera } from '@kit.CameraKit';
import common from '@ohos.app.ability.common';

/** 选择结果（原始 uri + 展示用文件名） */
export interface PickedItem {
  name: string;
  uri: string;
}

export class AttachPicker {
  /** 从 uri 推断文件名（无扩展名时按类型补默认名） */
  static nameFromUri(uri: string, fallbackPrefix: string, fallbackExt: string): string {
    let path: string = uri;
    const q: number = path.indexOf('?');
    if (q >= 0) {
      path = path.substring(0, q);
    }
    let name: string = '';
    const slash: number = path.lastIndexOf('/');
    if (slash >= 0) {
      name = path.substring(slash + 1);
    }
    if (name === '' || name.indexOf('.') < 0) {
      return fallbackPrefix + '_' + Date.now() + '.' + fallbackExt;
    }
    return decodeURIComponent(name);
  }

  /** 相册选图（最多 max 张） */
  static async pickImages(max: number): Promise<PickedItem[]> {
    const p = new picker.PhotoViewPicker();
    const opt: picker.PhotoSelectOptions = {
      MIMEType: picker.PhotoViewMIMETypes.IMAGE_TYPE,
      maxSelectNumber: max
    };
    const res: picker.PhotoSelectResult = await p.select(opt);
    const items: PickedItem[] = [];
    const uris: string[] = res.photoUris;
    for (let i: number = 0; i < uris.length; i++) {
      items.push({ name: AttachPicker.nameFromUri(uris[i], 'IMG', 'jpg'), uri: uris[i] });
    }
    return items;
  }

  /** 选择文档（最多 max 个） */
  static async pickDocs(max: number): Promise<PickedItem[]> {
    const p = new picker.DocumentViewPicker();
    const opt: picker.DocumentSelectOptions = { maxSelectNumber: max };
    const uris: string[] = await p.select(opt);
    const items: PickedItem[] = [];
    for (let i: number = 0; i < uris.length; i++) {
      items.push({ name: AttachPicker.nameFromUri(uris[i], 'FILE', 'dat'), uri: uris[i] });
    }
    return items;
  }

  /** 调起系统相机拍照（拍照后由系统保存为图片并返回 uri） */
  static async takePhoto(ctx: common.UIAbilityContext): Promise<PickedItem[]> {
    const profile: cameraPicker.PickerProfile = {
      cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK
    };
    const r: cameraPicker.PickerResult = await cameraPicker.pick(ctx, [cameraPicker.PickerMediaType.PHOTO], profile);
    if (r.resultCode !== 0 || r.resultUri === undefined || r.resultUri === '') {
      return [];
    }
    return [{ name: AttachPicker.nameFromUri(r.resultUri, 'IMG', 'jpg'), uri: r.resultUri }];
  }
}
