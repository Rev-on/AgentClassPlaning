# Technical Report — HarmonyOS/ArkTS Education App
## Scope: `entry/src/main/ets/pages/`, `entryability/`, `entrybackupability/`, `common/components/`

Read: all 18 page files, both ability files, all 7 components. No files were modified.

---

## 1. Navigation / routing

### 1.1 Route table — `entry/src/main/resources/base/profile/main_pages.json`

Registers exactly 16 `@Entry` pages:

```
Splash, Index, Plan, Courseware, Quiz, Research, Analysis, Talk, Report,
History, Settings, Seats, ClassManager, ClassDetail, ContinuationResult, WatchHome
```

`IndexWide.ets` and `IndexWideDuo.ets` are deliberately **absent** — they are plain
`@Component` structs (not `@Entry`), imported by `Index.ets:19-20` and rendered as child
components (Index.ets:563, 570). The router never knows about them. This is consistent.

### 1.2 Two competing router APIs

| Mechanism | Where | Note |
|---|---|---|
| deprecated global `router.pushUrl` / `router.back` | Index.ets:606,613,620,627,634,641,687,694,740,747,754; ClassManager.ets:117; PageHeader.ets:33; Plan.ets:233; Courseware.ets:72 | The dominant path |
| `UIContext.getRouter().replaceUrl` | Splash.ets:329, 338, 341 | Only Splash |

Splash.ets:337 carries an explicit comment — *"ArkUI-X 跨端：使用 UIContext 路由（router.replaceUrl 不支持跨平台）"*.
That rationale is never applied anywhere else, so the codebase mixes both APIs with no
stated policy. `PageHeader.ets:33` (`router.back()`) is the shared back button for every
non-wide page.

### 1.3 The three Index variants

**`Index` (Index.ets:557-787)** is the single `@Entry` shell. Its `build()` is a
three-way branch:

```
if (this.appDuo)        → IndexWideDuo()      // :558-566
else if (this.wideLayout) → IndexWide()        // :567-573
else                    → Tabs (3 tabs)        // :575-786  phone
```

**Form-factor detection.**

- `applyWide(vw, vh)` (Index.ets:233-243) sets `appWideLayout` when
  `vw > vh && vw >= 900 && vh >= 520` — *or* when `DuoDetect.supported() && DuoDetect.hasLowerHalf()` (:237).
- `refreshDuo(vw, vh)` (Index.ets:248-264) sets `appDuo` when
  `(2in1 && geometryWide && vw>=1000 && vh>=760) || twoScreen`, then gates on
  `DuoDetect.keyboardDocked()` — **magnetic keyboard connected ⇒ tablet layout, not duo**
  (:257-263). This is the phone/tablet/2-in-1 discriminator.
- Inputs: `window.on('windowSizeChange')` (:416), `DuoDetect.attach` (:424),
  `display.on('add'|'remove'|'change')` (:429-437, delayed 300 ms at :445).

So: **phone** = bottom Tabs; **tablet/landscape or 2-in-1 *with* keyboard** = `IndexWide`
(400 vp left rail + right content pane, no page transitions); **2-in-1 *without* keyboard**
= `IndexWideDuo` (upper tool pane + lower result pane).

**`IndexWide` (372 lines).** Left `Column` fixed at `NAV_W = 400` (:53), right pane is
`this.renderContent()` (:201-226) — a flat `if/else if` chain over `selId`. Tab switching
(`switchTab`, :166-188) resets `selId` to the first entry of the new group and drives a
sliding highlight block measured via `onAreaChange` → `measureTabs` (:156-163).
Right-pane content is wrapped in **no Scroll** (:359-361).

**`IndexWideDuo` (657 lines).** Same rail/nav code, duplicated verbatim from IndexWide
(:244-412 vs IndexWide.ets:38-198). Differences:

1. `renderContent()` passes `bottomResult: true` to the 7 AI tools (:417-438) so the
   pages suppress their own inline result panel.
2. Right pane **is** wrapped in a `Scroll` (:574-583) — asymmetric with IndexWide.
3. `build()` (:636-656) splits on `twoScreen` (written by Index.ets:289):
   - `twoScreen === true` → `duoTwoPane()` (:611-634): manual geometric partition —
     upper pane at `height(screenTopVp())`, a crease-avoidance spacer at `height(creaseVp())`,
     lower pane `layoutWeight(1)`. `screenTopVp()`/`creaseVp()` delegate to `Duo2in1` (:271,:276).
   - `twoScreen === false` → system `FoldSplitContainer` with
     `expandedLayoutOptions: { verticalSplitRatio: 1.5 }`, `foldedLayoutOptions: { verticalSplitRatio: 1 }`.

**Two entirely different partition algorithms** selected by one boolean. Index.ets:285-306
(`syncDuoWindow`) drives window spanning with a **800 ms watchdog** that retries
`Duo2in1.enterFold` up to 30 times (:327-352, :339) and collapses when the lower half
disappears (:392-398).

### 1.4 Entry / exit graph

```
Splash (EntryAbility.ets:51 loadContent)
  ├─ WatchLayout.isWatch() → replaceUrl WatchHome        (Splash.ets:328-333)
  ├─ ContinuationService.hasInbox() → ContinuationResult  (Splash.ets:335-336)
  └─ else → Index                                         (Splash.ets:336)
Index ──pushUrl──▶ Plan / Courseware / Quiz / Research / Analysis / Seats
                └─▶ Talk / Report / History / Settings / ClassManager
Plan ──pushUrl(params:{planText})──▶ Courseware            (Plan.ets:233-236)
ClassManager ──pushUrl(params:{cid})──▶ ClassDetail        (ClassManager.ets:117)
```

Splash is the only `replaceUrl` user, so **there is no back-stack to Splash**: pressing
back from `Index` exits the app. `ContinuationResult` has no `onBackPress`, so back pops
to Index (the inbox was already drained by `takeInbox()` at ContinuationResult.ets:39).

---

## 2. Feature pages

