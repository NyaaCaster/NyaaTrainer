# CE 独立修改器：把修改项打包成"双击即用"的程序

> **要解决的问题**：内存里找到的修改项（见 `docs/02-stable-address.md`）只能在 CE 界面里用。
> 本文档把它做成一个**放在游戏目录、双击就能跑、不依赖已安装 CE** 的程序。
>
> **三份文档的分工**：
> `docs/04-ce-bridge.md` = 通道与工具集成（DSH 怎么驱动 CE）；
> `docs/02-stable-address.md` = 怎么把浮动地址固化成重启后仍有效的条目；
> **`docs/03-standalone-trainer.md`（本文）** = 怎么把那些条目打包成独立程序。
>
> **配套 skill**：`ce-standalone-trainer`（全局 `~\.agents\skills\`）—— 只放决策表与流程骨架。

- 本机环境：Cheat Engine 7.7 @ `<CE_DIR>`；实测游戏 `<GAMES_DIR>\2026-6\パンドラメイズ260427`
- 生成器：`<CE_DIR>\make_trainer.py`（**通用**，换游戏/换表都能用）
- 建立：2026-09-19；**每条都标验证状态**（✅ 实测 / ⚠️ 待验证 / ❌ 实测不可用）

---

## 0. 两种产物形态（先选一种）

| 形态 | 玩家看到什么 | 怎么做 | 成本 |
|---|---|---|---|
| **A. 完整 CE 窗口** | 一个普通 CE 主窗口，地址列表里已躺着条目（地址自动算好） | 表 + 一句自动解析脚本，直接打包 | 最低 |
| **B. 小面板修改器**（推荐交付） | 一个小窗口：属性 / 当前值 / 目标值 / 写入按钮 + 快捷按钮，CE 主窗口被隐藏 | A 之上再加一段 `createForm` 建面板的 Lua | 中等 |

**本文以 B 为主线**——A 是 B 的子集（把建面板那段删掉即可）。
`hideAllCEWindows()` 是"变成修改器样貌"的关键：它把 CE 的正常窗口全部隐藏。

---

## 1. 总流程（5 步）

```
①写表(条目+自动解析脚本[+面板]) → ②生成 exe → ③放到游戏目录 → ④玩家双击 → ⑤验证
```

| 步 | 动作 | 产出 |
|---|---|---|
| ① | 写 `.CT`：8 个条目 + `<LuaScript>`（附加进程 → 等 Mono → 解析地址 → 弹面板） | `Pandora_stable.CT` |
| ② | `make_trainer.py --table … --out …` | `PandoraTrainer.exe`（约 10 MB） |
| ③ | 复制到游戏目录 | 交付物 |
| ④ | 双击 | 面板弹出，地址自动解析 |
| ⑤ | 改一个值，看游戏里是否生效 | 验收 |

---

## 2. 阶段①：表的准备

### 2.1 `.CT` 与 `.CETRAINER` 是同一套 XML ✅

`saveTable('x.CETRAINER')` 产出的文件，开头就是 `<?xml version="1.0" encoding="utf-8"?><CheatTable UsesMono="1"…`。
所以**可以直接拿 `.CT` 当输入**，不必先让 CE 存一遍。

结构：

```xml
<CheatTable UsesMono="1" CheatEngineTableVersion="52">
  <CheatEntries> …8 个条目，地址先写 0，由脚本回填… </CheatEntries>
  <UserdefinedSymbols/>
  <LuaScript> …表脚本… </LuaScript>
</CheatTable>
```

> ⚠️ **`<LuaScript>` 里不能出现裸 `<` 和 `&`** —— 详见 §5 坑①。这是最容易翻车的一条。

### 2.2 表脚本要做的四件事

```lua
① 附加目标进程        openProcess(getProcessIDFromProcessName('Pandora.exe'))
② 等 Mono 采集器就绪   dofile(…'autorun\monoscript.lua') + LaunchMonoDataCollector()
③ 解析静态字段地址     mono_findClass + mono_class_getStaticFieldAddress + 字段 offset
④ 建面板（可选）       hideAllCEWindows() + createForm/createLabel/createEdit/createButton
```

**②③ 的完整写法与踩坑见 `docs/02-stable-address.md` §7**（类名 + 字段偏移的解析链）。

**主循环骨架**（用 CE 的 timer 轮询，因为附加/Mono 都是异步的）：

```lua
local function tick(sender)
  tries = tries + 1
  local ok, err = pcall(function()
    if (getOpenedProcessID() or 0) == 0 then
      local pid = getProcessIDFromProcessName(PROCESS_NAME)
      if pid and pid ~= 0 then openProcess(pid) end
    end
    if ensureMono() then                 -- 返回 true 表示采集器已就绪
      if apply() > 0 then                -- 解析成功，返回条目数
        sender.Enabled = false           -- 停掉自己
        buildPanel()                     -- 弹面板
      end
    end
  end)
  if not ok then say('error: ' .. tostring(err)) end
  if tries > 119 then sender.Enabled = false end   -- 60 秒放弃
end
```

### 2.3 文件日志（调试必备）✅

trainer 里的 CE **没有 `CELUASERVER` 管道**（见 §5 坑⑥），看不到它的 Lua 输出，
所以表脚本**必须自带文件日志**，否则出问题只能靠猜：

```lua
local LOG_PATH = 'C:\\Windows\\Temp\\pandora_trainer_log.txt'   -- XML 里写 \\，Lua 收到 \
local function say(s)
  print('[Pandora] ' .. tostring(s))
  pcall(function()
    local f = io.open(LOG_PATH, 'a')
    if f then f:write(os.date('%H:%M:%S ') .. tostring(s) .. '\n'); f:close() end
  end)
