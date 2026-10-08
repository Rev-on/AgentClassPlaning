/**
 * 沟通话术建议：老师描述家校沟通困难，AI 生成得体话术与避坑提示（双语界面 + 深浅主题）
 * 说明：下拉选项按界面语言显示中/英；发送给 AI 的字段值保留中文，便于生成内容
 */
import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import { AiService } from '../common/AiService';
import { GenSession, GenSessionState } from '../common/GenSession';
import { PageDraft } from '../common/PageDraft';
import { Prompts } from '../common/Prompts';
import { HistoryStore } from '../common/HistoryStore';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AppFonts } from '../common/AppFonts';
import { AttachBar } from '../common/components/AttachBar';
import { VoiceRemarkBox } from '../common/components/VoiceRemarkBox';
import { ThinkSwitch, ThinkPanel } from '../common/components/ThinkPanel';
import { AppSettings } from '../common/AppSettings';
import { AttachFile } from '../common/AttachTypes';
import { PageHeader } from '../common/components/PageHeader';
import { ResultPanel } from '../common/components/ResultPanel';
import { RichBox } from '../common/components/RichBox';
import { RichHtml } from '../common/RichHtml';
import { SafeInsets } from '../common/SafeInsets';
import { LiveView } from '../common/LiveView';
import { StreamThrottle } from '../common/StreamThrottle';
import { NameMask, NameMaskSession, MaskError } from '../common/NameMask';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 完成后定位到结果顶部时预留的内边距（vp）：让预览顶部操作按钮完整露出 */
const ResultTopPadding: number = 12;

@Component
export struct TalkContent {
  private sceneZh: string[] = ['学习退步沟通', '课堂表现反馈', '作业问题沟通', '考试后安抚', '家长会发言'];
  private toneZh: string[] = ['温和沟通', '正式规范', '激励引导'];

  @State sceneIndex: number = 0;
  @State toneIndex: number = 0;
  @State situation: string = I18n.t('def.situation');
  /**
   * 学生姓名（**可选**输入框）。
   *
   * 【为什么要有这个字段】本页的"学生情况描述"是自由文本，老师会手写姓名。
   * 我们刻意**不做"2-4 个连续汉字就是姓名"的启发式猜测** —— 那会把
   * "成绩下滑""家长会""单元测试"整片误改成编号，AI 收到的语义直接废掉。
   * 因此策略是：
   *   · 该输入框：老师填写姓名后，本页**确知**它是姓名，必被编号替换；
   *   · 描述自由文本：只在"确知姓名"的范围内替换（含本框的值），
   *     以及姓名由姓氏字库 + 常见后续字/双字名组合识别出的高置信候选
   *     （见 maskSituation 的注释）。留空也能用。
   */
  @State studentName: string = '';
  @State remark: string = '';
  /** 附件（图片/文档/拍照），随生成请求一起提交 */
  @State attachFiles: AttachFile[] = [];
  @State loading: boolean = false;
  /** 深度思考过程全文（开启深度思考生成时实时更新；空表示本次未产生思考过程） */
  @State thinkText: string = '';
  /** 思考过程是否展开（生成中展开实时滚动，生成完成后自动折叠，点击标题可再次展开） */
  @State thinkExpanded: boolean = true;
  @State thinkRunning: boolean = false;
  /**
   * 本次生成是否预期产生思考过程（生成时按"深度思考"开关置位）。
   * 思考框的显示条件用它而非 thinkText !== ''，保证：
   *  - 开关开启时，点击生成立刻出现思考框（占位"正在思考…"），不会因思考增量晚到而缺失；
   *  - 开关关闭（快速模式）时不显示，避免每次生成都闪一个空框。
   */
  @State thinkExpected: boolean = false;
  @State result: string = '';
  /**
   * 流式渲染节流：SSE 分片率远高于屏幕刷新率，
   * 直接每次赋值会触发大量无谓 rebuild（分片落在同一帧内纯属白做）。
   * 这里按固定间隔合并提交最新文本，结束时 flush 保证最终内容不丢。
   */
  private resultThrottle: StreamThrottle = new StreamThrottle((v: string): void => {
    this.result = v;
  });
  /** 生成会话恢复（离开页面后重进仍显示生成中/结果） */
  private sessSub: number = -1;
  /** 实时预览滚动控制器（生成中自动滚到最底部） */
  private liveScroll: Scroller = new Scroller();
  /** 完成后整页滚动控制器（自动下滑到结果预览） */
  private doneScroll: Scroller = new Scroller();
  /** 结果预览在整页滚动内容中的顶部偏移（用于完成后自动定位） */
  private resultTop: number = 0;
  /** 滚动内容容器的屏幕 Y 坐标（onAreaChange 记录，用于把绝对值换算成相对偏移） */
  private scrollContentTop: number = 0;
  /** 结果面板的屏幕 Y 坐标（onAreaChange 记录） */
  private resultAbsTop: number = 0;