All seven AI pages share an identical skeleton: `PageHeader` in a fixed top `Column` with
`padding({top: topInset})`, then a `loading` / `done` branch, an `inputCard()` `@Builder`,
a `loadingPreview()` `@Builder`, and one `ResultPanel` with `scrollPage: true`.
Every one of them carries a copy of `resumeGenSession()` / `leaveGenSession()` /
`stopGen()` / `autoSaveHistory()` / `saveToHistory()` / `scrollLiveToBottom()` /
`autoShowResult()`.

### 2.1 Splash.ets (434 lines)

Purpose: animated particle launch screen. Not a data page.

- Reads the theme image (`app.media.foreground` dark / `foreground1` light, :141), decodes
  via `image.createImageSource` + `createPixelMap` + `readPixelsToBuffer` (:143-156),
  samples on a 2.2 vp grid (:163), and buckets opaque pixels into 4-bit-quantised colour
  groups (:182-190) for cheap `fillStyle` switching.
- Each particle flies in from a random screen edge with cubic ease-out (:194-221, :318).
- Dark mode adds a pulsing glow layer that fades out at `startAt + 2400` ms (:232, :277-305).
- Text fades in at `finishAt` (:229), navigation at `jumpAt` (:230); hard 7 s fallback
  `forceAt` (:97, :265-268).
- `noAnimFallback()` (:236-249) covers decode failures.
- `goIndex()` (:326-346): watch → `WatchHome`; inbox present → `ContinuationResult`;
  else `Index`, with one 800 ms retry (:340-344).
- Registers the three minority-language fonts (`ensureFonts`, :104-125) guarded by
  `AppStorage('revFontsReg')`.
- Shows literal `'Agent备课'` (:370) — not an i18n key — and `'v1.0.0 · AGPL-3.0'` (:414).

### 2.2 Index.ets (789 lines)

Three tabs (`备课助手` / `家校沟通` / `我的`), each a 2-column `Grid` of `FunCard`s
(`@Component` at :130-182, `@Prop title/desc` so language switches propagate).

- `DisclaimerDialog` (:23-127): 5 s countdown before 同意 enables (:109); 同意 →
  `AcceptStore.setAccepted` (:63); 不同意 → `ctx.terminateSelf()` (:73).
- Greeting typewriter (:472-498) driven by `Greeting.forNow()` (time slot + 2026 holiday table).
- `aboutToAppear` (:500-521): fonts, `appDuo/appTwoScreen` defaults, `ResultBus.init()`,
  greeting, `initWideLayout()`, disclaimer check, `GenTask.recover(ctx)`.
- No result panel; no export. Pure navigator.

### 2.3 Plan.ets (556 lines) — 教案生成

| | |
|---|---|
| Fields | 学科 `subject`, 教材版本 `version`, 年级 `grade`, 课题 `topic`, 课时 `period` (all `TextInput`, :279-323); 备注 `remark` via `VoiceRemarkBox` (:327-332); attachments via `AttachBar` (:335) |
| Prompt | `Prompts.planSystem()` (Plan.ets:161) |
| Service | `AiService.chat(..., onDelta, false, {ctx,type:'plan',label,attachments,thinking}, onThink)` (:161-179) |
| Streaming | **Yes** — `onDelta` writes `this.result = partial` and calls `scrollLiveToBottom()` (:167-168) |
| Think | `ThinkSwitch()` in input card (:338); `ThinkPanel` rendered twice (:449-453 loading, :470-476 done) |
| Result | `ResultPanel` :482-503 — `type`/`title` = `教案生成-{topic}`, `scrollPage:true`, default `exportMode:'word'` |
| Export | Copy / 导出Word / 保存历史 (defaults) |
| Unique | `jumpToCourseware()` (:229-239) pushes `pages/Courseware` with `params:{planText:this.result}` |

`@Entry PlanEntry` (:533-556) intercepts back when `AppStorage('editorOpen')` is true and
writes `editorCloseReq` (:541-547) — the same 8-line `onBackPress` is copy-pasted in
Courseware/Quiz/Research/Analysis/Talk/Report.

### 2.4 Courseware.ets (513 lines) — 课件大纲

- Fields (when **not** in import mode): 学科 / 年级 / 课题 / 课型用途 `usage`; remark; attachments (:272-326).
- **Import mode** (:46-48, :72-80): if route param `planText` is non-empty, hides all inputs,
  sets `topic = t('def.importedPlan')`, and generates directly from the plan (:174-177).
- Prompt `Prompts.coursewareSystem()`, `skipNote = true` (:183, :191).
- **No streaming render**: `onDelta` discards the partial (`void partial`, :190). Live preview
  shows only a spinner (`loadingPreview`, :371-385).
- `PptxExporter.writeCoursewarePages` after completion (:210); `clearCoursewarePages` before (:172).
- `ResultPanel` :435-455 — **`exportMode:'pptx'`, `slideMode:true`, `editable:false`, `showCopy:false`**.
- No `autoShowResult` streaming guard needed since output is one-shot.

### 2.5 Quiz.ets (507 lines) — 分层练习

Fields 学科/年级/课题知识点/附加要求 `requirement` (:260-299) + remark + attachments.
Prompt `Prompts.quizSystem()`, `type:'quiz'`, **streaming on** (:158-176), accent `#3E9B6F`.
`ResultPanel` :433-449, default word export, fully editable.

### 2.6 Research.ets (538 lines) — 教研辅助

Three modes via `mode: 0|1|2` = 选题建议 / 论文大纲 / 摘要润色 (:150-168), switching
`mode` clears `result` (:298). Single `TextArea` `input` plus remark + attachments.
Prompt chosen by `systemPrompt()` (:161-168). Streaming on (:186-193).
**Unique: a blinking red watermark** (`research.wm`, :488-497) driven by a 650 ms interval
(:119-121). `ResultPanel` :452-468, word export.

### 2.7 Analysis.ets (582 lines) — 学情分析

- Input is a `TextArea` of tab-separated Excel data (:312-320) with live preview via
  `ExcelParser.parse` (:125-127, :322-373) showing header + first 5 rows.
- **Import**: `ExcelFileImporter.pickAndParse` → `toTabText` (:150-164).
- Generation gate: `rows.length < 2` → `err.noExcelData` (:168-171).
- Prompt `Prompts.analysisSystem()`; user prompt embeds `ExcelParser.toJson(rows)` (:182).
- Streaming on (:184-191). `ResultPanel` :508-524; title uses a date slice
  `HistoryStore.formatNow().slice(5,10)` (:511).