end
```

CE 的 Lua **保留了完整 `io` / `os` 标准库**（实测可读写文件）——排障全靠它。
脚本开头用 `'w'` 模式清空一次，避免多次运行的日志混在一起。

---

## 3. 阶段②：生成 exe

### 3.1 CE 自带功能（GUI 路径）✅ 功能存在，但不适合自动化

CE 有 **Exe Trainer Generator**（中文界面「制作 EXE 修改器」）：
菜单 `File`（文件）→ `Save As...`，**文件名带 `.exe` 扩展名**，保存时弹出向导。

| 选项 | 含义 |
|---|---|
| **巨大** gigantic | 把 CE 的 exe 和 dll 一起打包 → 真正独立，约 10~40 MB |
| **微型** tiny | 只放表数据 → 约 70 KB，但**目标机器必须已装 CE** |
| **Mono** 复选框 | 勾上才会打包 Mono 采集器（解析静态字段必需） |
| **进程** | 填游戏进程名，trainer 会自动附加 |

❌ **`saveTable('x.exe')` 不会产出文件** —— 它只把向导窗口叫起来，函数本身返回 `false`。
想自动化**必须自己合成**（下一节）。

### 3.2 无 GUI 自动生成（✅ 本机实测跑通，推荐）

原理逆向自 CE 源码 `frmExeTrainerGeneratorUnit.pas`（`btnGenerateTrainerClick`）：

```
trainer exe = standalonephase1.dat          ← 解压 stub（本身是个 PE 文件）
            + PE 资源 ARCHIVE               ← [filecount:DWORD] + raw-deflate(条目序列)
            + PE 资源 DECOMPRESSOR          ← standalonephase2.dat
   （微型模式没有 DECOMPRESSOR，ARCHIVE 直接就是表文件内容）
```

**归档条目格式**（`addFile` 的自定义格式，全部小端）：

```
[文件名长:4][文件名][目录长:4][目录][大小:4][内容]   … 逐文件重复 …
```

**模板 `.cepack` 格式**：

```
"CEPACK"（6 字节 ASCII，无 NUL） + [解压后大小:4] + raw-deflate(内容)
```

> raw deflate = zlib **去掉头尾**的流，Python 用 `zlib.decompressobj(-15)` 解、
> `zlib.compressobj(level, zlib.DEFLATED, -15)` 压。

**必须打进归档的文件**（64 位 gigantic + Mono，共 11 个）：

| 文件 | 归档内目录 | 说明 |
|---|---|---|
| `CET_TRAINER.CETRAINER` | （根） | ⚠️ **表名必须叫这个**，CE 硬编码 |
| `cheatengine-x86_64.exe` | （根） | CE 本体（18.6 MB） |
| `lua53-64.dll` | （根） | CE 的 Lua 运行时 |
| `defines.lua` | （根） | CE 自带的 AA 定义 |
| `win64\dbghelp.dll` | `win64\` | **符号解析必需**，缺了 Mono 注入报错（坑②） |
| `win64\symsrv.dll` | `win64\` | 同上 |
| `win64\dbgshim.dll` | `win64\` | 同上 |
| `autorun\monoscript.lua` | `autorun\` | Mono 支持（来自 `registerEXETrainerFeature('Mono')`） |
| `autorun\forms\MonoDataCollector.frm` | `autorun\forms\` | 同上 |
| `autorun\dlls\MonoDataCollector32.dll` | `autorun\dlls\` | 同上 |
| `autorun\dlls\MonoDataCollector64.dll` | `autorun\dlls\` | 注入目标进程的采集器 |

**生成命令**：

```powershell
python '<CE_DIR>\make_trainer.py' `
  --table '<CE_DIR>\Pandora_stable.CT' `
  --out   '<GAMES_DIR>\2026-6\パンドラメイズ260427\PandoraTrainer.exe'
```

可选参数：`--tiny`（微型，约 70 KB）、`--no-mono`、`--no-decompressor`、`--table-name`（归档内表名）、`--level`（压缩级别）。

脚本自动完成：**解 `.cepack` → 收文件 → 建归档 → 复制 stub → 写 PE 资源**。

**PE 资源写入用 Win32 API**：
`BeginUpdateResourceW` → `UpdateResourceW(RT_RCDATA, 'ARCHIVE'/'DECOMPRESSOR', …)` → `EndUpdateResourceW`。

> ⚠️ **参数顺序陷阱**：`UpdateResource(h, lpType, lpName, …)` 是 **(type, name)**，
> 而 `FindResource(h, lpName, lpType, …)` 是 **(name, type)** —— 验证资源时写反会误报"资源不存在"。

---

## 4. 阶段①之面板：小面板 UI（Lua 窗体）

### 4.1 可用的窗体 API ✅

| 用途 | API |
|---|---|
| 建窗/建控件 | `createForm(visible)` / `createLabel(owner)` / `createEdit(owner)` / `createButton(owner)` / `createPanel(owner)` |
| 窗体 | `.Caption` `.Width` `.Height` `.OnClose` `.show()` `.hide()` `.centerScreen()` `.bringToFront()` |
| **任务栏显示** | **`.ShowInTaskbar = 1`**（`stAlways`）← 见 §4.1.1 |
| 控件 | `.Left` `.Top` `.Width` `.Height` `.Caption`（Edit 用 `.Text`）`.OnClick` `.Font.Size` |
| **枚举窗体控件** | **`form.getControl(i)`** + `form.ControlCount` ← ⚠️ `form.Controls` 是 **nil** |
| 隐藏 CE 界面 | `hideAllCEWindows()` ← 变成"修改器样貌"的关键 |
| 退出 | `closeCE()` |
| 定时刷新 | `createTimer(MainForm, false)` + `.Interval` / `.OnTimer` / `.Enabled` |
| 不写进表 | `form.DoNotSaveInTable = true` |

#### 4.1.1 让面板显示在任务栏（✅ 2026-09-20 实测）

**问题**：CE 的 `createForm` 默认 `ShowInTaskbar = stDefault`，**面板不进任务栏**，
玩家切游戏/修改器只能靠 `Alt+Tab`，还容易误触游戏快捷键。

**正解**：

```lua
pcall(function() f.ShowInTaskbar = 1 end)   -- 1 = stAlways
```

**⚠️ 必须用数字，不能用枚举常量名**：LCL 的 `stDefault` / `stAlways` / `stNever`
在 CE 的 Lua 全局里**不存在**（是 `nil`）。写 `f.ShowInTaskbar = stAlways` 会**静默失败**
（不报错，回读仍是 `stDefault`）。实测映射：**`0=stDefault`、`1=stAlways`、`2=stNever`**。

**枚举 & 触发控件的写法**（调试/自动化时有用）：

```lua
-- form.Controls 是 nil，要用 getControl(i)
for i = 0, f.ControlCount - 1 do
  local c = f.getControl(i)
  local cap = nil
  pcall(function() cap = c.Caption end)
  if cap == '某个按钮' then
    c.OnClick(c)          -- 手动触发点击（参数传控件自身）
  end
