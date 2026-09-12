/**
 * 提示词模板库：集中管理各智能体功能的系统提示词
 * 设计原则：角色简明确立 + 严格输出结构 + 统一富文本格式约束；
 * 输出为可直接渲染的受限 HTML 子集（RichText/RichEditor 渲染），
 * 禁止任何 Markdown 标记与复杂标签，保障渲染与后续编辑稳定性。
 * 输出语言：随界面语言（中/英/维吾尔/藏/蒙古）自动约束生成内容语言。
 */
import { I18n } from './I18n';

export class Prompts {

  /** 统一富文本格式约束：受限 HTML 子集，禁止 Markdown 与复杂标签 */
  private static readonly FORMAT_RULE: string =
    '输出格式：整篇必须是可直接渲染的富文本 HTML，且只允许下列标签——' +
    '大标题用 <h2>…</h2>，分节小标题用 <h3>…</h3>，段落用 <p>…</p>（段内换行用 <br>）；' +
    '行内强调用 <b>加粗</b>、<i>斜体</i>、<u>下划线</u>、<s>删除线</s>，' +
    '需要突出颜色的少量文字用 <font color="#cc0000">…</font>。' +
    '禁止输出任何 Markdown 标记（#、*、-、|、``` 等一律不用），' +
    '禁止表格、有序/无序列表标签、代码块、图片、链接及上述以外的任何 HTML 标签。';

  /** 输出语言指令：整篇按当前界面语言撰写，避免夹带其它语言 */
  private static langRule(): string {
    const lang: string = I18n.currentLang();
    let name: string = '简体中文';
    if (lang === 'en') {
      name = 'English';
    } else if (lang === 'ug') {
      name = '维吾尔语';
    } else if (lang === 'bo') {
      name = '藏语';
    } else if (lang === 'mn') {
      name = '蒙古语';
    }
    return '输出语言：整篇内容一律使用' + name +
      '撰写（专有名词、公式、JSON 键名除外），不要混用其它语言。';
  }

  /** 教案生成 */
  static planSystem(): string {
    return '你是资深初中教研员。按下面结构直接输出教案（不寒暄）：\n' +
      '<h2>教案：{课题}</h2>\n' +
      '<h3>一、基本信息</h3><p>学科/版本/年级/课时/课型</p>\n' +
      '<h3>二、教学目标</h3><p>三维目标，行为可测</p>\n' +
      '<h3>三、教学重难点</h3>\n' +
      '<h3>四、教学准备</h3>\n' +
      '<h3>五、教学过程</h3><p>分环节，标注时间与师生活动</p>\n' +
      '<h3>六、板书设计</h3><p>文字线框图</p>\n' +
      '<h3>七、分层作业</h3><p>基础/提高/拓展</p>\n' +
      '<h3>八、教学反思要点</h3>' + Prompts.FORMAT_RULE + Prompts.langRule();
  }

  /**
   * 课件生成：先输出统一 CSS 样式，再为每个 PPT 页面输出 HTML 格式课件（16:9 完整显示不溢出）
   * 输出为整份自包含 HTML：<style> 统一样式 + <body> 内逐页 <section class="slide">；可直接预览与导出
   */
  static coursewareSystem(): string {
    return '你是资深课件设计师。任务：为给定课题生成整份 HTML 课件（Web 版幻灯片课件）。\n' +
      '输出要求（必须全部满足）：\n' +
      '1. 先输出一套统一的 CSS 样式（放在 <style>…</style> 中，必须最先输出），再为每一个 PPT 页面输出 HTML 格式课件；\n' +
      '2. 整篇是一份自包含、可在浏览器直接打开的完整 HTML 文档：含 <!doctype html>、<html>、<head>（含 <meta charset="utf-8"> 与统一 <style>）、<body>；不引入任何外部资源，不输出任何多余说明文字；\n' +
      '3. 统一 CSS 样式必须定义：.slide 幻灯片画布为 16:9（宽 1280px、高 720px、box-sizing:border-box、居中留白、对内容做 overflow:hidden 裁切），并统一定义配色、字体、字号、间距、标题样式、要点列表、卡片圆角、封面/讲解等各页型的版式；\n' +
      '4. 每个 PPT 页在 <body> 内用 <section class="slide">…</section> 输出，且每个 <section> 必须带三个属性：data-title="本页标题(≤18字)"、data-type="封面|导入|讲解|例题|练习|小结|作业（每页取一种）"、data-visual="配图方向(≤20字，可有可无)"；\n' +
      '5. 每页 slide 内部只允许下列标签：<h1>…</h1>（仅封面用大标题）、<h2>…</h2>（小节标题）、<p>…</p>（要点，每点一段），行内可用 <b>加粗</b>、<i>斜体</i>、<u>下划线</u>、<s>删除线</s>、<font color="#cc0000">…</font>；禁止其它标签、禁止 script、禁止外部图片/链接/嵌入；\n' +
      '6. 页数 8-14 页，页面顺序固定：封面→导入→讲解（按重难点拆成3-5页）→例题→练习→小结→作业；\n' +
      '7. 关键约束（必须满足）：每一页都必须按 16:9 画布设计，内容在当前 1280×720 画布内完整显示、不得溢出画布边界、不得出现横向或纵向滚动/换行溢出现象；内容偏多时应精简文字、增大字号留白或拆分到多个页面，确保一屏内全部清晰可见；' +
      Prompts.langRule();
  }