  /** 由两个屏幕绝对坐标求「结果面板在滚动内容内的相对偏移」 */
  private computeResultOffset(): number {
    const rel: number = this.resultAbsTop - this.scrollContentTop;
    return rel > 0 ? rel : 0;
  }
  /** 用户是否点击了"停止生成" */
  private stopRequested: boolean = false;

  aboutToAppear(): void {
    // 读取顶部状态栏/刘海避让高度：整页滚动时预留顶部安全区
    SafeInsets.topInset(getContext(this) as common.UIAbilityContext).then((v: number): void => {
      this.topInset = v;
    });
    this.resumeGenSession();
  }

  aboutToDisappear(): void {
    // 离开页面前把当前结果留存到生成会话：再次进入可恢复（编辑界面左滑退出同样不丢）
    if (!this.loading && this.result !== '') {
      GenSession.end(this.genKey(), this.result);
      // 本地草稿兜底：异常退出/进程被杀后重进仍可恢复
      PageDraft.save(getContext(this) as common.UIAbilityContext, this.genKey(), this.result);
    }
    this.leaveGenSession();
        
  }

  private resumeGenSession(): void {
    const cur: GenSessionState | undefined = GenSession.stateOf(this.genKey());
    if (cur !== undefined) {
      if (cur.phase === 'busy' && this.result === '') {
        this.loading = true;
      } else if (cur.phase === 'done' && cur.text !== '' && this.result === '') {
        this.result = cur.text;
        this.loading = false;
      }
    }
    this.sessSub = GenSession.subscribe(this.genKey(), (s: GenSessionState): void => {
      if (s.phase === 'busy') {
        if (this.result === '') {
          this.loading = true;
        }
      } else if (s.phase === 'done') {
        // 仅在有内容时回写：避免异常空结果把已显示的预览清空
        if (s.text !== '') {
          this.result = s.text;
        }
        this.loading = false;
      } else {
        this.loading = false;
      }
    });

    // 会话无内容时回退到本地草稿：即使异常退出/进程被杀，重进也能恢复预览
    if (this.result === '') {
      const draft: string = PageDraft.load(getContext(this) as common.UIAbilityContext, this.genKey());
      if (draft !== '') {
        this.result = draft;
      }
    }
  }

  private leaveGenSession(): void {
    if (this.sessSub >= 0) {
      GenSession.unsubscribe(this.genKey(), this.sessSub);
      this.sessSub = -1;
    }
  }

  private genKey(): string {
    return 'talk';
  }
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  /** 2in1 独立页面（IndexWideDuo 下半屏）渲染时由壳传入 true：本组件不内嵌结果区 */
  bottomResult: boolean = false;
  /** 顶部状态栏/刘海避让高度（vp）：整页滚动时预留顶部安全区 */
  @State topInset: number = 0;

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  /** 界面显示的沟通场景选项（按界面语言取词典，talk.s1..s5） */
  private sceneOptions(): SelectOption[] {
    const opts: SelectOption[] = [];
    for (let i = 0; i < this.sceneZh.length; i++) {
      const opt: SelectOption = { value: this.t('talk.s' + (i + 1)) };
      opts.push(opt);
    }
    return opts;
  }

  /** 界面显示的语气选项（按界面语言取词典，talk.t1..t3） */
  private toneOptions(): SelectOption[] {
    const opts: SelectOption[] = [];
    for (let i = 0; i < this.toneZh.length; i++) {
      const opt: SelectOption = { value: this.t('talk.t' + (i + 1)) };
      opts.push(opt);
    }
    return opts;
  }

  /** 当前场景的界面显示文本 */
  private sceneLabel(): string {
    return this.t('talk.s' + (this.sceneIndex + 1));
  }

  /** 当前语气的界面显示文本 */
  private toneLabel(): string {
    return this.t('talk.t' + (this.toneIndex + 1));
  }

  /** 发送给 AI 的沟通场景（保留中文） */
  private scene(): string {
    return this.sceneZh[this.sceneIndex];
  }

  /** 发送给 AI 的期望语气（保留中文） */
  private tone(): string {
    return this.toneZh[this.toneIndex];
  }