end
```

### 4.2 三个"看着能用、实际不能用"的 API（✅ 全部实测）

| API | 期望 | 实测结果 |
|---|---|---|
| `getScreenDPI()` | 拿到真实 DPI 好算缩放 | ❌ **恒返回 96**（本机真实 200%，注册表 `AppliedDPI=192`）→ 按它算倍率得到 1.00，等于没缩放 |
| `form.fixDPI()` | 按 DPI 自动缩放布局 | ❌ **空操作**——它比的是"设计 PPI"与当前 DPI，而 CE 自建窗体两者相等，倍率恒为 1 |
| `Canvas.TextWidth()` | 量文字宽度 | ❌ **CE 的 Lua 里是 `nil`**（`label.Canvas` 存在但没这个方法） |
| `AutoSize = true` | 让 Label 自适应文字 | ❌ 对**未显示**的窗体不重算，恒返回默认 `65x17` |

**结论：不要在 CE 的 Lua 里试图测量文字宽度或靠 DPI 自动缩放。**
本机现象：9pt 字号 + 96 DPI 坐标 → 在高缩放桌面上文字撑破格子（压字）、按钮被裁切、窗口过小。

### 4.3 唯一可靠的度量：`Font.Height` ✅

```lua
local probe = createEdit(f)
probe.Font.Size = FS
local TH = math.abs(probe.Font.Height)   -- 16pt -> 21（像素字高）
probe.destroy()
```

字宽按字高**保守估算**（经验系数，宁大勿小）：

```lua
-- ASCII 取 0.62 倍字高；UTF-8 多字节按每 3 字节 1 个宽字符、1.15 倍字高
local function estW(s, th)
  local hi = 0
  for i = 1, #s do if s:byte(i) > 127 then hi = hi + 1 end end
  local wide = hi / 3
  local ascii = #s - hi
  return math.floor(ascii * th * 0.62 + wide * th * 1.15 + 0.5)
end
```

### 4.4 布局公式（本机实测产出 581x618，玩家反馈"效果满意"）✅

```
PAD = 14, GAP = 12
W_NAME = estW('EroPower',TH)*1.30 + 2*PAD      -- 取最长属性名
W_NUM  = estW('9999',TH)*1.60 + 2*PAD
W_EDIT = W_NUM + 2*PAD
W_BTN  = estW('写入',TH)*1.60 + 2*PAD
LBL_H  = TH + 8
BTN_H  = TH + 2*PAD
ROW_H  = TH + 2*PAD + 10
HEAD_H = TH + 2*PAD
X_NAME = PAD;  X_CUR = X_NAME+W_NAME+GAP;  X_EDIT = X_CUR+W_NUM+GAP;  X_BTN = X_EDIT+W_EDIT+GAP
FW = max(X_BTN+W_BTN+PAD, 底部按钮行总宽)
FH = PAD + HEAD_H + 行数*ROW_H + GAP + BTN_H + PAD + 8
```

**字号**：脚本顶部一个常量 `local FS = 16`，改它就能整体缩放（实测 16pt → 字高 21px → 窗口 581x618）。

> ⚠️ 所有尺寸算式**必须 `math.floor`**：Lua 5.3 里 `9 * 1.30` 是浮点数，
> 直接丢给 `string.format('%d')` 会抛 `number has no integer representation`（坑④）。

### 4.4.1 ⭐ 界面结构规范（用户 2026-09-20 定稿，指导后续所有项目）

**把面板信息按职责分成四个模块**，从上到下排列。这条规范的目标是
**让用户一眼知道哪块在改游戏、哪块是工具本身**，并**从结构上减少重复入口**。

| 模块 | 放什么 | 控件形态 |
|---|---|---|
| **① 工具条** | **修改器本体功能**（刷新、将来的重连进程/版本号等） | 顶部横条，标准软件布局 |
| **② 数值修改** | 用户**可填任意值**的数值（HP、体力…） | 数值行控件（见下） |
| **③ 状态开关** | **无数值**的通断状态（无敌模式…） | 开关（不是"开/关"两个按钮） |
| **④ 定值选项** | 取值被游戏**硬约束在有限集合**、彼此互斥、**不允许填任意值**的项 | 每个取值一个按钮 |

**命名规范（重要，用户明确）**：第 ④ 类叫 **「定值选项」**，不是「定制选项」。
含义是"**取值已定**、只能从给定档位里挑"，与"数值修改"（用户可填任意值）相对。

#### 数值修改的控件排布（用户定稿）

```
[属性名]  [当前值]  | [0] [-] [+] [MAX] | [设定值输入框] [应用] | [锁定]
```

**分组逻辑（关键）**：

- **`0` / `-` / `+` / `MAX` 是一组** —— 它们**直接改值，不需要"应用"**
- **输入框 + `应用` 是一组** —— 输入的值**需要提交才生效**
- 两组之间留间隔，视觉上分开

**各控件规格**：

| 控件 | 规格 | 说明 |
|---|---|---|
| `-` `+` | **正方形**（宽=高） | 用户要求；整列按正方形边长对齐，排版工整 |
| `0` | 正方形 | **仅"当前值"性质的项开放**；**上限性质隐藏**（`HP上限=0` 可能让游戏出错） |
| `MAX` | 正方形 | **仅定义了"运行时上限"的项开放**；无上限的项隐藏。**语义 = 把当前值改为运行时上限值**（取上限项的值，不做额外裁剪） |
| 输入框 | 约"十个 9"宽度 | 名字列则按最长标签动态算 |
| `应用` | 够 2 个字 | 原名"写入"；改叫"应用"更贴合"提交输入"的语义 |
| 锁定 | **正方形状态开关**（不是按钮样式） | 用 `□`/`■` 自绘符号表达二态；**省宽度**，且与"状态开关"风格统一 |

> **隐藏按钮要保留占位**（用户要求）：不创建该控件即可，坐标天然留空 ——
> 这样各行的按钮仍是**矩阵对齐**的，不会因某项缺按钮而错位。

#### 状态开关与定值选项

| 类型 | 控件 | 为什么不用别的 |
|---|---|---|
| **状态开关** | **开关**（`□`/`■` 自绘，或勾选框） | 二态用"开/关两个按钮"是**重复入口**且占宽度；一个开关就够 |
| **定值选项** | **每个取值一个按钮** | 取值互斥且有硬约束，**不给输入框**（避免用户填非法值） |

#### 模块归属的硬性要求

1. **状态开关类项目不得同时出现在「数值修改」里** —— 否则又是多入口。
   （实测：无敌模式原先在数值区，又加了开关，属于重复）
2. **工具条只放"与游戏无关"的功能** —— 刷新、重连进程、版本号等。
   与改值相关的按钮不要放这里，避免用户理解混淆。
3. **底部只放一次性动作** —— 可以做「重置锁定」（清理动作）、「全部拉满」这类批量操作，
   但**不要放任何锁定类按钮**（见 §4.5.1）。

#### 关于「游戏信息监控」模块（非必须，按需询问用户）

有些项目需要一块**只读**的监控区，用于显示**游戏 UI 上不显示的信息**
（隐藏要素、被游戏隐藏的敌人数值、统计等）。

**规范**：

- **不是必开发组件** —— 先判断本项目是否有必要，**并征询用户同意**再开发
- 定义：**用户不能修改，但可以看到游戏没显示出来的信息**
- 若**每行的"当前值"列已能满足监控需求**，就不要另加汇总行（重复展示 = 多一处维护面）

### 4.5 面板行为约定

| 约定 | 做法 | 理由 |
|---|---|---|
| 关闭面板 = 退出修改器 | `f.OnClose = function(sender) pcall(closeCE) end` | 符合商业修改器习惯；CE 主窗口已隐藏，留着也没用 |
| 面板不进表 | `f.DoNotSaveInTable = true` | 避免每次 `loadTable` 都重建控件、表文件被污染 |
| 当前值自动刷新 | 500ms timer 只改 `label.Caption` | 不碰输入框，避免打断玩家输入 |
| 输入框用完即清 | `writeField()` 里 `edit.Text = ''` | 一眼看出"已写入" |
| 顺手加「关闭」按钮 | 底部第 4 个按钮 | 高缩放下右上角 X 不好点 |

#### 4.5.1 ⭐ 锁定功能只能有一个入口（用户 2026-09-20 明确要求，作为模板约定）

**原则**：

> **每个数值条目的锁定，只由该行自己的 `□` 按钮负责，唯一入口。**
> 底部快捷按钮区**只放一次性动作**（补满、开关某状态、设某个值…），
> **不放**任何锁定类按钮 —— 包括「全部锁定 / 全部解锁」，
> 以及「<某项>锁定N% / <某项>解锁」这类与条目自身锁定重复的按钮。

**为什么（实测踩坑）**：

某项目里同时在两处提供性快感的锁定：

| 入口 | 设置的变量 |
|---|---|
| 行内 `□` 按钮 | `LOCKS['Arouse']` |
| 底部「快感锁定50%」 | `AROUSE_LOCK` |

结果两条路各自为政：

- 用**行内 `□`** 锁定时，通用重设循环遍历到 `LOCKS['Arouse']`，
  却用**通用写内存**的方式去写 —— 而该数值**必须调游戏方法**才有效，
  于是"看起来锁了、实际没锁"
- 「快感锁定50%」走的是正确路径，但**它设的变量在行内路径里不被识别**

**这类问题会在任何项目、任何"多入口锁定"的设计里重演**，而且症状隐蔽
（界面显示正常，值却在漂）。**消除重复入口 = 从结构上消灭这类 bug**，
同时也降低了后续维护成本（不必保证多处状态同步）。

**落地写法**：

```lua
-- 每个数值条目一套锁定状态，全局唯一
local LOCKS = {}     -- key -> true/false
local LOCKVAL = {}   -- key -> 目标值