### 2.8 Talk.ets (508+ lines) — 沟通话术

Two `Select` dropdowns (`sceneIndex` 5 options, `toneIndex` 3 options) whose **display**
strings come from i18n (`talk.s1..s5`, `talk.t1..t3`, :137-164) but whose **submitted**
values are hardcoded Chinese arrays `sceneZh`/`toneZh` (:28-29, :167-174).
Free-text `situation` `TextArea` (:332-337) + remark + attachments.
Prompt `Prompts.talkSystem()`, streaming on (:193-200). Accent `#D9534F`.
`ResultPanel` :472-488.

### 2.9 Report.ets (514 lines) — 个性化学情报告

Fields 学生姓名 `studentName`, 班级 `className`, 各科成绩 `grades` (`TextArea` 70 vp),
课堂观察 `observation` (`TextArea` 80 vp) (:261-305) + remark + attachments.
Gate on `studentName` (:142-145). Prompt `Prompts.studentReportSystem()`, streaming on.
`ResultPanel` :440-456, title = `学情报告-{studentName}`.

### 2.10 Seats.ets (912 lines) — 排座位表

**The only page with no AI call.** Pure local algorithm.

- `SeatsAlgorithm` (:26-145): `parse` (name + height lines), `sortAsc`, `build` =
  ascending sort → serpentine fill → iterative per-column correction so front rows are
  never taller than back rows (:89-117); `toMarkdown` (:122-144).
- Inputs: 排数 `rowsText`, 每排人数 `colsText` (numeric `TextInput`), 学生名单 `studentText`
  (`TextArea` 140 vp), 讲台两侧 `Checkbox` + 左/右护法姓名 (:657-730). Bounds 1..20 × 1..15 (:209).
- **Class roster integration** (:256-446): `openImport` / `openSave` / `classOptions` /
  `doImport` (fills the textarea from a class) / `doSave` (`buildRoster` merges by name,
  auto-numbers gaps from max+1, :392-405).
- Interactive grid: click one seat, click a second to swap (`onSeatTap`, :484-501); side
  seats use `r = -1` (:450-481).
- Result actions (:858-880): 复制 (`pasteboard`), 导出Word (`DocxExporter.exportDocx`),
  保存历史 (`HistoryStore.addRecord`). **No `ResultPanel`** — it renders its own grid.

### 2.11 History.ets (708 lines)

- `HistoryContent` (:322-694) lists `HistoryStore.getRecords` (`MAX = 50`).
- `HistoryDetailDialog` (:18-211): copy (plain via `RichHtml.toPlain`), and
  `isCourseware()` (:50-54) decides **PPTX vs DOCX** export; courseware renders 16:9 slide
  cards via `PptxExporter.parseOoxmlFragments` → `parseHtmlCourseware` (:57-68).
- Long-press multi-select (`enterMulti`, :373-378), batch delete with a 2 s cooldown
  self-drawn overlay (:472-527).
- `DeleteHistoryDialog` (:214-319) is **dead code** — never instantiated.
- `clearAll()` (:463-469) still uses system `AlertDialog.show` (:576).
- `onPageShow()` (:359) — see bug B16.

### 2.12 Settings.ets (514 lines)

Language (self-drawn `bindMenu` so each language uses its own font, :71-100, :247),
theme `Select` (light/dark/system, :262-271), font scale 4 presets + live preview + 应用
(:298-345), auto-save-to-history `Toggle` (:373-377), 关于, AGPL-3.0 text, and a
`REPO_URL` link opened via `startAbility` with `ohos.want.action.viewData` (:200-212).
`AppTheme.color` token table lives in `common/AppTheme.ets:14-46`.

### 2.13 ClassManager.ets (255 lines)

Class list: create/rename/delete, tap to open detail. **Wide-mode split**: in `wideLayout`
it renders `ClassDetailContent({cid: this.openCid})` inline with a back chevron (:122-143);
otherwise it pushes a route (:117).

### 2.14 ClassDetail.ets (339 lines)

`@Prop cid`; `aboutToAppear` loads the `ClassItem`; `persist()` writes back via
`ClassStore.updateClass`. Add student with auto-assigned 学号 (`nextFreeNo`, :69-85),
delete student, and `ClassImport.pickAndParse` for Excel/Word roster import with
duplicate-学号 skipping (:121-157). `@Entry ClassDetailEntry` reads `cid` from route params (:325-329).

### 2.15 ContinuationResult.ets (132 lines)

Distributed-continuation receive page. `ContinuationService.takeInbox()` fills
`result/title/ftype/exportMode/slideMode` (:39-46), then hands everything to `ResultPanel`
(:103-116) with `scrollPage:true`. Save-to-history via `onSave` (:60-70).

### 2.16 WatchHome.ets (380 lines)

Watch "上课指挥" page. See §6.

---

## 3. ResultPanel.ets in depth (1137 lines)

### 3.1 Props / state model

**Input props (`@Prop` / plain):**

| Prop | Line | Role |
|---|---|---|
| `result: string` | :84 | Rich-text HTML (plain text tolerated) |
| `type` / `title` | :86, :88 | History record type/title |
| `onSave` | :90 | Parent writes to history |
| `onEdited` | :92 | Parent receives edited HTML |
| `exportMode: 'word'\|'json'\|'pptx'` | :95 | Selects exporter |
| `slideMode: boolean` | :97 | Render as 16:9 slide deck |
| `editable` | :99 | Show 编辑 |
| `showCopy` | :101 | Show 复制 |
| `showContinue` | :103 | Show 流转 |
| `scrollPage` | :109 | Natural-height vs internal Scroll |

**Internal `@State`:** `editing`, `showColors`, `editorReady`, `hasSelection`, `topInset`,
`confirmMode` (0/1/2), `confirmRemain`. Plus `@StorageProp('appResolvedTheme')`,
`@StorageProp('appLang')`, and `@StorageProp('editorCloseReq') @Watch('onCloseReq')` (:142).