  /**
   * 【隐私】把"学生情况描述"里的学生姓名替换为编号。
   *
   * 设计原则：**结构是有方向性的**，用错了方向就会把正文改成残句。
   * 下面两条通道各自绑定一种"肯定无歧义"的语法结构，其余一律不猜：
   *   通道① 字段标签 + 分隔符 + 值：`学生姓名：张三` —— 值在标签**后面**；
   *   通道② 人名 + 称谓：`张三同学`、`王小明妈妈` —— 人名在称谓**前面**。
   *
   * ------------------------------------------------------------------
   * 【曾经踩过的坑：把"称谓词"当成"字段标签"用】
   *   旧实现把 '学生'、'孩子' 放进了 labels，并用 nameAfterLabel 抓"标签后的汉字"。
   *   可 '学生'/'孩子' 是**称谓词**而非字段标签，句中到处都有，于是：
   *       原文：孩子最近情绪低落，需要家访。
   *       外发：孩子S001低落，需要家访。            ← 把"最近"当成了人名
   *       原文：学生姓名：李四，数学成绩下滑明显。
   *       外发：学生S002：S001，数学成绩下滑明显。    ← '学生' 抢在 '学生姓名' 之前命中，
   *                                                      把"姓名"当成了人名
   *   这类**误改比漏脱敏更糟**：漏脱敏只是隐私风险；误改是把错误、残缺的数据喂给 AI，
   *   生成结论直接失真，且还原后与老师原文对不上。
   *   因此现在：labels **只留真正的字段标签**（学生姓名/姓名/名字）；称谓词改走通道②。
   *
   * ------------------------------------------------------------------
   * 【通道② 的边界规则：为什么"家长会""家访"不会被误伤】
   *   称谓词本身有歧义 —— '家长' 在"家长会"里不是称谓。命中需三条同时成立：
   *     a) 称谓**前面**紧跟 2-4 个汉字（这段才是候选人名）；
   *     b) 候选人名前不紧邻虚词（的/和/与/给/对/跟…），排除"学校的同学"这类名词短语；
   *     c) 称谓**后面**不紧跟常见后续字（会/访/们/长/里…），排除"家长会"被拆成 家长+会。
   *   例：
   *     "王小明妈妈反映…" → 前有"王小明"✓、前无虚词✓、'妈妈'后是"反"✓ → 登记「王小明」
   *     "家长会需要沟通"   → '家长'后紧跟"会" ✗ → 放弃（整句逐字不变）
   *     "需要家访"         → "家访"里根本没有 '家长' 这个子串 → 天然不命中
   *   取舍："宁可漏、不可错" —— 漏了可以靠上方「学生姓名」输入框兜住；改错了无从补救。
   */
  private maskSituation(mask: NameMaskSession): string {
    const src: string = this.situation;
    // 通道①：真正的字段标签（"标签 + 分隔符 + 值"），长标签排前面
    const labels: string[] = ['学生姓名', '姓名', '名字'];
    for (let i: number = 0; i < labels.length; i++) {
      mask.registerAll(TalkContent.nameAfterLabel(src, labels[i]));
    }
    // 通道②：人名 + 称谓（人名在前），带后界裁剪避免"家长会"被拆开
    const roles: string[] = ['同学', '小朋友',
      '的妈妈', '的爸爸', '的母亲', '的父亲', '的家长', '的奶奶', '的爷爷',
      '妈妈', '爸爸', '母亲', '父亲', '家长', '奶奶', '爷爷'];
    for (let i: number = 0; i < roles.length; i++) {
      mask.registerAll(TalkContent.nameBefore(src, roles[i], 4));
    }
    // ③ 已知姓名（输入框 + 上面两路）全量替换，确保一个都不剩
    return mask.maskFreeText(src, true);
  }

  /**
   * 抓取「称谓前的人名」：在 text 中找到 role 前紧跟的 2-4 个汉字。
   * 例：role='同学'，"张三同学" → '张三'；role='妈妈'，"王小明妈妈" → '王小明'。
   *
   * 三重边界裁剪（缺一不可，理由见 maskSituation 的【通道②】）：
   *   a) 候选必须 2-4 个汉字（单字不成名）；
   *   b) 候选前不紧邻虚词 —— "学校的同学"里的"学校"不是人名；
   *   c) 称谓后不紧跟常见后续字 —— "家长会""妈妈们"里的称谓只是构词成分。
   *
   * 另有一条**去领属"的"**的归一化（d），理由见下方注释。
   */
  private static nameBefore(text: string, role: string, maxLen: number): string[] {
    const out: string[] = [];
    let from: number = 0;
    let idx: number = text.indexOf(role, from);
    while (idx >= 0) {
      // (c) 称谓后紧跟常见后续字 → 该 role 是构词成分，不构成称谓结构
      const after: string = text.substring(idx + role.length, idx + role.length + 1);
      if (!TalkContent.isRoleSuffix(after)) {
        const prefix: string = text.substring(0, idx);
        // (d) 去掉候选尾部的领属助词"的"：
        //     roles 里同时存在带"的"（'的妈妈'）与不带"的"（'妈妈'）两种写法，
        //     于是 "李四的妈妈希望…" 会命中两次：
        //       · role='的妈妈' @2 → 候选 "李四"      ✓ 正确
        //       · role='妈妈'  @3 → 候选 "李四的"     ✗ 多出一条脏数据
        //     结果编号表里同时登记 "李四" 与 "李四的"，而 "李四的" 并不是姓名。
        //     这里统一剥掉尾部的"的"，两条路径归一化到同一个候选 "李四"，
        //     NameMask.register 去重后只占一个编号（不影响隐私安全，但编号表更干净，
        //     也避免 "李四的"→编号 的替换把正文里的"李四的"改成 "S001的"这种畸形结果）。
        //     注：中文姓名不含"的"，剥离不会伤到真实姓名。
        let cand: string = TalkContent.tailHan(prefix, maxLen);
        while (cand.length >= 2 && cand.charAt(cand.length - 1) === '的') {
          cand = cand.substring(0, cand.length - 1);
        }
        // (a) 候选 2-4 字  (b) 前不紧邻虚词  (a') 候选本身不是称谓/动词等常见词
        if (cand.length >= 2 &&
          !TalkContent.endsWithFunctionWord(prefix.substring(0, prefix.length - cand.length)) &&
          !TalkContent.isStopWord(cand)) {
          out.push(cand);
        }
      }
      from = idx + role.length;
      idx = text.indexOf(role, from);
    }
    return out;
  }