-- 重设循环：只认 LOCKS
local function tickLocks()
  for i = 1, #WANT do
    local k = WANT[i].key
    -- 需要调游戏方法才能改的项，要排除在通用写内存之外，走它自己的重设函数
    if k ~= 'Arouse' and LOCKS[k] and ADDR[k] and LOCKVAL[k] then
      if rd(WANT[i], ADDR[k]) ~= LOCKVAL[k] then wr(WANT[i], ADDR[k], LOCKVAL[k]) end
    end
  end
  if LOCKS.Arouse and LOCKVAL.Arouse then
    setArouse(LOCKVAL.Arouse)      -- 该项的正规重设路径
  end
end
```

> **注意最后那句**：需要"调游戏方法"的数值，**必须排除在通用写内存循环之外**，
> 否则通用循环会把无效的写操作当成"已在处理"，而专用分支又因为开关不同而不执行。

**配套的显示约定**：锁定中**一律显示真值**（不是目标值）；
与目标不符时**标红**。否则锁定失效时界面照样显示目标值，把失败掩盖掉。

### 4.6 面板骨架

```lua
local function buildPanel()
  if panel ~= nil then return end
  pcall(hideAllCEWindows)                       -- 先藏 CE，再建自己的窗

  local f = createForm(false)
  pcall(function() f.DoNotSaveInTable = true end)
  f.Caption = 'パンドラメイズ 修改器'
  setFont(f)
  -- …读 TH、算布局、建控件（见 §4.3/4.4）…
  f.OnClose = function(sender) pcall(closeCE) end
  pcall(function() f.centerScreen() end)

  panel = f
  f.show()
  refresh()                                     -- 立即填一次当前值
end
```

---

### 4.7 退出行为与残留进程（✅ 实测，**必读**）

### 4.7.1 三段式启动器 —— 进程结构

CE 官方 trainer 模板生成的是一个**三段式启动器**，一定要认清这三层：

```
① <游戏目录>\XXX修改器.exe                     ← stub：解压 + 启动（**无窗口**）
   ② %TEMP%\cetrainers\CETxxxx.tmp\...         ← 解压出的启动器（**无窗口**）
      ③ ...\extracted\...                       ← 真正的 CE（**有窗口的那个**）
```

父子链完整：`① → ② → ③`。在任务管理器里看到三个同名进程是**正常现象**，不是 bug。

> ⚠️ **只关 ③ 的窗口，①② 不一定会跟着退出** —— 官方模板没有看门狗。
> 残留进程会**继续占用 Mono 采集器通道**，导致下次启动修改器时注入失败
> （`Library Injection failed or invalid module`，或解析不出地址）。

### 4.7.2 实测：哪种关闭方式会残留

在 `淫白の御供` 上反复实测（每次从干净基线起，关闭后查进程）：

| 关闭方式 | 结果 |
|---|---|
| 面板右上角 **X** | ✅ 整条链干净退出 |
| 面板底部 **「关闭」按钮** | ✅ 干净退出（日志出现 `exit: best-effort cleanup`） |
| 外部 **WM_CLOSE**（等效点 X） | ✅ 干净退出 |
| 外部 **`Stop-Process` 强杀 ③** | ✅ ①② 随之退出 |

**结论：正常关闭路径下不会残留。** 「关闭」按钮走的 `quitTrainer()` 会先清理再退出，
日志里有 `exit: best-effort cleanup` 一行可作证据。

> 但仍然**不能假设它永远干净**：崩溃、任务管理器结束、断电、强杀 stub 等异常路径
> 仍可能留下 ①②。所以下面这套"兜底"值得做，但它是**保险**，不是必需品 ——
> **不要因为怕残留就把每个项目都复杂化**。

### 4.7.3 表脚本里的退出处理（推荐做法）

```lua
-- 统一的"退出修改器"入口 —— 面板的 X 和「关闭」按钮都指向它
local function quitTrainer()
  pcall(tryCleanup)      -- 尽力而为的一次清理，失败无所谓、不阻塞
  pcall(closeCE)
