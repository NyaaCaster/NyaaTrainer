---
name: ce-standalone-trainer
description: '把 Cheat Engine 的修改项打包成一个放在游戏目录、双击即用、不依赖已安装 CE 的独立修改器 exe（可带小面板 UI：属性/当前值/目标值/写入按钮）。当用户要求"做成独立修改器""打包成 exe""双击就能用""不要每次开 CE""给游戏做个修改器""生成 trainer""小面板/界面修改器"时使用。Use when the user asks to 打包 CE 修改器 / 生成独立 exe 修改器 / standalone trainer / exe trainer / make_trainer / 把修改项做成程序，or mentions ce trainer / 小面板修改器 / 双击即用的修改器。'
---

# CE 独立修改器（ce-standalone-trainer）

把 CE 里调好的修改项，做成 `<游戏目录>\XXX修改器.exe` —— 双击就跑，不用开 CE。

> **本 skill 只给决策与流程骨架**；格式逆向细节、完整代码、坑位表、实测数据在
> **`docs/03-standalone-trainer.md`**。
> 上游依赖：稳定地址怎么找 → `docs/02-stable-address.md`；通道怎么用 → `docs/04-ce-bridge.md`。

## 触发条件

- 要把修改项**打包成独立程序**放游戏目录
- 抱怨"**每次都要开 CE 太麻烦**"、"想双击就能改"
- 要求**给某个游戏做个修改器**（trainer）
- 要求**小面板/界面**（而不是 CE 那种地址列表）
- 已经用 `ce-stable-address` 找到了稳定条目，现在要"做成产品"

## 前置条件

| 条件 | 说明 |
|---|---|
| **已有稳定的修改项** | 类名+字段偏移 / 指针链 / AOB，且**经过重启验证**。没有就先走 `ce-stable-address` |
| 一份表（`.CT`） | 含条目 + `<LuaScript>`（自动附加进程 + 解析地址 + 可选弹面板） |
| `<CE_DIR>\make_trainer.py` | 本机通用生成器，**与游戏无关**，直接复用 |
| CE 安装目录完整 | 生成时要读 `cheatengine-x86_64.exe`、`.cepack` 模板、Mono 文件等 |

## 两种产物（先选一种）

| 形态 | 玩家看到 | 成本 |
|---|---|---|
| **A. 完整 CE 窗口** | 普通 CE 主窗口，地址列表里条目已算好 | 最低（表里不加建面板的代码即可） |
| **B. 小面板修改器**（推荐） | 小窗口：属性 / 当前值 / 目标值 / 写入 + 快捷按钮；CE 界面被隐藏 | 中等（多一段 `createForm` 代码） |

## 5 步流程

| 步 | 动作 | 产出 |
|---|---|---|
| ① | 写表：条目 + `<LuaScript>`（附加进程 → 等 Mono → 解析地址 → 建面板） | `XXX_stable.CT` |
| ② | `python make_trainer.py --table <.CT> --out <游戏目录>\XXX.exe` | 独立 exe（约 10 MB） |
| ③ | 放到游戏目录 | 交付物 |
| ④ | **干净环境**下双击（关掉其它 CE、**重启一次游戏**） | 面板弹出 |
| ⑤ | 改一个值 → 游戏里确认 | 验收 |

## 生成 exe 的两条路

| 路 | 做法 | 结论 |
|---|---|---|
| **GUI** | CE 菜单 `File` → `Save As...`，文件名带 `.exe` → 弹「制作 EXE 修改器」向导（巨大/微型/Mono/进程名） | ✅ 功能存在，但**要人工点**，没法自动化 |
| **脚本**（推荐） | `make_trainer.py` 自己合成 | ✅ 全自动，已实测跑通 |

**脚本原理**（逆向自 `frmExeTrainerGeneratorUnit.pas`）：

```
trainer exe = standalonephase1.dat        ← 解压 stub（PE）
            + PE 资源 ARCHIVE             ← [filecount:4] + raw-deflate(条目序列)
            + PE 资源 DECOMPRESSOR        ← standalonephase2.dat
条目: [名长:4][名][目录长:4][目录][大小:4][内容]
模板: .cepack = "CEPACK" + [原大小:4] + raw-deflate
```

❌ **`saveTable('x.exe')` 不会产出文件**（只叫出向导、返回 `false`）—— 别再试这条路。

## 表脚本要做的四件事

```lua
① openProcess(getProcessIDFromProcessName('<游戏>.exe'))
② dofile(getCheatEngineDir()..'autorun\\monoscript.lua') + LaunchMonoDataCollector()
③ mono_findClass + mono_class_getStaticFieldAddress + 字段 offset  → 回填地址
④ hideAllCEWindows() + createForm/createLabel/createEdit/createButton → 弹面板
```

用 `createTimer(MainForm,false)` 每 500ms 轮询（附加和 Mono 都是异步的），成功后就地停掉自己。

**必备：文件日志**（trainer 的 CE **没有 `CELUASERVER` 管道**，看不到 Lua 输出）：

```lua
local LOG_PATH = 'C:\\Windows\\Temp\\xxx_trainer_log.txt'
local function say(s)
  print('[CE] '..tostring(s))
  pcall(function()
    local f = io.open(LOG_PATH,'a')
    if f then f:write(os.date('%H:%M:%S ')..tostring(s)..'\n'); f:close() end
  end)
end
```

## 面板 UI：四个"看着能用其实不能用"的 API（✅ 全部实测）