**Private (non-reactive) fields:** `rc: RichEditorController`, `selStart`/`selEnd`,
`editedFlag`, `styleOps: StyleOp[]`, `selBold/selItalic/selUnderline/selStrike`,
`confirmTimer`.

**Two AppStorage contracts** (:138-140): `editorOpen` (page's `onBackPress` reads it) and
`editorCloseReq` (page writes a timestamp to request close).

### 3.2 Streaming text rendering

ResultPanel itself does **not** stream. Streaming is split in two places:

1. **During generation** each page renders `RichBox({ html: RichHtml.liveSafe(this.result) })`
   inside its own `Scroll(this.liveScroll)` (`Plan.ets:410-413`, `Quiz.ets:361-364`,
   `Research.ets:380-383`, `Analysis.ets:436-439`, `Talk.ets:400-403`, `Report.ets:368-371`).
   `RichHtml.liveSafe` tolerates half-written HTML. `scrollLiveToBottom()` re-issues
   `scrollEdge(Edge.Bottom)` 32 ms after each delta (:202-215 in Plan) and is guarded by
   `if (!this.loading) return;` because the Scroller is unmounted in the completion frame —
   the comment at Plan.ets:204-205 records that an unguarded call **crashed natively**.
2. **After completion** the page swaps to `ResultPanel({...})` with `scrollPage:true`,
   which renders `RichBox` in natural height (:1067-1084) inside the page's `doneScroll`.

`Courseware` opts out of (1) entirely (`void partial`, Courseware.ets:190).

### 3.3 Edit mode

`openEditor()` (:310-323) rebuilds `RichEditorController`, resets `editedFlag`/`styleOps`,
calls `refreshTopInset()`, sets `AppStorage('editorOpen', true)`, `editing = true`.
The editor is presented as a **`bindContentCover` full-screen overlay** (:1127-1135), not an
inline swap — `build()` renders an empty placeholder while editing (:1114-1118).

`loadEditorContent()` (:326-360) converts HTML → `RichRun[]` via `RichHtml.htmlToRuns` and
replays them with `rc.addTextSpan`. Missing colours are forced to `inkHex()` because the
SDK default carries an alpha channel that was being misread as red (:352-353).

**Selection snapshotting.** `onEditorSelect` (:364-402) stores the range *and* computes
`selBold/selItalic/selUnderline/selStrike` by AND-ing every span's style — necessary because
tapping a toolbar chip collapses the real selection. `applySelectionStyle` (:497-518) toggles
based on the snapshot, records a `StyleOp {kind,on,color,start,end}`, and calls `updateRange`.
Colours come from the 8-entry `FONT_COLORS` palette (:24) plus 清除颜色 (:739-748).

**`readHtml()` — the core cleverness (:410-464).** Two paths:

- If the editor's concatenated span text equals `RichHtml.plainOf(this.result)` (text
  unchanged), it **never reads styles back from the SDK**: if there are no `styleOps` it
  returns `this.result` verbatim; otherwise it returns
  `RichHtml.applyStyleOps(this.result, this.styleOps)`. The comment at :406-408 explains
  why — some devices drop all inline tags on read-back.
- Only when the text actually changed does it fall back to reading spans and rebuilding via
  `RichHtml.mapOps` + `applyOpsToRuns` + `runsToHtml`.

Three enum-shape tolerance helpers exist because the SDK returns enums *or* semantic numbers
*or* strings: `isBoldWeightOf` (:33-53) accepts strings, ≥600 numerics and the
`Medium/Bold/Bolder` enum ordinals; `isItalicStyleOf` (:55), `isUnderlineOf` (:65),
`isStrikeOf` (:73). `decodeColor` (:185-203) takes only the last 6 hex digits so `#AARRGGBB`
does not become red.

**Exit confirmation** is a self-drawn overlay, not a system dialog — the comment at :123 and
:809 states system dialogs stacked over a full-screen cover crashed/killed the process.
`askSaveExit()` → mode 1, 1 s cooldown; `askDiscardExit()` → mode 2, 2 s cooldown (:569-580).
`onCloseReq()` (:144-148) routes the cover's `onWillDismiss` (:1131-1134) and the page's
back gesture into the same discard confirmation.

### 3.4 Actions

| Action | Method | Line | Behaviour |
|---|---|---|---|
| 复制 | `copyText` | :206-218 | `RichHtml.toPlain` → `pasteboard.MIMETYPE_TEXT_PLAIN` |
| 导出 Word | `exportWord` | :221-230 | `DocxExporter.exportDocx(ctx, content, safeTitle + '.docx')` |
| 导出 JSON | `exportJsonFile` | :233-242 | `DocxExporter.exportJson` |
| 导出 PPTX | `exportPptx` | :260-269 | `PptxExporter.exportPptx` |
| 保存历史 | `onSave()` callback | :1033-1036 / :793-799 | In edit mode `saveEdited()` first does `onEdited(readHtml())` then `onSave()` (:632-635) |
| 编辑 | `openEditor` | :310-323 | — |
| 流转 | `startContinue` | :288-305 | see below |

`exportLabel()` (:249-257) picks the button text from `exportMode`.

**流转 (`startContinue`, :288-305)** is a two-branch decision:
if `LessonPlanParser.isPlanType(this.type) && WatchLink.supported()` **and** a wearable is
discovered (`WatchLink.hasWearable`), it parses the plan into `LessonStage[]` and pushes a
*stage timer* to the watch instead of flowing the document (:293-301). Otherwise it
`ContinuationService.stash`es the payload and calls `startContinuation()`, which triggers
the system device picker and the `EntryAbility.onContinue` callback.

### 3.5 RichText rendering approach

Read-only rendering is **not** `RichText`. `RichBox.ets` (143 lines) parses the HTML with
`RichHtml.htmlToRuns` into `RichRun[]`, splits on `\n` into `PreviewBlock`s (:50-81), and
renders each block as either a bold `Text` (headings) or a `Text` containing one `Span` per
run (:107-134). The stated reasons (RichBox.ets:1-7): `RichText` fixes pixel sizes and
ignores the app font-scale setting, and `RichText` cannot apply the registered minority
fonts. `RichBox` uses `fp` sizes, `AppFonts.family()`, and a theme-aware paper
(`#FFFFFF` / `#1C222C`) with ink `#1B1B1F` / `#E7EAF0`.