end

-- 面板关闭
f.OnClose = function(sender) quitTrainer() end
-- 底部按钮
{ cap = '关闭', fn = quitTrainer }

-- 兜底：CE 无论怎么退都会走这里（实测确认 OnClose 会触发）
pcall(function()
  if MainForm ~= nil then
    local prev = MainForm.OnClose
    MainForm.OnClose = function(sender)
      pcall(tryCleanup)
      if prev then pcall(prev, sender) end
    end
  end
end)
```

### 4.7.4 ❌ 为什么不能在 CE 内部真正清理（实测全败）

直觉做法是退出前用 `os.execute` 起个 PowerShell 去杀残留。实测：

| 尝试 | 结果 |
|---|---|
| `MainForm.OnClose` 能否触发 | ✅ **能**（写文件验证，确认退出前会执行） |
| `os.execute` 在 CE 里可用吗 | ✅ 可用（`echo` 写文件成功） |
| **CE 调 `powershell` 做清理** | ❌ 子进程**随 CE 一起被杀**（同一作业对象），清理没跑完就死了 |
| 改用 `Invoke-CimMethod Win32_Process.Create` 脱离 | ❌ 外层 PowerShell 仍在作业里，照样被杀 |
| 改用 `wmic process call create` | ❌ 文件没生成（CE 的 `os.execute` 环境受限） |
| 改用 `schtasks` 一次性任务 | ❌ 创建/运行都失败（同上） |

**结论：CE 的 `os.execute` 发不起"父进程退出后仍存活"的进程。**
所以 CE 内部只能"尽力而为"，**真正可靠的外部清理需要由启动方做**。

### 4.7.5 ✅ 可选的兜底：外部看门狗启动器

如果确实需要"无论怎么退都清干净"，让**启动修改器的那一方**负责善后（监听 stub 退出）：

```powershell
Run-Cleaner                                    # 启动前先清一次旧残留
$p = Start-Process $exe -WorkingDirectory $here -PassThru
$p.WaitForExit()                               # ← 盯住 ① 的 pid（整条链的根）
Run-Cleaner                                    # 它退出后立刻清理整条链
```

**清理脚本**（按可执行路径匹配，排除自身）：

```powershell
$procs = Get-CimInstance Win32_Process -Filter "Name = '$ProcessName.exe'" |
  Where-Object { $_.ProcessId -ne $PID }