| API | 实测 |
|---|---|
| `getScreenDPI()` | ❌ 恒返回 **96**（真实 200% 也读不到）→ 别用它算缩放 |
| `form.fixDPI()` | ❌ **空操作**（DesignTimePPI == 当前 DPI，倍率恒 1） |
| `Canvas.TextWidth()` | ❌ 在 CE 的 Lua 里是 **`nil`**，量不了字宽 |
| `AutoSize = true` | ❌ 对**未显示**的窗体不重算，恒返回默认 `65x17` |

**唯一可用：`Font.Height`**（16pt → `-21`，取 `math.abs`）→ 字高实测，字宽按比例估算：

```
estW(s,th) = ascii*th*0.62 + wide*th*1.15      -- wide = 多字节数/3
W_NAME = estW(最长属性名)*1.30 + 2*PAD         -- PAD=14, GAP=12
W_NUM  = estW('9999')*1.60 + 2*PAD
ROW_H  = th + 2*PAD + 10
字号一个常量：local FS = 16                    -- 实测产出 581x618，玩家满意
```

## 硬规矩

1. **表脚本（`<LuaScript>`）里绝不能有裸 `<` 或 `&`** —— `.CT` 是 XML。
   症状极坑：`loadTable` 返回 `true` 但 `getAddressList().Count == 0`，**脚本静默不执行**。
   把 `if x < 4 then` 改写成 `if x > 3 then`。
2. **Mono 支持必须打包符号库**：`win64\dbghelp.dll` / `symsrv.dll` / `dbgshim.dll`
   —— 缺了会报 `Library Injection failed or invalid module`（**其实 DLL 已注入成功**，
   只是 CE 靠符号名 `MDC_ServerPipe` 确认导出）。注入后补一次 `reinitializeSymbolhandler(true)`。
3. **所有尺寸算式套 `math.floor`** —— `9*1.30` 是浮点，`string.format('%d')` 会抛
   `number has no invalid integer representation`。
4. **验证必须用干净环境**：关掉所有 CE + **重启一次游戏**。
   Mono 采集器 DLL **一旦注入就不随 CE 退出而卸载**，旧采集器占位会导致新修改器注入失败。
5. **归档里的表名必须是 `CET_TRAINER.CETRAINER`**（CE 硬编码）——`make_trainer.py` 已默认处理。
6. 面板设 `DoNotSaveInTable = true`，避免控件被写回表文件。
7. 关闭面板 = `closeCE()`（CE 主窗口已隐藏，留着无意义）；顺手在面板底部放个「关闭」按钮。
8. 覆盖 exe 前先 `Stop-Process -Name <修改器名>` —— 运行中的 stub 会锁住文件（`Permission denied`）。
9. **⭐ 谁启动，谁关闭**：验证修改器时启动的进程，**必须在同一步里检查完就关**。
   悬空进程会让用户误判为"残留 bug"，还会占着 Mono 采集器通道影响下次测试。
   涉进程的操作收尾前统一查四样：**遗留进程 / `%TEMP%\cetrainers` / 自己起的调试 CE / 探针脚本**。
10. **⭐ 不要替用户关他在用的程序**：用户的游戏、CE、修改器 —— **先问再动**。
   曾因"清测试基线"强杀用户正在玩的游戏，用户看到的是"游戏闪退"并怀疑修改器搞崩了游戏。
   拿不准就只做只读检查（`Get-CimInstance` 查状态）。
11. **面板尺寸必须在用户会话验证** —— DSH（Session 0）与用户会话的字体度量差一倍
   （实测 `textH` 21 vs 43），在 DSH 里看着正常的面板，用户那边可能大出一倍。

## 坑位速查

| 坑 | 正解 |
|---|---|
| `loadTable` 成功但条目为 0 | LuaScript 里有裸 `<` / `&`，XML 解析失败 → 改写条件 |
| `Library Injection failed or invalid module` | 补 `win64\dbghelp.dll` 等 + `reinitializeSymbolhandler(true)` |
| `saveTable('x.exe')` 无产出 | 用 `make_trainer.py` |
| `number has no integer representation` | `math.floor` |
| 关掉 CE 后游戏里仍有 `MonoDataCollector64.dll` | 正常（不卸载）→ 重启游戏 |
| `ce-lua.ps1` 连不上修改器 | 正常，它没有 Lua 管道 → 看文件日志 |
| `extracted\CET_TRAINER.CETRAINER` 启动后消失 | 正常，CE 读入后自清理 |
| 生成时报 `Permission denied` | 先杀掉正在运行的修改器进程 |
| `FindResource` 说资源不存在 | 参数顺序是 `(name, type)`，而 `UpdateResource` 是 `(type, name)` |

## 索引

| 需要什么 | 看哪 |
|---|---|
| **完整方案主文档** | `docs/03-standalone-trainer.md` |
| 格式逆向 / `.cepack` / 归档格式 / 文件清单 | 该文档 §3 |
| 小面板 UI：可用 API、DPI 实测、布局公式、骨架 | 该文档 §4 |
| 11 条坑位（含现象与正解） | 该文档 §5 |
| 实测数据（体积、运行链路、命令行证据） | 该文档 §6 |
| 验证与交付清单 | 该文档 §7 |
| 换游戏复用步骤 | 该文档 §9 |
| 稳定条目怎么找（上游） | `docs/02-stable-address.md` |