`slideMode` bypasses `RichBox`: `slidesNow()` (:889-904) tries
`parseOoxmlFragments` → `parseHtmlCourseware` → `parseSlides`, falling back to `RichBox`
if all fail; `slidesPreview()` (:919-1002) draws 16:9 `aspectRatio(16/9)` clipped cards with
a type badge, `n / total` counter, title, ≤5 bullets, and the `visual` (image-suggestion) line.

---

## 4. Attachment / voice / thinking subsystems

### 4.1 AttachBar.ets (184 lines)

`@Link files: AttachFile[]`, `@Prop max = AttachService.MAX`, `@Prop disabled`, local
`@State busy`. The `+` tile binds `menuItems()` (:37-46) — 图片 / 文档 / 拍照 — each calling
`AttachService.pickImages` / `pickDocs` / `takePhoto` (:48-83) with a `busy`+`disabled`
re-entrancy guard. Selected files render as a horizontal `Scroll` of 48×48 tiles: images use
`f.dataUrl` directly, other kinds show `f.ext.toUpperCase()` on grey (:112-130). Each tile
has a `×` badge calling `AttachService.removeAt` (:85-90). Counter `n/max` at :100.
Whole bar greys to `opacity(0.5)` when disabled (:182). Used by Plan :335, Courseware :323,
Quiz :309, Research :325, Analysis :384, Talk :348, Report :316 — all seven AI pages.

### 4.2 VoiceRemarkBox.ets (336 lines)

`@Link text` + `@Prop disabled/labelText/placeholderText`. Clicking the mic toggles between
the `TextInput` and a "按住说话" bar (`toggleVoiceMode`, :71-92), requesting permission via
`VoiceInput.ensurePermission` first. Press → `onPressDown` (:95-104); drag →
`onSlide(offsetY)` where `offsetY < -60 vp` enters the cancel zone (:107-115); release →
`onPressUp(cancel)` (:118-137).

Three race conditions are explicitly handled:
- Start-up latency: if released before the engine started, `releaseIntent` (1=send, 2=cancel)
  is stored and applied when `start()` resolves (:124-127, :168-180).
- Both `TouchType.Cancel` and `PanGesture.onActionCancel` route to the same `onPressUp`
  with the current `cancelZone` value (:252-255, :265-267).
- Empty result under 600 ms is silently ignored; longer holds show `voice.empty` (:198-203).

Recognised text is appended to the existing remark with an auto-inserted `'。'` if the
previous character is not already punctuation (:204-211), then `voiceMode` returns to text
so the result is visible in the box. Live interim results render inside the bar
(`voiceBarText`, :317-325).

### 4.3 ThinkPanel.ets (171 lines)

**`ThinkSwitch` (:22-69)** — `@StorageLink('deepThink')`, so all seven pages share one
persisted value; `AppSettings.saveThink` on change (:63). Pages read it as
`AppStorage.get<boolean>(AppSettings.KEY_THINK) === true` and pass it as `opts.thinking`.

**`ThinkPanel` (:71-170)** — `@Prop @Watch('onTextChanged') text`, `@Link expanded`,
`@Prop running`. `onTextChanged` auto-scrolls to the bottom while expanded (:95-106). The
body is a fixed 120 vp `Scroll` whose **height is animated between 0 and 120** rather than
conditionally rendered — the comment at :144-145 explains that conditional rendering made it
vanish abruptly. The header row toggles `expanded`; expanding after completion scrolls to
`Edge.Top` instead of bottom (:129-141).

Lifecycle in the pages: `thinkText=''`, `thinkExpanded=true`, `thinkRunning=true` at start;
the first `onDelta` flips `thinkRunning=false, thinkExpanded=false`; the `finally` block sets
`thinkExpanded=false` unconditionally (:443-458 in Plan, and identically in the other six).
`AiService.chat`'s `onThink` callback is the producer (AiService.ets:332-333, :440-441, :448-449).

---

## 5. Cross-cutting UI infrastructure

### 5.1 Theming — `common/AppTheme.ets` (47 lines)

`AppTheme.color(token, resolved)` is a 16-case switch (`bg, card, title, text, sub, hint,
faint, inputBg, barBg, codeBg, codeText, line, headBg` + a `#000000` default). Two
AppStorage keys: `appTheme` (light/dark/system) and `appResolvedTheme` (light/dark).
`EntryAbility.onConfigurationUpdate` (EntryAbility.ets:34-44) recomputes `appResolvedTheme`
only when `appTheme === 'system'`.

**Page idiom**, repeated in every file:

```ts
@StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
private col(key: string): string { void this.resolvedTheme; return AppTheme.color(key, this.resolvedTheme); }
```

The `void this.resolvedTheme;` is a deliberate no-op to register the dependency (ArkTS has no
automatic tracking inside plain methods). Identical pattern for `void this.appLang;` in `t()`.

**Hardcoded colours escape the theme in ~40 places** — accent buttons (`#4A90D9`, `#2F6DB5`,
`#5BA8A0`, `#D9534F`, `#3E9B6F`, `#F0A93F`, `#7B61C2`, `#D97706`, `#C0564F`), plus
`FunCard` backgrounds in Index.ets:605-643 and the `iconBg()` chains in
IndexWide.ets:66-99 / IndexWideDuo.ets:282-313. `ResultPanel` also hardcodes
`FONT_COLORS` (:24) and paper/ink hexes (:172, :178).

### 5.2 Fonts — `common/AppFonts.ets` (43 lines)

Three registered families: `TibetanUchen` (`ctrc-uchen.ttf`), `UyghurMejT` (`UKIJMejT.ttf`),
`MongolianFont` (`c8abb3845e34a252fcf04f0cd4e74a00.ttf`); default `HarmonyOS Sans`.
`forLang(lang)` maps `bo/ug/mn` else default; `family()` reads `AppStorage('appLang')`.
Registration happens in **three** places with identical code: Splash.ets:104-125,
Index.ets:524-545, Settings.ets:47-68 — all guarded by `AppStorage('revFontsReg')`.

### 5.3 i18n — `common/I18n.ets`