$chain = $procs | Where-Object { $_.ExecutablePath -like '*\cetrainers\*' }
Stop-Process -Id $chain.ProcessId -Force       # 杀解压链，stub 会随之自然退出
# 顺手删掉已无进程占用的 %TEMP%\cetrainers\CETxxxx.tmp（每个几十 MB）
```

> ⚠️ **`Get-Process` 的 `.Path` 常返回空**（权限受限时），必须用
> **`Get-CimInstance Win32_Process` 的 `ExecutablePath`** 才拿得到路径。

**本机产物**（`<GAMES_DIR>\2026-9\淫白の御供\`，作为可选保险一起交付）：

| 文件 | 作用 |
|---|---|
| `启动淫白の御供修改器.bat` | 双击入口（GBK 编码），可选 |
| `启动淫白の御供修改器.ps1` | 看门狗启动器（带 BOM） |
| `close_iyohaku_trainer.ps1` | 清理脚本（带 BOM），可独立运行 |

### 4.7.6 ⚠️ 编码坑：`.ps1` 中文进程名必须带 UTF-8 BOM

Windows PowerShell 5.1 执行 `.ps1` 时**无 BOM 就按 ANSI/GBK 解析**。脚本里的中文进程名
（`淫白の御供修改器`）会变乱码 → `-Filter` 匹配不到 → **脚本静默什么都不做**
（退出码 0、无任何输出，极具迷惑性）。

```powershell
[IO.File]::WriteAllText($path, $content, (New-Object Text.UTF8Encoding($true)))  # 带 BOM 写
$b = [IO.File]::ReadAllBytes($path); ($b[0..2] | % { $_.ToString('X2') }) -join ' '  # 应为 EF BB BF
```

> `.bat` 恰好相反：cmd.exe 按本地代码页解析，中文要写成 **GBK（代码页 936）**，
> 并在开头加 `chcp 65001 >nul` 让后续 PowerShell 输出不乱码。

### 4.7.7 ⚠️ DPI 陷阱：同一个脚本在不同会话下尺寸差一倍

**实测对比**（同一个修改器、同一台机器）：

| 启动者 | `textH`（实测字高） | 面板逻辑尺寸 |
|---|---|---|
| DSH（Session 0）起的 CE | **21** | 789×710 |
| **用户原生双击**（用户会话） | **43** | **1640×895** |

原因：本机是 **200% 缩放**（`AppliedDPI = 192`）。从 DSH 的 Session 0 启动时，
CE 读不到用户会话的字体设置，按 100% 度量算；用户原生启动才是真实值。

**影响**：布局按字高推算，字高翻倍 → 面板尺寸翻倍。
逻辑 1640 在 200% 下等于**物理 3280px**，而屏幕物理宽只有 1024。

> 💡 **不要在 DSH 里验证面板尺寸** —— 你会看到一个"正常"的小面板，
> 而用户实际看到的是两倍大的版本。**面板尺寸必须在用户会话里实测**。
>
> 修正方向：布局的可用宽度应当用「**物理宽 ÷ 缩放比 = 逻辑宽**」（本机 1024 ÷ 2 = **512 逻辑像素**），
> 而不能直接拿 `getScreenWidth()`（它给的是物理量）当上限。

#### 补充实测：两个"屏幕宽度"API 都不可信（✅ 2026-09-20）

| 环境 | `getScreenWidth()` | `MainForm.Width` | `Font.Height`(12pt) | 面板落定尺寸 |
|---|---|---|---|---|
| DSH / Session 0 起的 CE | **1024** | 799 | **16** | 1562×928（未压缩） |
| 用户桌面会话（打包后的 trainer） | **3840** | 799 | **32** | — |

**两个 API 的问题**：

- `getScreenWidth()`：返回**物理**像素，且**跨会话还不一致**（本机 1024 vs 3840）
- `MainForm.Width`：是 **CE 主窗口**的尺寸（不是屏幕宽），两个会话**都是 799**，完全不可用

**最终采用的策略**（简单且稳）：

1. 面板宽度**由内容决定**
2. 上限取**固定值**（本项目取 **1800**，按用户会话 1920 逻辑宽留余量）
3. 压缩时给**名字列设保底宽度**：绝不窄于最长标签所需（防止标签被截断）
4. 字号取小一点（本项目 **12**）

> **教训**：与其猜屏幕宽度猜错导致标签截断，不如给一个宽松的固定上限 ——
> 面板是独立窗口，正常屏幕都远宽于它。

---

## 5. 坑位速查（全部实测）

| 坑 | 现象 | 正解 |
|---|---|---|
| **① 表 LuaScript 里有裸 `<`** | `loadTable` 返回 `true`，但 `getAddressList().Count == 0`——**脚本一声不响地没执行** | `.CT` 是 XML，`<` 必须避开或写 `&lt;`。用 `>` 改写条件即可（`if x > 3 then` 替 `if x < 4 then`） |
| **② trainer 缺 `win64\dbghelp.dll`** | Mono 注入报 `Library Injection failed or invalid module`（其实 DLL 已经注进目标进程了） | 把 `win64\dbghelp.dll` / `symsrv.dll` / `dbgshim.dll` 一起打包；注入后补 `reinitializeSymbolhandler(true)` |
| **③ `saveTable('x.exe')` 不产出文件** | 向导弹出来了，但目录里什么都没有，函数返回 `false` | 用 `make_trainer.py` 自己合成（§3.2） |
| **④ `string.format('%d', 浮点)`** | `bad argument #3 to 'format' (number has no integer representation)` | 所有尺寸算式套 `math.floor` |
| **⑤ 已注入的 Mono 采集器不卸载** | 关掉 CE 后，游戏里 `MonoDataCollector64.dll` 仍在；后来者注入不进去 | 验证独立修改器时**先关掉其它 CE、并重启一次游戏** |
| **⑥ trainer 的 CE 没有 Lua 管道** | `ce-lua.ps1` 连不上它，看不到 Lua 输出 | 正常现象（它的 `main.lua` 是原版）。调试靠表脚本的**文件日志**（§2.3） |
| **⑦ 两个 CE 同时附加同一游戏** | 后启动的那套 Mono 用不了 | 同一时间只留一个修改器/CE |
| **⑧ 解压目录里的表文件不见了** | `extracted\CET_TRAINER.CETRAINER` 在 CE 启动后消失 | **正常**——CE 读入后自行清理 |
| **⑨ 覆盖 exe 时 `Permission denied`** | 生成失败，报文件被占用 | 先关掉正在运行的修改器（`Stop-Process -Name PandoraTrainer`），stub 进程会锁住 exe |
| **⑩ `UpdateResource` / `FindResource` 参数写反** | 验证时误报"资源不存在" | 前者是 `(type, name)`，后者是 `(name, type)` |
| **⑪ 重启游戏后 Mono 采集器掉线** | `mono_AttachedProcess = nil` | 重新 `LaunchMonoDataCollector()` 并等约 5 秒；只 `openProcess` 不够 |
| **⑫ 关掉修改器后进程残留** | 三个同名进程还活着，占着 Mono 采集器通道 | **用看门狗启动器启动**（§4.7）；CE 内部发不起脱离式清理进程 |
| **⑬ `.ps1` 中文进程名匹配不上** | 脚本静默无输出、退出码 0 | `.ps1` 必须带 **UTF-8 BOM**（PS 5.1 无 BOM 按 ANSI 解析）；`.bat` 反之用 GBK |
| **⑭ `Get-Process.Path` 返回空** | 按路径筛进程筛不到 | 用 `Get-CimInstance Win32_Process` 的 `ExecutablePath` |
| **⑮ 面板不在任务栏** | 切游戏/修改器只能 `Alt+Tab`，易误触游戏快捷键 | `f.ShowInTaskbar = 1`（**必须用数字**，枚举常量名在 CE 里是 nil 会静默失败），见 §4.1.1 |
| **⑯ `form.Controls` 是 nil** | 想遍历控件改不了 | 用 `form.getControl(i)` + `form.ControlCount` |
| **⑰ 尺寸算法用了 `getScreenWidth()` / `MainForm.Width`** | 面板被压缩到**标签截断**（两会话下值都不同） | 别拿它们当屏幕宽度，见 §4.7.7 的实测数据；宽度由内容决定 + 固定上限 + 名字列保底 |
| **⑱ LuaScript 里有裸 `&`** | 严格 XML 解析器报 `invalid token`（CE 自身容错，但规范上不合法） | 位运算改取模/取整：`v % 256`、`v = math.floor(v/256)`。**注释里的裸字符同样会坏事** |
| **⑲ Lua `local` 作用域** | 日志显示解析成功，运行逻辑却报"未解析" | 共享变量**统一声明在脚本最前面**。`local` 是词法作用域，函数定义时不可见的 local 会退化成**读全局**（一边写 local、一边读 global）。建议加自动自查（§7.1） |
| **⑳ 高频调托管方法导致游戏崩溃** | 偶发崩溃（`mono_invoke_method` 走每线程管道，失效时继续调用会写坏管道） | 调用前 `pipeOK()` 自检；一次只做一个操作；周期调用间隔 ≥200ms 并限流。详见 `01-mono-recon.md` §8.4 |
| **㉑ CE 里面板尺寸正常、用户那边截断** | 两个会话的 `Font.Height` 差约一倍 | **面板尺寸只能在用户会话目视确认**（§4.7.7） |
| **㉒ 控件坐标算对了、面板却被裁** | 布局按 `FW=1758` 算，但面板实际只有 `1038` 宽，右侧按钮全看不见 | CE 窗体**实际渲染宽度受屏幕限制**（实测 `getScreenWidth()=1024` → 面板最多 1038）。宽度上限要取 `getScreenWidth()` 之类**实际可用的值**，不能凭内容无限展开 |
| **㉓ `FW` 计算漏了某个区** | 面板下方某个区的按钮**超出右边界、界面上完全看不到** | `FW = max(...)` 要把**每个横向布局区**的宽度需求都算进去（数值行 / 快捷按钮行 / 其它自定义区），漏一个就会裁 |
| **㉔ 压缩时漏缩放某个控件宽** | 最右侧的按钮仍溢出 | 压缩分支里要把**所有**会参与横向排布的宽度都乘 `k`（包括自定义区的按钮宽），漏一个就溢出 |
| **㉕ 两个锁定入口** | 一个入口能锁、另一个"锁定中却没重设" | **锁定只保留一个入口**（每个数值自己的 `□`），快捷区只放一次性动作。见 §4.5.1 |
| **㉖ 显示"锁定中就显示目标值"** | 锁定失效时界面照样显示目标值，**把失败掩盖** | 锁定中也显示**真值**；与目标不符时**标红** |
| **㉗ Lua 数组下标 1-based vs 业务 0-based** | 循环 `for lv = 0, 3` 取值，整体错一格，最后一档永远取不到 | 用显式映射 `{ [0]='a', [1]='b' }`，不要依赖数组顺序 |
| **㉘ 周期任务静默失败、日志空白** | 手动能改、定时器里的重设从不生效，且没任何日志 | ① `pcall(fn)` 会吞掉返回值 —— 周期任务**成功/失败都要留痕**（含心跳）；② CE 定时器**可能跑在没管道的线程**上，`pipeOK()` 要能**建立**管道而不只是检查（见 `01-mono-recon.md` §8.4） |