  /**
   * 称谓后是否紧跟"常见后续字" —— 是则该称谓只是构词成分，不构成称谓结构。
   * 例：家长+会、家长+访、妈妈+们、父亲+节。
   */
  private static isRoleSuffix(ch: string): boolean {
    if (ch === '') {
      return false;
    }
    return '会访们长里节日的和与或等些个人话'.indexOf(ch) >= 0;
  }

  /**
   * 候选词是否是常见词（显然不是人名）。
   * 拦住"妈妈说""家长反映"这类：称谓前紧跟的还是称谓/动词，不可能是姓名。
   */
  private static isStopWord(cand: string): boolean {
    const stop: string[] = ['妈妈', '爸爸', '母亲', '父亲', '家长', '奶奶', '爷爷',
      '孩子', '学生', '同学', '老师', '反映', '需要', '觉得', '认为', '表示', '说到'];
    for (let i: number = 0; i < stop.length; i++) {
      if (cand === stop[i]) {
        return true;
      }
    }
    return false;
  }

  /**
   * 抓取「标签后的人名」：标签 + 分隔符（：: 是 叫 为 等）之后紧跟的 2-4 个汉字。
   * 例：'学生姓名：张三，' → '张三'。
   */
  private static nameAfterLabel(text: string, label: string): string[] {
    const out: string[] = [];
    const seps: string[] = ['：', ':', '是', '叫', '为', '＝', '='];
    let from: number = 0;
    let idx: number = text.indexOf(label, from);
    while (idx >= 0) {
      let p: number = idx + label.length;
      // 允许标签与分隔符之间夹一个"是/叫"
      if (p < text.length && TalkContent.isHan(text.charAt(p)) && TalkContent.isSep(text.charAt(p))) {
        p = p + 1;
      }
      while (p < text.length && TalkContent.isSep(text.charAt(p))) {
        p = p + 1;
      }
      const cand: string = TalkContent.headHan(text.substring(p), 4);
      if (cand.length >= 2) {
        out.push(cand);
      }
      from = idx + label.length;
      idx = text.indexOf(label, from);
    }
    return out;
  }

  /** 取串尾连续的 1..maxLen 个汉字（不足则返回全部可取的汉字） */
  private static tailHan(text: string, maxLen: number): string {
    let end: number = text.length;
    let start: number = end;
    while (start > 0 && end - start < maxLen && TalkContent.isHan(text.charAt(start - 1))) {
      start = start - 1;
    }
    return text.substring(start, end);
  }

  /** 取串首连续的 1..maxLen 个汉字 */
  private static headHan(text: string, maxLen: number): string {
    let end: number = 0;
    while (end < text.length && end < maxLen && TalkContent.isHan(text.charAt(end))) {
      end = end + 1;
    }
    return text.substring(0, end);
  }

  /** 是否汉字（U+4E00–U+9FFF，够用于中文姓名判定） */
  private static isHan(ch: string): boolean {
    const c: number = ch.charCodeAt(0);
    return c >= 0x4E00 && c <= 0x9FFF;
  }

  /** 是否是姓名分隔符（标签与值之间的连接符） */
  private static isSep(ch: string): boolean {
    return ch === '：' || ch === ':' || ch === '=' || ch === '＝' || ch === ' ' || ch === '\u3000';
  }