`I18n.t(key)` over per-language `Map`s (`zh` inline; `UyghurDict`, `TibetanDict`,
`MongolianDict` imported). Five languages: `zh / en / ug / bo / mn`. `I18n.LANG_CODES`,
`I18n.langSelf(code)` (language's own endonym), `I18n.badge(char, key)` (icon glyph per
language). Missing minority-language keys fall back to Chinese (:8 comment).

**Invocation pattern is uniform and slightly wasteful:** `private t(key){ void this.appLang; return I18n.t(key); }`
is redefined in essentially every struct, and results are computed *inside* `build()`
(e.g. `this.t('dlg.count').replace('{n}', ...)`, Index.ets:96) rather than memoised.

### 5.4 Safe insets

`common/SafeInsets.ets` — one function, `topInset(ctx)` → `TYPE_SYSTEM` topRect height in vp.
Called in Plan:65, Courseware:68, Quiz:62, Research:115, Analysis:131, Talk:57, Report:62,
ContinuationResult:36. `ResultPanel` **duplicates** it as `refreshTopInset()` (:549-566)
using `window.getLastWindow` directly. Seats, ClassManager, ClassDetail, Settings, History
and Splash do **not** reserve a top inset.

Index.ets:436-441 shows the pattern: the `PageHeader` sits in an outer `Column` with
`padding({top: this.topInset})` so it stays fixed while the body scrolls.

### 5.5 Watch layout — `common/WatchLayout.ets` (79 lines)

`isWatch()` checks `deviceInfo.deviceType ∈ {watch, wearable}`. `isRound()` infers a round
screen from the `TYPE_CUTOUT` avoid area: `minInset > 2 && minInset*10 > shortSide` (:50).
`avoid()` returns `{round, inset, top, bottom, left, right}` where `inset` is the inscribed-
square margin on round screens (:69-73), with a hardcoded 16 px fallback (:76).

### 5.6 2-in-1 duo layout

`Index.ets` decides (`refreshDuo`, :248-264), spans the window (`syncDuoWindow`, :285-306,
`ensureSpanned`, :314-321), verifies with `Duo2in1.isAcrossSpan` (:309-311), and runs an
800 ms watchdog with a 30-attempt cap (:327-352). `IndexWideDuo` consumes
`@StorageProp('appTwoScreen')` (:244) to choose manual partition vs `FoldSplitContainer`.
`ResultBus` (`liveGenResult` JSON: `{phase, kind, type, title, text}`) is the channel: written
by `AiService` (:159 live, :234/:257 clear, :260 done) only when `AppStorage('appDuo')===true`
(:244-249), read by `DuoResultBar` (IndexWideDuo.ets:56).

---

## 6. Responsive / watch / wide-screen specifics

| Form factor | Trigger | Shell |
|---|---|---|
| Phone | default | `Index` bottom `Tabs`, bar height 56 (:783), `scrollable(false)` |
| Tablet / landscape | `vw>vh && vw>=900 && vh>=520` (Index.ets:236) | `IndexWide`, 400 vp rail + pane |
| 2-in-1 + magnetic keyboard | `!keyboardDocked()` false (Index.ets:257-263) | falls back to `IndexWide` |
| 2-in-1 no keyboard, single screen | `2in1 && geometryWide && vw>=1000 && vh>=760` (Index.ets:252) | `IndexWideDuo` + `FoldSplitContainer` |
| 2-in-1 half-folded (two physical screens) | `DuoDetect.hasLowerHalf()` (Index.ets:237,251) | `IndexWideDuo` + `duoTwoPane()` manual partition + crease spacer |
| Watch | `deviceInfo.deviceType ∈ {watch,wearable}` (WatchLayout.ets:32) | `WatchHome` |

**WatchHome** is a five-phase state machine (`phase: 0 waiting / 1 received / 2 ready /
3 running / 4 ended`, :34). It observes a distributed KV store via `WatchLink.watchObserve`
(:52-54), shows ✓已接收教案 for 1600 ms (:69-73), then a large green 开始上课 button whose
shape follows `avoid.round` — 150×150 circle or 168×112 rounded rect (:224-227). Running
shows `segIdx+1 / total · stageName`, a `LessonPlanParser.formatClock` countdown that turns
green on overtime (:258-263), and a hint line. **Timing never auto-advances** — the interval
only decrements `remain` and fires `vibrator.startVibration({type:'time',duration:400})` once
(:107-116, :148-159); the user must swipe up (`SwipeGesture`, offsetY<0, :371-377) to call
`advance()` (:121-138). The last swipe calls `WatchLink.clear` and enters phase 4.
The `//#if OHOS` guard around the `vibrator` import (:18-20) and call (:149-158) is the
ArkUI-X cross-platform escape hatch. Round-screen content is inset by
`avoid.<edge> + avoid.inset` (:358-363), and the page uses fixed dark colours
`C_BG_DARK/#0C1522`, `C_GREEN/#2ECC71`, `C_TEXT/#F2F6FB` (:22-25) rather than `AppTheme`.

---

## 7. Bugs, inconsistencies, duplication, unfinished work

Severity: **[H]** functional defect, **[M]** correctness/consistency risk, **[L]** cosmetic/perf.

### Correctness