---

## 6. 实测数据（两个项目）✅

### 6.1 `パンドラメイズ260427`（2026-09-18/19）

**数据形态**：静态字段（Mono JIT 内联绝对地址）

| 项 | 结果 |
|---|---|
| 产物 | `PandoraTrainer.exe` **10,041,856 字节**（gigantic + Mono + 面板） |
| ARCHIVE 资源 | 9,755,248 字节 / 11 个文件 |
| DECOMPRESSOR 资源 | 230,400 字节（`standalonephase2.dat`） |
| stub | `standalonephase1.dat` 55,296 字节（`.cepack` 28,924 → 解出） |
| 运行链路 | 双击 stub → 解压到 `%TEMP%\cetrainers\CET<id>.tmp\extracted\` → 拉起 CE 并传入表 |
| 实测命令行 | `extracted\PandoraTrainer.exe "…\extracted\CET_TRAINER.CETRAINER" "-ORIGIN:<GAMES_DIR>\2026-6\パンドラメイズ260427\"` ✅ |
| 典型日志 | `resolved 8 entries, static_data=24D6418BEA0` → `panel built: 581x618` → `panel created` |
| 玩家验收 | 面板改值、快捷按钮、关闭 —— **用户确认"效果满意"** ✅ |

> 静态字段地址随重启变化（`1AFE3EABEA0` → `2DB5D13BEA0` → `24D6418BEA0`），脚本每次都能重新算对。

### 6.2 `淫白の御供`（2026-09-19）

**数据形态**：实例字段（沿单例链取 + 二次偏移）

| 项 | 结果 |
|---|---|
| 产物 | `淫白の御供修改器.exe` **约 10.04 MB**（gigantic + Mono + 面板 + 锁定） |
| 定位链 | `GameManager.Instance → +0x20 → GameData → +字段偏移` |
| 托管字段 | HP `+0x18` / MaxHP `+0x1C` / MP `+0x20` / MaxMP `+0x24` / Day `+0x30` / DaysLeft `+0x2C` / Stage `+0x28` / Deaths `+0x34` |
| 新增功能 | **HP/MP 锁定**（200ms timer 回写）、每行 `+/-` 步进、HP 比例实时显示 |
| 跨进程验证 | 重启游戏后 `GameData` 从 `25AAFEDFAE0` → `20E3B426A20` → `1D8C4C05C00`，**每次都能解析对** ✅ |
| 退出行为 | 点 X / 点「关闭」/ WM_CLOSE / 强杀 ③ —— **均无残留** ✅ |
| 已知遗留 | 面板在 200% DPI 下逻辑尺寸 1640×895（见 §4.7.7），用户暂不修改 |

**两例沉淀的可复用资产**：

- `make_trainer.py` —— 通用生成器，换表即用
- 两种数据形态的解析框架样板（`Pandora_stable.CT` / `iyohaku_stable.CT` + `.lua`）
- 退出处理 + 可选看门狗（§4.7）
- 锁定功能的实现（§4.5 扩展）

---

## 7. 验证与交付清单

### 7.1 生成侧自检（每次生成后都做）

```powershell
# 1) 表的 LuaScript 没有裸 < / &（XML 必须能解析）
python -c "import re,xml.etree.ElementTree as ET; p=r'<.CT路径>'; raw=open(p,encoding='utf-8').read(); txt=re.search(r'<LuaScript>(.*?)</LuaScript>',raw,re.S).group(1); print([l for l in txt.split(chr(10)) if '<' in l or '&' in l]); ET.parse(p); print('XML OK')"
```

**2) Lua 作用域自查**（专查「使用早于 local 声明」）—— 强烈建议做：

```powershell
python check_lua_scope.py <提取出的脚本.lua>
```

**为什么必须查**：这是**最隐蔽的一类 bug**。实测踩过一次，症状是
**日志里明明显示解析成功，运行逻辑却报"未解析"**：

```lua
local function familyService()
  local p = PLAYER_ADDR      -- 行 174：使用
end
...
local PLAYER_ADDR = nil      -- 行 317：声明（在使用之后！）
```

Lua 的 `local` 是**词法作用域** —— `familyService` 定义时 `PLAYER_ADDR` 这个 local 还不存在，
于是函数体里读到的是**全局** `_G.PLAYER_ADDR`（永远 nil）；而后面写的是那个 local。
**一边写 local、一边读 global，永远读不到**，且完全不报错。

> 已通用化的检查脚本见仓库 `src/check_lua_scope.py`（思路：收集所有 `local` 首次声明行号，
> 再扫每个变量的裸读取，报告「使用行号早于声明行号」的项；需排除函数参数与 for 循环变量）。

**3) 结构自检**：条目数对得上、脚本能 `loadstring` 通过（CE 里试跑一次，看文件日志）。

### 7.2 运行侧验证（**必须干净环境**）

1. 关掉所有 CE 与旧修改器进程
2. **重启一次游戏**（清掉已注入的旧采集器 —— 坑⑤）
3. 双击独立修改器（**用户原生双击**，不要只在 DSH 里验证）
4. 看日志：应为 `resolved N entries` + `panel created`
5. 改一个数值 → 游戏里确认生效
6. **看面板有没有超屏**（§4.7.7：DSH 会话与用户会话的 DPI 度量差一倍，尺寸必须在用户会话看）
7. 关闭修改器 → **确认无残留进程**（§4.7）
8. **清理自己启动的一切**（§7.4）—— 进程、临时目录、探针脚本

### 7.3 交付物清单

