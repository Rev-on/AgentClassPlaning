/**
 * 实况窗 activityId 上报（客户端 → 服务端）。
 *
 * 【为什么需要这个文件】
 *   实况窗由**客户端**用 liveViewManager.startLiveView() 在本地创建（见 LiveView.ets）。
 *   正常路径下客户端自己会在生成结束时调用 stopLiveView() 收尾。
 *   但有一种情况客户端做不到：**生成过程中 App 进程被系统杀掉**（用户切走、
 *   内存回收、手动清理）。此时本地实况窗还挂在状态栏上显示"生成中"，
 *   而创建它的进程已经没了 —— 没有任何人来收尾，实况窗就会一直残留。
 *
 *   解决办法：服务端在后台把任务跑完（任务本身在服务端队列里，不受客户端进程
 *   生死影响）。完成时由服务端调 Push Kit 的 push-type 7 / operation 2
 *   下发"结束实况窗"消息，系统据此关闭那个残留的实况窗。
 *
 * 【关键：服务端怎么知道要关哪一个实况窗】
 *   Push Kit 的结束报文里只有一个 `activityId` 字段用于定位实况窗。
 *   而 SDK 的 `LiveViewResult` **只回 resultCode/message，不含任何 id**
 *   （见 @hms.core.liveview.liveViewManager.d.ts:1416，已核对本地 SDK）。
 *   也就是说 system 不会告诉我们它给实况窗分配了什么标识 ——
 *   **这个 id 必须由 App 自己指定**，并通过 `LiveView.id` 传进去。
 *
 *   官方接入说明也明确了这一点（客户端 view.id 需与服务端 HmPayload.activityId 对应），
 *   故本类负责把这个"业务侧自有的 activityId"连同任务 id 一起告诉服务端，
 *   服务端在任务完成时原样回传。
 *
 * 【失败策略】
 *   上报失败只写日志，绝不抛出、绝不阻塞生成：
 *   实况窗是增强体验，最坏情况只是"进程被杀时实况窗残留"，不影响功能可用性。
 */
import http from '@ohos.net.http';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiConfig } from './ApiConfig';

const DOMAIN = 0x0000;
const TAG = 'LiveViewReport';

/**
 * 实况窗绑定上报体。
 *
 * 显式声明接口是 ArkTS 的硬要求（arkts-no-untyped-obj-literals）：
 * 对象字面量必须对应一个明确声明的 class/interface，不能直接赋给
 * `Record<string, ...>`。
 *
 * totalChars / expectedMinutes 为**可选**：老版本服务端不认这两个字段会被忽略，
 * 新服务端在缺省时退回按类型默认 + 时间兜底，因此**向后兼容**。
 */
interface LiveViewBindBody {
  /** 业务侧自有的实况窗标识（正整数） */
  activityId: number;
  /** 创建实况窗时实际生效的场景名 */
  event: string;
  /** 预期总字符数（跨端进度契约，见 GenProgress.expectedChars） */
  totalChars?: number;
  /** 预期生成时长（分钟）；**不参与百分比计算**，服务端仅记录/诊断 */
  expectedMinutes?: number;
}

export class LiveViewReport {
  /**
   * 把 activityId 绑定到指定任务。
   *
   * @param taskId 服务端任务 id（GenTask.submit 返回）
   * @param activityId 业务侧自有的实况窗标识（LiveView.id，正整数）
   * @param event 创建实况窗时实际生效的场景名（服务端结束报文需与之一致）
   * @param totalChars 预期总字符数（可选）。服务端**不掌握**客户端的
   *        EXPECT_CHARS 表，缺省时它按类型默认表兜底；显式传入后两端用同一套
   *        正文长度形状换算（基线 + ratio^0.85），实测逐点一致。
   *        取值用 GenProgress.expectedChars(kind)（跨端唯一事实来源）。
   * @param expectedMinutes 预期生成时长（分钟，可选）。
   *
   *        ⚠️ 该字段**不参与百分比计算**，服务端仅记录用于诊断。
   *        原因（实测踩到过，务必不要再改回去）：服务端一度按这个值缩放流逝时间
   *        再喂给时间滑轨，而客户端的时间滑轨用的是**绝对流逝时间**配固定时间常数
   *        （RAMP_TAU_MS=45s），从不随类型缩放 —— 于是两端不是同一个钟，
   *        最大偏差 26pp（plan/纯思考/t=150s：服务端 52% vs 客户端 78%）。
   *        方向是服务端落后，因此每次补推都会把进度条**拉回最多 26pp**，
   *        且恰好在"无正文、纯思考"这段最依赖时间滑轨的区间。
   *
   *        结论：跨端对齐以**客户端渐近曲线**为准（见 GenProgress 顶部论证，
   *        渐近是为了不提前显示 95%），服务端去掉一切时间缩放。
   *        因此这里如实上报 GenProgress.expectedMinutes(kind) 即可，
   *        **不要**为了拟合而填凑数值 —— 它已经不参与计算了。
   */
  static async bind(taskId: string, activityId: number, event: string,
    totalChars?: number, expectedMinutes?: number): Promise<void> {
    if (taskId === '' || activityId <= 0) {
      return;
    }
    const body: string = JSON.stringify(
      LiveViewReport.body(activityId, event, totalChars, expectedMinutes));
    const req = http.createHttp();
    try {
      const resp = await req.request(ApiConfig.SERVER_BASE_URL + '/task/' + taskId + '/liveview', {
        method: http.RequestMethod.POST,
        header: LiveViewReport.headers(),
        extraData: body,
        connectTimeout: 10000,
        readTimeout: 10000
      });
      const code: number = resp.responseCode;
      if (code === 200) {
        hilog.info(DOMAIN, TAG,
          '实况窗已绑定任务 taskId=%{public}s activityId=%{public}d event=%{public}s totalChars=%{public}d',
          taskId, activityId, event, totalChars === undefined ? 0 : totalChars);
      } else {
        hilog.warn(DOMAIN, TAG, '绑定失败 http=%{public}d taskId=%{public}s', code, taskId);
      }
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, '绑定异常: %{public}s', err.message === undefined ? String(e) : err.message);
    } finally {
      req.destroy();
    }
  }

  /**
   * 组装上报体。
   *
   * 非正数的 totalChars/expectedMinutes **一律不携带**（而不是带 0）：
   *   服务端把 0 视作"未提供"并退化为时间兜底，显式带 0 与省略对服务端等价；
   *   但省略能让上报体只在有意义时才变长，也便于抓包时一眼看出客户端是否真的
   *   掌握预期长度（排查"两端百分比为何不一致"的关键线索）。
   *
   * 注意：这里必须用**显式声明的接口**，不能写成 `Record<string, number|string>`
   * 的对象字面量 —— ArkTS 会报
   *   arkts-no-untyped-obj-literals:
   *   Object literal must correspond to some explicitly declared class or interface
   * （已实测踩到，编译期直接失败）。
   */
  private static body(activityId: number, event: string,
    totalChars?: number, expectedMinutes?: number): LiveViewBindBody {
    const b: LiveViewBindBody = { activityId: activityId, event: event };
    if (totalChars !== undefined && totalChars > 0) {
      b.totalChars = totalChars;
    }
    if (expectedMinutes !== undefined && expectedMinutes > 0) {
      b.expectedMinutes = expectedMinutes;
    }
    return b;
  }

  private static headers(): Record<string, string> {
    const h: Record<string, string> = { 'Content-Type': 'application/json' };
    if (ApiConfig.PROXY_TOKEN !== '') {
      h['x-proxy-token'] = ApiConfig.PROXY_TOKEN;
    }
    return h;
  }
}