| # | Sev | Location | Finding |
|---|---|---|---|
| B1 | **[H]** | IndexWideDuo.ets:206 + :99, AiService.ets:260 | `exportMode: this.load().kind === 'courseware' ? 'json' : 'word'` compares `kind` (a category) against a `type` value, so a 2-in-1 courseware result exports **Word, not PPTX**. Also the duo panel passes no `slideMode`, so a courseware result degrades from the 16:9 deck to raw rich text (ResultPanel.ets:1077, :1093). |
| B2 | **[H]** | IndexWideDuo.ets:99 | `ResultBus.pack('done', p.kind, p.type, p.title, text)` — args are `(phase, kind, type, title, text)` but the value passed as `kind` is `p.kind` while the real `type` is in the `kind` slot. After any edit via `patchText` the `type` field is permanently emptied; history saves then fall back to `t('tab.assistant')` (:110-111). |
| B3 | **[M]** | History.ets:675 | `ForEach` key is `record.time + record.title`. Two records in the same minute with the same title collide → ArkUI duplicate-key corruption. `HistoryStore.keyOf` exists and is used for selection (:635) but not here. |
| B4 | **[M]** | Index.ets:359-361, ClassManager.ets:41 | `onPageShow()` is declared on plain `@Component`s rendered inside `IndexWide`/`IndexWideDuo`. It is an `@Entry`-only lifecycle hook and will not fire there, so the wide-layout class/history lists go stale after an external import. |
| B5 | **[M]** | Seats.ets:200 vs :516 | `hasGrid()` returns true when only `sideCells` is non-empty, but `resultText()` dereferences `this.grid[0].length`. Latent TypeError; currently unreachable because every writer sets `grid` and `sideCells` together (:231-232, :249-250). |
| B6 | **[M]** | ClassDetail.ets:49-57 | `persist()` fires `ClassStore.updateClass` without `await` and without `.catch` — a failed write is completely silent. |
| B7 | **[M]** | Splash.ets:92-95, :140-141 | The particle init waits a guessed 200 ms for `AppSettings.load` (EntryAbility.ets:78, explicitly non-blocking) and then reads `appResolvedTheme`. On a slow cold start the splash samples the **wrong** foreground image. The comment at :92 acknowledges the race but does not solve it. |
| B8 | **[M]** | Index.ets:503-504 | `aboutToAppear` unconditionally resets `appDuo`/`appTwoScreen` to false *before* the async `refreshDuo` completes, producing a layout flip on every appearance. |
| B9 | **[M]** | Index.ets:451-469 | `this.win.off('windowSizeChange')` is called with no handler, removing **all** listeners for that event on the shared window. |
| B10 | **[M]** | ResultPanel.ets:1127 + EntryAbility.ets:60 | `KeyboardAvoidMode.RESIZE` is set page-level, but the editor is a `bindContentCover` overlay, which does not reliably inherit page-level avoid mode — the bottom Copy/Export/Save row can sit under the keyboard. |
| B11 | **[M]** | Index.ets:403 vs :416 | Startup width comes from `display.getDefaultDisplaySync()` while subsequent updates come from `window.on('windowSizeChange')`. On a windowed 2-in-1 these differ, so the first resize can flip wide↔narrow. |
| B12 | **[M]** | IndexWideDuo.ets:271, :617 | The manual partition trusts `Duo2in1.topHeightVp()`/`creaseVp()`. A stale value after rotation or fold places the result panel partly under the physical crease. No re-measure on `windowSizeChange` inside this component. |

### i18n / theming

| # | Sev | Location | Finding |
|---|---|---|---|
| B13 | **[H]** | WatchHome.ets:168,173,191,206,215,266,279,297,302,307 | The entire watch page is hardcoded Chinese with `fontFamily('sans-serif')` — no `I18n.t`, no `AppFonts`, no `AppTheme`. The only page that ignores all three systems. |
| B14 | **[M]** | VoiceRemarkBox.ets:209 | Recognised speech is joined with a hardcoded `'。'` for all five languages — English/Uyghur/Tibetan/Mongolian users get a Chinese full-stop mid-sentence. |
| B15 | **[M]** | History.ets:97 | Literal `'No content'` instead of an i18n key. |
| B16 | **[M]** | Splash.ets:370, IndexWide.ets:286, IndexWideDuo.ets:502 | Literal `'Agent备课'` brand string in three places, untranslatable. |
| B17 | **[L]** | Index.ets:605-643 vs IndexWide.ets:66-99 vs IndexWideDuo.ets:282-313 | Three independent sources of truth for card colours, and they disagree (`#E6F4F2` vs `#EDF0FA` for settings; `#F3EDFB` vs `#FDEFF0` for classes). |
| B18 | **[L]** | ResultPanel.ets:173 | `cw.empty` (a *courseware*-namespaced key) is the generic empty-result string for every feature (also :1072, :1088). |

### Duplication / dead code

| # | Sev | Location | Finding |
|---|---|---|---|
| B19 | **[H]** | 7 pages | `resumeGenSession`/`leaveGenSession`/`stopGen`/`autoSaveHistory`/`saveToHistory`/`scrollLiveToBottom`/`autoShowResult`/`loadingPreview` are near-identical in Plan:82-253, Courseware:95-264, Quiz:79-252, Research:58-280, Analysis:62-278, Talk:74-295, Report:79-252. |
| B20 | **[H]** | 7 pages | The `if (this.thinkText !== '') { ThinkPanel(...) }` block is duplicated **twice per page** (loading branch + done branch) = 14 copies: Plan:448-456/:469-477, Courseware:401-409/:422-430, Quiz:399-407/:420-428, Research:418-426/:439-447, Analysis:474-482/:495-503, Talk:438-446/:459-467, Report:406-414/:427-435. |
| B21 | **[H]** | 7 pages | The ~10-line `onBackPress` editor guard is copy-pasted verbatim: Plan:541-547, Courseware:498-504, Quiz:492-498, Research:523-529, Analysis:567-573, Talk:531-537, Report:499-505. |
| B22 | **[M]** | History.ets:214-319 | `DeleteHistoryDialog` (`@CustomDialog`, 106 lines) is never instantiated — the controller at :335 only builds `HistoryDetailDialog`. Dead code superseded by `deleteConfirmOverlay()` (:472). |
| B23 | **[M]** | IndexWideDuo.ets:244-412 vs IndexWide.ets:38-198 | ~170 lines of nav/rail/transition code duplicated between the two wide shells. |
| B24 | **[M]** | ResultPanel.ets:549-566 vs common/SafeInsets.ets | `refreshTopInset()` re-implements `SafeInsets.topInset` identically. |
| B25 | **[M]** | ResultPanel.ets:889-904 vs History.ets:57-68 | `slidesNow()` and `coursewareSlides()` are the same 3-step parser fallback chain (History omits only `parseSlides`). |
| B26 | **[L]** | Splash.ets:104-125, Index.ets:524-545, Settings.ets:47-68 | Font registration written out three times. |
| B27 | **[L]** | Index.ets:25, History.ets:20, :216 | `CustomDialogController = new CustomDialogController({ builder: undefined })` as a type placeholder — fragile against stricter SDK typing. |
| B28 | **[L]** | IndexWideDuo.ets:206, :439 | `renderContent` needs `import { PlanContent } from './Plan'` etc.; the file's import block (:17-28) and `iconBg` chain are otherwise byte-identical to IndexWide. |