| 交付物 | 位置 |
|---|---|
| 独立修改器 exe | `<游戏目录>\<游戏>修改器.exe` |
| 表 + 稳定地址脚本（可再生成） | `<CE_DIR>\<代号>_stable.CT` / `.lua` |
| 生成器（通用，与游戏无关） | `<CE_DIR>\make_trainer.py` |
| 留档副本 | `examples/\`、`src/\` |

> **关于配套脚本**：退出清理/看门狗脚本（§4.7.5）属于**可选保险**。
> `淫白の御供` 项目实测正常关闭路径不残留，用户已选择**全部删除**，
> 修改器现在是不依赖任何外部文件的单文件。
> 是否需要它，按项目实际需求决定，**不要默认就加**。

**本机已完成的两个项目**：

| 游戏 | 修改器 | 表 | 数据形态 |
|---|---|---|---|
| `パンドラメイズ260427` | `<GAMES_DIR>\2026-6\パンドラメイズ260427\PandoraTrainer.exe` | `Pandora_stable.CT` | 静态字段 |
| `淫白の御供` | `<GAMES_DIR>\2026-9\淫白の御供\淫白の御供修改器.exe` | `iyohaku_stable.CT` | 实例字段 |

### 7.4 ⭐ 清理规范（强制，含血泪教训）

> **教训**：2026-09-19，为验证"删掉外部脚本后修改器还能不能跑"，我启动了修改器，
> **检查完忘了关**，留下 3 个进程。用户此时已关掉自己的游戏和修改器，看到进程后
> 以为是残留 bug。**悬空进程会污染用户判断，还会占着 Mono 采集器通道影响下次测试。**

#### 铁律一：谁启动，谁关闭

验证必须**"启动 + 检查 + 关闭"三步一体**，不要跨消息留悬空进程。

```powershell
# ✗ 反例（本次失误）：启动了，检查完没下文
Start-Process $trainer; Start-Sleep 50; Get-Content $log

# ✓ 正例：同一段里收尾
$p = Start-Process $trainer -PassThru
Start-Sleep -Seconds 50
Get-Content $log                       # 检查
Get-Process -Name '<修改器名>' -ErrorAction SilentlyContinue | Stop-Process -Force   # 关闭
```

若确实需要分离（要等用户操作），**必须在回复里写明"我启动了 X，稍后会关"**，并在下一步立即关闭。

#### 铁律二：每次涉进程的操作，收尾查四样

```powershell
# 1) 遗留进程（修改器 / CE / 游戏）
Get-CimInstance Win32_Process |
  Where-Object { $_.Name -match '修改器|cheatengine|<游戏名>' } |
  Select-Object ProcessId,Name,ExecutablePath | Format-Table -AutoSize -Wrap

# 2) 临时解压目录（每个约 30 MB）
foreach ($t in @("$env:TEMP\cetrainers", 'C:\Windows\Temp\cetrainers')) {
  if (Test-Path $t) { Get-ChildItem $t -Directory | Select-Object FullName }
}

# 3) 自己起的调试用 CE
Get-Process -Name 'cheatengine-x86_64*' -ErrorAction SilentlyContinue

# 4) 写在 %TEMP% 的探针脚本/测试文件
Get-ChildItem $env:TEMP -Filter '*test*' -ErrorAction SilentlyContinue
```

#### 铁律三：不要替用户关他在用的程序

> **同一天的第二个教训**：我为"清出干净测试基线"，一条命令里把**用户正在玩的游戏**
> 也 `Stop-Process -Force` 了。用户看到的是**游戏闪退**，并一度怀疑是修改器把游戏搞崩的。

- **只清自己启动的东西**；用户的游戏 / CE / 修改器 —— **先问再动**
- 要动就说清楚：*"为了做隔离测试，需要关掉你正在运行的游戏，可以吗？"*
- 拿不准就只做**只读检查**（`Get-CimInstance` 查状态）
- **万一误关**：立刻承认是我做的、说明原因，不要让用户以为是他自己的软件出了问题

#### 交付物 vs 临时物

| 类别 | 例子 | 处置 |
|---|---|---|
| **交付物** | 修改器 exe、表 `.CT`、留档副本 | **保留**（游戏目录 / `GameMod\tables\`、`scripts\`） |
| **临时物** | 进程、`cetrainers` 目录、探针脚本 | **用完即清** |
| **证据物** | 运行日志（`*_trainer_log.txt`） | 排障期保留，结论落文档后可清 |

---

## 8. 命令速查

```powershell
$ce = '<CE_DIR>'

# 生成独立修改器
python "$ce\make_trainer.py" --table "$ce\Pandora_stable.CT" --out '<游戏目录>\PandoraTrainer.exe'

# 微型版（约 70 KB，但目标机器必须已装 CE）
python "$ce\make_trainer.py" --table "$ce\Pandora_stable.CT" --out '<输出.exe>' --tiny

# 看运行日志（trainer 没有 Lua 管道，只能看文件）
#   路径随启动者会话不同：DSH 起的在 C:\Windows\Temp\，用户原生启动的在 %TEMP%\
Get-Content "$env:TEMP\iyohaku_trainer_log.txt"
Get-Content 'C:\Windows\Temp\pandora_trainer_log.txt'

# 检查残留进程（应只剩你自己在用的那些）
Get-CimInstance Win32_Process | Where-Object { $_.Name -match '修改器' } |
  Select-Object ProcessId,ParentProcessId,ExecutablePath | Format-Table -AutoSize -Wrap

# 生成前先释放被占用的 exe
Get-Process -Name PandoraTrainer -ErrorAction SilentlyContinue | Stop-Process -Force

# 验证资源（注意 FindResource 的参数顺序是 name, type）
python "$env:TEMP\verify_trainer.py"
```

---

## 9. 换一个游戏怎么做（复用清单）

1. 先按 `GameMod\docs\CE稳定地址方法.md`（或数据在 Mono 里时直接走 `Mono内核API探索修改法.md`）找到**稳定锚点**（类名 + 字段偏移 / 指针链 / AOB）
2. 复制一份最接近的表（静态字段型抄 `Pandora_stable.CT`；实例字段型抄 `iyohaku_stable.CT`），改三处：
   - `<CheatEntries>` 的条目（名称 + 个数）
   - 表脚本的 `PROCESS_NAME`（目标进程名）
   - 表脚本的 `WANT`（显示名 → 静态字段名）
3. 改面板标题 `f.Caption`
4. 跑 `make_trainer.py` 生成、按 §7 验证

> `make_trainer.py` **与游戏无关**，任何表都能打包 —— 不用改。