  /**
   * 人名候选前是否紧邻虚词（的/和/与/、/给/对/跟/是）——是则大概率不是姓名，
   * 例如"学校的同学"里 role='同学' 前是"学校"，但再往前的"的"说明"学校"是名词。
   */
  private static endsWithFunctionWord(prefix: string): boolean {
    if (prefix.length === 0) {
      return false;
    }
    const last: string = prefix.charAt(prefix.length - 1);
    return '的与和、给对跟同被把是在有'.indexOf(last) >= 0;
  }

  async generate(): Promise<void> {
    if (this.situation.trim() === '') {
      promptAction.showToast({ message: this.t('err.noSituation') });
      return;
    }
    this.stopRequested = false;
    this.loading = true;
    this.result = '';
    // 深度思考：清空上一次的思考过程并展开（生成中实时滚动展示）
    this.thinkText = '';
    this.thinkExpanded = true;
    this.thinkRunning = true;
    // 本次生成是否预期产生思考过程（按开关决定）：用于让思考框立即出现，
    // 避免思考增量晚于正文首块到达时思考框整个不显示。
    this.thinkExpected = AppStorage.get<boolean>(AppSettings.KEY_THINK) === true;
    // 开始新的生成：清除旧草稿，避免旧结果回魂
    PageDraft.clear(getContext(this) as common.UIAbilityContext, this.genKey());
    // 实况窗：生成开始即创建，之后随进度更新百分比（失败静默，不影响生成）
    LiveView.start('talk', this.t('page.talk')).catch((e: Error) => {
      hilog.warn(0x0000, 'Talk', 'LiveView.start 异常: %{public}s', e.message);
    });
    const remarkPart: string = this.remark.trim() !== '' ? '\n【备注】' + this.remark.trim() : '';
    /**
     * 【隐私】本页没有"学生姓名"输入框，姓名只可能以两种形式出现：
     *   ① 学生姓名 = 直接写名字（"张三最近上课走神…"）—— 自动识别为姓名并编号；
     *   ② 学生姓名（可选）= 老师显式填写的真实姓名（有输入框兜底，避免"高兴"这类
     *      姓名恰好是常见词时被漏掉）。两者都登记进本次会话后，描述/备注里的
     *      这些名字会被替换为编号再外发。
     * 映射表只在本次生成的内存里（见 NameMask 文件头），结束即丢。
     */
    const mask: NameMaskSession = NameMask.session();
    const explicitName: string = NameMask.maskStructured(mask, this.studentName);
    const situationMasked: string = this.maskSituation(mask);
    const remarkMasked: string = NameMask.maskFreeText(mask, this.remark);
    // 姓名 → 编号，用于给 AI 一句"描述里提到的学生用这个编号"，避免它把编号当成无关代号
    const nameHint: string = explicitName !== ''
      ? `（描述中提到的学生 ${explicitName} 即此处所指学生）` : '';
    const remarkOut: string = remarkMasked.trim() !== '' ? '\n【备注】' + remarkMasked.trim() : '';
    const user: string = `沟通场景：${this.scene()}\n学生情况描述：${situationMasked}${nameHint}\n期望语气：${this.tone()}\n\n请生成沟通话术建议。${remarkOut}`;
    /**
     * 【隐私 fail-closed】出网前最后一道闸：prompt 里只要还残留任何已知真实姓名就抛错阻断。
     * 同时把"已经流式提交到界面上的半截文本"整体还原成真名版本：
     *   AI 正文里出现的编号（描述里的姓名已被换成编号）在界面上应以真名显示，
     *   且**必须整体还原** —— 编号在流式过程中可能被 token 切成 "S0" + "01"，
     *   逐片还原会漏掉半个编号（详见 NameMask 文件头"流式还原的坑"）。
     */
    let streamToShow: string = '';
    try {
      streamToShow = NameMask.applyToFlow(mask, Prompts.talkSystem(), user, this.result);
    } catch (e) {
      const me: MaskError = e as MaskError;
      hilog.error(0x0000, 'Talk', '脱敏校验未通过，已阻断外发: %{public}s', me.code);
      this.loading = false;
      this.thinkRunning = false;
      this.thinkExpected = false;
      LiveView.done().catch((er: Error) => {
        hilog.warn(0x0000, 'Talk', 'LiveView.done 异常: %{public}s', er.message);
      });
      promptAction.showToast({ message: this.t('err.maskFail') });
      return;
    }
    if (streamToShow !== '') {
      this.resultThrottle.push(streamToShow);
    }
    try {
      const content: string = await AiService.chat(Prompts.talkSystem(), user, (partial: string) => {
        if (this.thinkRunning) {
          // 第一个正文字块到达＝思考阶段完成、正文开始输出：此刻折叠思考框
          this.thinkRunning = false;
          this.thinkExpanded = false;
        }
        // 【流式还原的坑】partial 是累计全文，但任意前缀都可能在编号中间被切断
        // （"…S0" + "01…"）。故流式期间不还原，只展示编号；
        // 生成结束后对最终完整文本还原一次，并用还原结果覆盖流式文本。
        this.resultThrottle.push(partial);
        // 实况窗：随正文进度更新百分比
        LiveView.onContent(partial).catch((e: Error) => {
          hilog.warn(0x0000, 'Talk', 'LiveView.onContent 异常: %{public}s', e.message);
        });
        this.scrollLiveToBottom();
      }, false, {
        ctx: getContext(this) as common.UIAbilityContext,
        type: 'talk',
        label: I18n.t('page.talk'),
        attachments: this.attachFiles,
        // 深度思考：按当前开关决定本次是否使用思考模式（默认关闭＝快速模式）
        thinking: AppStorage.get<boolean>(AppSettings.KEY_THINK) === true
      }, (think: string): void => {
        // 思考过程实时更新（服务端按"当前全文"语义回传，直接覆盖即可）
        this.thinkText = think;
        // 实况窗：思考阶段推进基准进度
        LiveView.onThinking().catch((e: Error) => {
          hilog.warn(0x0000, 'Talk', 'LiveView.onThinking 异常: %{public}s', e.message);
        });
      });
      if (this.stopRequested) {
        // 用户主动停止：保留已生成的部分文本，不覆盖、不入历史
        this.stopRequested = false;
        // 停止时把节流中最后一片补上，避免末尾内容缺失
        this.resultThrottle.flush();
        // 停止时手上的也是"最终可获得文本"：整体还原一次，用户看到真名版本
        this.result = mask.restore(this.result);
        return;
      }
      // 【结果还原】最终完整文本一次还原：展示/导出/存历史/草稿全部使用真名版本
      const shown: string = mask.restore(content);
      this.result = shown;
      this.autoSaveHistory(shown);
      PageDraft.save(getContext(this) as common.UIAbilityContext, this.genKey(), shown);
    } catch (e) {
      promptAction.showToast({ message: this.t('err.genFail') + (e as Error).message });
      // 失败路径：补上节流中已收到的部分内容
      this.resultThrottle.flush();
    } finally {
      // 丢弃未提交的中间态：成功路径已由 this.result = content 写入权威内容，
      // 此处若 flush 会用滞后的 partial 覆盖它。
      this.resultThrottle.cancel();
      this.loading = false;
      this.thinkRunning = false;
      // 思考框随生成态结束而收起；若本次确实产生了思考内容，
      // 完成态视图会按 thinkText !== '' 继续展示（可点击标题展开）
      this.thinkExpected = false;
      // 实况窗：生成结束（完成/失败/停止）即结束，避免残留
      LiveView.done().catch((e: Error) => {
        hilog.warn(0x0000, 'Talk', 'LiveView.done 异常: %{public}s', e.message);
      });
      // 生成结束（完成/失败/停止）：思考过程自动折叠，用户点击标题可展开查看
      this.thinkExpanded = false;
      // 生成完成后自动下滑定位到结果预览，仅留预览顶部操作按钮
      setTimeout(() => this.autoShowResult(), 120);
    }
  }