### Resource leaks / timers

| # | Sev | Location | Finding |
|---|---|---|---|
| B29 | **[M]** | Research.ets:111, :119-121, :133-136 | A 650 ms `setInterval` toggles the watermark blink and is only cleared in `aboutToDisappear`. In `IndexWide`/`IndexWideDuo` the component is swapped by conditional `@Builder` rendering, not destroyed, so the timer keeps firing for the process lifetime. |
| B30 | **[M]** | WatchHome.ets:135 | `WatchLink.clear` runs only when the user swipes past the last stage. Backgrounding the app on the end screen leaves a stale `ready` bundle in the distributed store for the next session. |
| B31 | **[L]** | WatchHome.ets:371-377 | The `SwipeGesture` is attached to the page root `Stack`, not to `runningView`; `advance()` guards on `phase !== 3` (:123) so it is harmless today, but the gesture also fires on phases 0/2/4. |
| B32 | **[L]** | Splash.ets:98-100, :160-233 | The whole particle set (~10 k JS objects at 2.2 vp sampling) is built synchronously on the UI thread inside a promise callback, with no chunking. |
| B33 | **[L]** | Index.ets:32-40, :96 | The disclaimer countdown re-renders every second and allocates a new string via `.replace('{n}', ...)` *inside* `build()`. Same pattern in `startGreeting` (:482-490). |

### Inconsistency

| # | Sev | Location | Finding |
|---|---|---|---|
| B34 | **[M]** | Splash.ets:337-341 vs everything else | Only Splash uses `UIContext.getRouter()`; the comment there states the global router breaks ArkUI-X, yet 12 other call sites use the global `router` (Index:606-754, ClassManager:117, PageHeader:33, Plan:233). |
| B35 | **[M]** | History.ets:576, ClassManager.ets:93, ClassDetail.ets:103 | The codebase deliberately replaced system dialogs with self-drawn overlays to avoid crashes (ResultPanel.ets:123, History.ets:329), but three destructive confirmations still use system `AlertDialog.show`. |
| B36 | **[M]** | History.ets:576-586, ClassManager.ets:93-108, ClassDetail.ets:103-118 | All three use `primaryButton = 关闭` / `secondaryButton = 清除|删除` — the *destructive* action is on the secondary button, while the self-drawn overlays put 取消 white on the left and 删除 red on the right. Contradictory affordances. |
| B37 | **[M]** | ResultPanel.ets:103 + ContinuationResult.ets:103-116 | The continuation *receive* page leaves `showContinue` at its default `true`, so the user can immediately re-flow the payload they just received. |
| B38 | **[M]** | ClassManager.ets:112-118 vs ClassDetail.ets:36 | Wide mode embeds `ClassDetailContent` and phone mode pushes a route — two code paths for the same screen, with different refresh semantics (`@Prop` changes do not re-run `aboutToAppear`). |
| B39 | **[L]** | IndexWide.ets:359-361 vs IndexWideDuo.ets:574-583 | The plain wide shell has no pane `Scroll`; the duo shell wraps the same content in one. Scrolling behaves differently between two shells that look the same. |
| B40 | **[L]** | IndexWideDuo.ets:427, :433, :435-438 | `SeatsContent()`, `HistoryContent()`, `ClassManagerContent()`, `SettingsContent()` are instantiated without `bottomResult` — correct, but `Seats` is arguably the most panel-shaped tool of all and cannot use the lower pane. |
| B41 | **[L]** | VoiceRemarkBox.ets:226, :281 | When `VoiceInput.available()` is false (non-OHOS platforms) the mic icon simply disappears with no explanation (contrast with `ContinuationService.supported()` which hides 流转 silently by design). |
| B42 | **[L]** | Talk.ets:28-29 vs :137-174 | Dropdown *display* is localised but the *submitted* value is always Chinese. Deliberate (documented at Talk.ets:3) yet it means non-Chinese users cannot predict the prompt payload. |
| B43 | **[L]** | Seats.ets:323-324 | `this.rosterMode === 2 && this.classes.length === 0 \|\| (...)` relies on `&&` precedence without parentheses. Correct, but a readability trap. |
| B44 | **[L]** | Seats.ets:537 | The exported `.docx` filename is built from `t('seats.copyName')` — the *copy button* label is reused as a filename base. |
| B45 | **[L]** | ThinkPanel.ets:15 vs :16 | The comment "约 6 行小字" for `BODY_MAX_H = 120` holds only at font scale 1.0; with `FONT_PRESETS` up to 1.3 (:AppSettings.ets:32) it shows ~4 lines. |

### Not yet built / unfinished

| # | Location | Observation |
|---|---|---|
| B46 | IndexWideDuo.ets:479-480, Plan.ets:479-480 | The `bottomResult` branch is an empty stub with only a comment. The duo lower panel is fed exclusively through `ResultBus`, which is written only by `AiService` — so any result path that does not go through `AiService.chat` (e.g. a restored `PageDraft` at Plan.ets:110-113) is **invisible in the lower panel**. |
| B47 | IndexWideDuo.ets:147-156 | The duo panel's 清空 calls `ResultBus.clear()` but does not clear the page's `result`/`GenSession`/`PageDraft`, so the upper pane still shows the result the lower pane just cleared. |
| B48 | IndexWideDuo.ets:202-211 | The duo panel passes `onSave: () => this.saveLive()` but **no `onEdited` persistence beyond `patchText`** — edits never reach `PageDraft`, so they are lost on restart while the upper-pane result is not updated either. |
| B49 | Index.ets:428-440 | The display add/remove/change listeners are registered without keeping references and are torn down with `display.off('add')` etc. — unverifiable that the intended handlers are removed. |
| B50 | Seats / History / ClassManager / Settings | None of these four pages reserve a top safe inset, unlike all seven AI pages and ContinuationResult — on a notched device in full-screen their `PageHeader` sits under the status bar. |
