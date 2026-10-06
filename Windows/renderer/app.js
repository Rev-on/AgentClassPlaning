/* ============================================================================
 * 【已废弃 · 故意保持空实现】Rev TechingMaster 电脑版 · 旧版单文件渲染层
 *
 * 为什么留一个空文件而不是删掉：
 *   某些手工搭的调试页 / 旧书签会直接 <script src="renderer/app.js">，
 *   若文件被删除，这些页面会 404 甚至白屏。保留为空实现可以让它们
 *   静默降级（什么都没渲染），而不会抛异常。
 *
 * 为什么必须清空（重要）：
 *   本文件曾是一份**完整可运行**的旧版渲染层，并且它自带一套 DOM 初始化：
 *     document.addEventListener('DOMContentLoaded', ...) 里会
 *       $('#btn-theme').addEventListener(...)
 *   而根节点 #btn-theme 只存在于它自己的旧版 HTML 里，在现行
 *   renderer/index.html（三 Tab 面板布局）中**并不存在**。
 *   一旦两者被同时加载，这里会抛
 *     "Cannot read properties of null (reading 'addEventListener')"，
 *   直接把后加载的 renderer/js/app.js 打断，应用变成白屏。
 *   同时它还会 buildAiPages()/buildStaticPages() 往 #pages 里再建一套页面，
 *   与现行渲染层抢同一批 DOM id（#nav、#pages、#page-*），造成重复渲染。
 *
 * 现行渲染层（唯一入口，由 renderer/index.html 加载，顺序不可颠倒）：
 *   js/vendor/jszip.min.js → js/i18n-data.js → js/office.js
 *   → js/notify-core.js  （生成通知核心：固定 notifyId 映射 + 文案拼装，可被 Node 单测）
 *   → js/app.js          （界面 + 生成流程 + 通知接线）
 *
 * 消息通知（本次新增能力）见：js/notify-core.js、renderer/preload.js、main.js
 * 说明文档见：Windows/通知功能说明.md
 * ========================================================================== */
/* 故意为空：请勿在此文件内添加任何逻辑。 */