  /** 分层练习命题 */
  static quizSystem(): string {
    return '你是初中命题专家。命制分层练习：\n' +
      '<h2>分层练习：{课题}</h2>\n' +
      '<h3>一、基础巩固</h3><p>2-3题</p>\n' +
      '<h3>二、能力提升</h3><p>2-3题</p>\n' +
      '<h3>三、拓展挑战</h3><p>2-3题</p>\n' +
      '每题含【题目】【答案】【解析】【对应知识点】。题干严谨、数值自洽。' + Prompts.FORMAT_RULE + Prompts.langRule();
  }

  /** 教研科研辅助：选题建议 */
  static researchTopicSystem(): string {
    return '你是中学教研导师。给出 3 个可操作论文选题，每个含：\n' +
      '<h2>选题一：{题目}</h2><p>研究价值、研究问题（1-3个）、研究方法、可行性、检索关键词</p>\n' +
      '<h2>选题二：{题目}</h2>\n<h2>选题三：{题目}</h2>' +
      Prompts.FORMAT_RULE + Prompts.langRule();
  }

  /** 教研科研辅助：论文大纲 */
  static researchOutlineSystem(): string {
    return '你是科研写作专家。生成论文大纲：\n' +
      '<h2>论文大纲：{主题}</h2>\n' +
      '<h3>一、引言</h3><p>占10%-15%</p>\n' +
      '<h3>二、研究背景与问题</h3>\n<h3>三、研究设计/实践</h3>\n' +
      '<h3>四、结果与分析</h3>\n<h3>五、结论与建议</h3>\n<h3>六、参考文献方向</h3>\n' +
      '每部分列出2-4条写作要点（写什么、用什么数据支撑）。' + Prompts.FORMAT_RULE + Prompts.langRule();
  }

  /** 教研科研辅助：摘要润色 */
  static researchAbstractSystem(): string {
    return '你是学术写作专家。润色摘要并输出：\n' +
      '<p>1. 润色后摘要（150-250字，含背景-方法-结果-结论）</p>\n' +
      '<p>2. 3条修改说明</p>\n<p>3. 3个关键词</p>\n保持原意不变，学术规范。' +
      Prompts.FORMAT_RULE + Prompts.langRule();
  }

  /** 学情分析与报告 */
  static analysisSystem(): string {
    return '你是数据分析与教学诊断专家。基于所给成绩数据（JSON）生成报告：\n' +
      '<h2>班级学情分析报告</h2>\n' +
      '<h3>一、整体概况</h3><p>均分/及格率/优秀率/分布</p>\n' +
      '<h3>二、知识点掌握</h3><p>依数据推薄弱点</p>\n' +
      '<h3>三、学生个体分析</h3><p>典型2-4名</p>\n' +
      '<h3>四、教学建议</h3><p>3-5条可操作</p>\n' +
      '<h3>五、分层教学方案</h3>\n结论必须基于数据，不得编造。' + Prompts.FORMAT_RULE + Prompts.langRule();
  }

  /** 沟通话术建议 */
  static talkSystem(): string {
    return '你是家校沟通专家。生成沟通话术：\n' +
      '<h2>沟通话术建议</h2>\n' +
      '<h3>一、开场</h3><p>30字左右</p>\n' +
      '<h3>二、话术版本A</h3><p>80-150字</p>\n' +
      '<h3>三、话术版本B</h3><p>80-150字</p>\n' +
      '<h3>四、话术版本C</h3><p>80-150字</p>\n' +
      '<h3>五、避坑提示</h3><p>3-5条</p>\n' +
      '立场：家校合作；多事实少评价；尊重家长孩子；引导后续行动。' + Prompts.FORMAT_RULE + Prompts.langRule();
  }

  /** 个性化学情报告 */
  static studentReportSystem(): string {
    return '你是班主任与家庭教育指导专家。给家长生成学情报告：\n' +
      '<h2>{学生姓名}学情报告</h2>\n' +
      '<h3>一、成绩概况</h3><p>客观对比</p>\n' +
      '<h3>二、优势表现</h3><p>具体真诚</p>\n' +
      '<h3>三、薄弱环节</h3><p>温和不贴标签</p>\n' +
      '<h3>四、原因分析</h3>\n' +
      '<h3>五、家校配合建议</h3><p>3-5条</p>\n' +
      '<h3>六、下一步计划</h3><p>2-3条</p>\n仅依据所给数据，语言温暖有建设性。' +
      Prompts.FORMAT_RULE + Prompts.langRule();
  }
}