  /** 生成完成后自动下滑到结果预览顶部（输入卡片滑出视口，预览填充可见区域并保持可下滑查看剩余内容） */
  private autoShowResult(): void {
    if (this.result === '') {
      return;
    }
    const target: number = this.computeResultOffset();
    this.resultTop = target;
    this.doneScroll.scrollTo({
      xOffset: 0,
      yOffset: Math.max(0, target - ResultTopPadding),
      animation: { duration: 350 }
    });
  }

  /** 自动保存到历史（开关开启且内容非空时静默保存；content 用于页面已离开时的兜底） */
  private autoSaveHistory(content?: string): void {
    const text: string = content !== undefined && content !== '' ? content : this.result;
    if (text === '') {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const typeLabel: string = I18n.t('page.talk');
    HistoryStore.autoAdd(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + this.sceneLabel(),
      content: text,
      time: HistoryStore.formatNow()
    });
  }

  saveToHistory(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const typeLabel: string = I18n.t('page.talk');
    HistoryStore.addRecord(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + this.sceneLabel(),
      content: this.result,
      time: HistoryStore.formatNow()
    }).then(() => {
      promptAction.showToast({ message: I18n.t('toast.saved') });
    });
  }

  /** 生成中：预览框实时滚动到最底部（等一帧让新内容完成布局） */
  private scrollLiveToBottom(): void {
    setTimeout((): void => {
      // 生成完成的这帧会把预览框 Scroller 从布局中移除（切换为整页滚动），
      // 若此时仍对已销毁的 Scroller 调 scrollEdge，会在原生层崩溃导致闪退，故用 loading 守卫跳过
      if (!this.loading) {
        return;
      }
      try {
        this.liveScroll.scrollEdge(Edge.Bottom);
      } catch (e) {
        // 预览区尚未挂载时忽略
      }
    }, 32);
  }

  /** 停止生成：立即取消任务与订阅，保留半截预览文本，回到生成前状态 */
  private stopGen(): void {
    this.stopRequested = true;
    AiService.stop(this.genKey());
    GenSession.clear(this.genKey());
    this.loading = false;
    this.thinkRunning = false;
    // 停止生成后思考过程同样自动折叠
    this.thinkExpanded = false;
  }

  /** 输入卡片 + 生成按钮区（生成中整卡置灰锁定按钮除外） */
  @Builder
  inputCard() {
    Column({ space: 10 }) {
      // 输入区：生成中整体置灰并锁定（按钮除外）
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Text(this.t('label.scene')).fontSize(15).fontColor(this.col('title')).width(86)
            .fontFamily(AppFonts.family())
          Select(this.sceneOptions())
            .selected(this.sceneIndex)
            .value(this.sceneLabel())
            .layoutWeight(1)
            .onSelect((index: number) => {
              this.sceneIndex = index;
            })
        }
        .width('100%')
        Row({ space: 10 }) {
          Text(this.t('label.tone')).fontSize(15).fontColor(this.col('title')).width(86)
            .fontFamily(AppFonts.family())
          Select(this.toneOptions())
            .selected(this.toneIndex)
            .value(this.toneLabel())
            .layoutWeight(1)
            .onSelect((index: number) => {
              this.toneIndex = index;
            })
        }
        .width('100%')
        // 【隐私】可选的学生姓名：填了它就一定被编号替换（描述里写没写都管用）。
        // 留空也能用 —— 描述里"张三同学""学生姓名：张三"这类带称谓/标签的写法会被识别，
        // 见 maskSituation 的说明。
        Row({ space: 10 }) {
          Text(this.t('label.studentName')).fontSize(15).fontColor(this.col('title')).width(86)
            .fontFamily(AppFonts.family())
          TextInput({
            text: this.studentName,
            placeholder: this.t('ph.talkStudentName')
          })
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.studentName = v; })
        }
        .width('100%')
        Text(this.t('talk.situationDesc'))
          .fontFamily(AppFonts.family())
          .fontSize(13)
          .fontColor(this.col('title'))
          .width('100%')
        TextArea({ text: this.situation, placeholder: this.t('ph.situation') })
          .fontFamily(AppFonts.family())
          .width('100%')
          .height(90)
          .fontSize(14)
          .onChange((v: string) => { this.situation = v; })
          .backgroundColor(this.col('inputBg'))
          .placeholderColor(this.col('hint'))
          .caretColor('#4A90D9')
          .borderRadius(10)

        // 备注（支持语音输入：点击麦克风切换"按住说话"，松手发送，上滑取消）
        VoiceRemarkBox({
          text: $remark,
          disabled: this.loading,
          labelText: this.t('label.remark'),
          placeholderText: this.t('ph.remark')
        })

        // 附件：+ 号选择图片/文档/拍照（上限 10）
        AttachBar({ files: $attachFiles, disabled: this.loading })

        // 深度思考开关：开启后本次生成走思考模式（模型先推理再作答），思考过程实时展示
        ThinkSwitch()
      }
      .width('100%')
      .enabled(!this.loading)
      .opacity(this.loading ? 0.6 : 1)

      // 生成中：按钮显示"生成中…"并禁用，避免重复提交。
      // （"停止生成"在页面顶部固定操作条，此处不重复提供）
      if (this.loading) {
        Button(this.t('gen.loading'))
          .fontFamily(AppFonts.family())
          .fontSize(15)
          .width('100%')
          .height(44)
          .fontColor('#FFFFFF')
          .backgroundColor('#9AA7B5')
          .enabled(false)
      } else {
        Button(this.t('act.talk'))
          .fontFamily(AppFonts.family())
          .width('100%')
          .height(44)
          .backgroundColor('#D9534F')
          .onClick(() => {
            this.generate();
          })
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.col('card'))
    .borderRadius(14)
  }

  /** 生成中：仅预览框内部滚动（整页固定，自动滚到底） */
  @Builder
  loadingPreview() {
    Column({ space: 8 }) {
      if (this.result !== '') {
        // 流式输出中：顶部小字提示 + 内容在预览框内部滚动到底
        Row({ space: 6 }) {
          LoadingProgress().width(14).height(14).color('#D9534F')
          Text(this.t('gen.streaming'))
            .fontFamily(AppFonts.family())
            .fontSize(12)
            .fontColor(this.col('sub'))
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
        .padding({ bottom: 8 })
        Scroll(this.liveScroll) {
          RichBox({ html: RichHtml.liveSafe(this.result) })
            .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
      } else {
        Row({ space: 10 }) {
          LoadingProgress().width(26).height(26).color('#D9534F')
          Text(this.t('gen.loading')).fontSize(14).fontColor(this.col('sub'))
            .fontFamily(AppFonts.family())
        }.width('100%').justifyContent(FlexAlign.Center).padding(20)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .backgroundColor(this.col('card'))
    .padding(16)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: 0 }) {
      // 固定标题栏：整页滚动时标题栏保持不滚，并预留顶部安全区（状态栏/刘海避让）
      Column() {
        PageHeader({ title: this.t('page.talk') })
        // 生成中：标题栏下方固定一条"停止生成"操作条。
        // 放在固定标题栏内而非输入卡片内 —— 生成过程中输入区可能被收起/禁用，
        // 若停止按钮留在卡片里会随之消失或不可点，用户无法中断生成。
        if (this.loading) {
          Row() {
            Button(this.t('act.stop'))
              .fontFamily(AppFonts.family())
              .fontSize(14)
              .fontColor('#FFFFFF')
              .height(34)
              .backgroundColor('#C0564F')
              .borderRadius(17)
              .onClick(() => {
                this.stopGen();
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ left: 12, right: 12, bottom: 8 })
        }
      }
      .width('100%')
      .padding({ top: this.topInset })

      if (this.loading) {
        // 生成中：输入卡片固定不下滑（整页不随生成滚动），仅预览框内部滚动到底
        Column({ space: 0 }) {
          this.inputCard()
          // 深度思考过程：生成中实时滚动；完成后自动折叠
          // 条件用 thinkExpected（本次预期有思考过程）而非 thinkText !== ''，
          // 否则思考增量尚未到达时思考框不会出现，用户会看到"直接跳到正文生成"。
          if (this.thinkExpected) {
            ThinkPanel({
              text: this.thinkText,
              expanded: $thinkExpanded,
              running: this.thinkRunning
            })
              .width('100%')
              .margin({ top: 10 })
          }
          this.loadingPreview()
        }
        .width('100%')
        .layoutWeight(1)
        .padding(12)
      } else {
        // 生成完成后：整页可下滑，完整显示预览框与顶部操作按钮
        Scroll(this.doneScroll) {
          Column({ space: 0 }) {
            this.inputCard()

            // 深度思考过程：灰色小字；生成完成后自动折叠，点击标题可展开查看
            if (this.thinkText !== '') {
              ThinkPanel({
                text: this.thinkText,
                expanded: $thinkExpanded,
                running: this.thinkRunning
              })
                .width('100%')
                .margin({ top: 10 })
            }

            if (this.bottomResult) {
              // 2in1（独立页面）：生成结果统一显示在下半屏大面板，本组件不再内嵌结果区
            } else if (this.result !== '') {
              ResultPanel({
                result: this.result,
                type: I18n.t('page.talk'),
                title: I18n.t('page.talk') + '-' + this.sceneLabel(),
                scrollPage: true,
                onSave: () => this.saveToHistory(),
                onEdited: (t: string): void => {
                  if (t.trim() === '') {
                    // 异常空回写保护：避免已有结果被清空导致预览框消失
                    return;
                  }
                  this.result = t;
                  // 同步到生成会话：离开页面/再次进入时不丢最新内容（含编辑结果）
                  GenSession.end(this.genKey(), t);
                  PageDraft.save(getContext(this) as common.UIAbilityContext, this.genKey(), t);
                }
              })
                .width('100%')
                .padding(16)
                .onAreaChange((_o: Area, n: Area): void => {
                  this.resultAbsTop = Number(n.globalPosition.y);
                })
            } else {
              Row() {
                Text(this.t('hint.common'))
                  .fontFamily(AppFonts.family())
                  .fontSize(12)
                  .fontColor(this.col('hint'))
                  .lineHeight(18)
              }
              .width('100%')
              .padding(16)
              .alignItems(VerticalAlign.Top)
            }
          }
          .width('100%')
          .padding(12)
          .onAreaChange((_o: Area, n: Area): void => {
            // 滚动内容容器的屏幕 Y 坐标：用于把结果面板的绝对坐标换算成相对偏移
            this.scrollContentTop = Number(n.globalPosition.y);
          })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.col('bg'))
  }
}


@Entry
@Component
struct TalkEntry {

  /**
   * 编辑浮层打开时拦截返回手势/返回键：
   * 交由编辑器弹出"放弃并退出"确认，避免左滑直接把页面弹栈导致生成结果丢失
   */
  onBackPress(): boolean {
    if (AppStorage.get<boolean>('editorOpen') === true) {
      AppStorage.setOrCreate('editorCloseReq', Date.now());
      return true;
    }
    return false;
  }
  build() {
    Column() {
      TalkContent()
    }
    .width('100%')
    .height('100%')
  }

  }
