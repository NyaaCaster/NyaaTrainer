# NyaaTrainer 技术文档与使用说明

> **这份文档是什么**：把 NyaaTrainer 的**原理、安装、配置、日常使用、命令速查、故障排查**收在一处。
> 读完本文你应该能独立完成「拿到一个游戏 → 找到数值 → 固化成重启后仍有效的条目 → 打包成双击即用的独立修改器」的全流程。
>
> **和仓库里其它文档的关系**：本文是**入口与总览**，同时也是**使用手册**。
> `docs/01`~`docs/04` 是四份**深度方法论**（每条结论都带实测状态），`AGENT.md` 是给 Agent 读的热 rule。
> 三者**不重复**：本文讲"怎么用、为什么这样设计"，`docs/` 讲"细节的完整推导与全部踩坑"。
>
> 本文所有路径一律用占位符（`<CE_DIR>` / `<GAMES_DIR>` / `<REPO>`），
> 实际值来自 `config.yaml`，**不要把本机路径硬编码进脚本**。

---

## 目录

| 章节 | 内容 | 适合谁 |
|---|---|---|
| [1. 项目简介](#1-项目简介) | 这是什么、解决什么问题、四条核心主张 | 所有人（先读） |
| [2. 核心原理](#2-核心原理) | 为什么不要一上来扫内存、地址为什么会浮动、稳定锚点是什么 | 想理解本质的人 |
| [3. 架构与目录](#3-架构与目录) | 文件清单、三条通道、四份文档的分工 | 要改代码的人 |
| [4. 安装](#4-安装) | 装依赖、装 CE、引导 CE、配 config.yaml | 首次使用 |
| [5. 使用说明](#5-使用说明) | 端到端工作流：找值 → 固化 → 打包 → 验证 | 所有人（主体） |
| [6. 命令速查](#6-命令速查) | 常用命令一页纸 | 日常查阅 |
| [7. 常见任务配方](#7-常见任务配方) | 按"我要做什么"索引的操作步骤 | 日常查阅 |
| [8. 故障排查](#8-故障排查) | 症状 → 原因 → 处理 | 出问题时 |
| [9. 硬规矩](#9-硬规矩) | 违反会翻车的约定（含血泪教训） | 所有人（务必读） |
| [10. 边界与免责](#10-边界与免责) | 支持范围、未验证项、安全风险 | 所有人 |

---

## 1. 项目简介

### 1.1 这是什么

**NyaaTrainer 是一套面向 Agent 驱动的游戏内存修改工程**。

它把「在游戏里找到一个数值」到「交付一个双击即用的独立修改器」的整条链路，
沉淀成**可被 Agent 直接复用的文档 + 脚本 + 样板**。

和传统 Cheat Engine 用法的根本区别：**这不是给人点 GUI 用的，是给 Agent 远程驱动用的**。
CE 里开着一条命名管道，Agent 通过 PowerShell 往里面灌 Lua 并取回文本结果 ——
所以「扫描内存」「反查类字段」「生成修改器」全都可以脚本化、可以无人值守。

### 1.2 解决什么问题

| 传统 CE 玩法的痛点 | NyaaTrainer 的做法 |
|---|---|
| 找到的地址**重启游戏就失效** | 记「**类名 + 字段偏移**」而不是记地址，运行时重新解析 |
| Unity Mono 游戏**扫内存收敛不了** | **先 dump 类结构**，字段名往往直接就叫 `currentHp` |
| 每次都要**开 CE 手动操作** | 交付物是**独立 exe**，放游戏目录双击就跑，不需要装 CE |
| 操作过程**无法复现** | 全程脚本化，表（`.CT`）与生成器都可留档重跑 |

### 1.3 四条核心主张

1. **不要一上来扫内存** —— Unity Mono 游戏直接 dump 类结构，字段名往往就是 `currentHp`
2. **地址必须可重建** —— 记「类名 + 字段偏移」而不是记地址，重启后重新解析
3. **交付物是程序** —— 最终产出是一个不依赖 CE 安装的独立修改器 exe
4. **全程可脚本化** —— 生成、验证、清理都不需要点 GUI

### 1.4 实测战绩

| 项目 | 引擎 | 数据形态 | 结果 |
|---|---|---|---|
| `パンドラメイズ260427` | Unity Mono | 静态字段 | 地址定位十几轮 → 交付独立修改器（约 10 MB，含小面板） |
| `淫白の御供` | Unity Mono | 实例字段 | **3 轮定位**，交付带 HP/MP 锁定的小面板修改器 |
| `Nurtale Nesche` | Unity Mono | 实例字段 + **无静态单例** | 走 UI 管理器兜底 + 调托管方法改状态（最难的一类） |

> 三个样例覆盖三种数据形态，都在 `examples/` 下，新项目**直接照着最接近的那份改**。

---

## 2. 核心原理

> 这一节解释「为什么这么做」。只想上手可直接跳到 [第 4 章](#4-安装)。

### 2.1 为什么不要一上来就扫内存

传统 CE 玩法是「扫值 → 筛 → 找指针」。**在 Unity Mono 游戏上这经常是最慢的路**：

| 现象 | 原因 |
|---|---|
| 扫出来的地址重启就变 | 托管堆对象会被 GC 移动；静态字段区每次启动重新分配 |
| 找不到指向它的指针 | 数据在 Mono 托管堆里，CE 的指针扫描扫不到托管引用链 |
| 界面不显示数值时**根本无从扫起** | 不知道目标值是多少（比如只有一根进度条） |
| 命中几十万个 | 靠"值看起来像什么"去猜，实测会命中一堆颜色分量与 UI 近似值 |

**两个真实项目的效率对比**（同一套方法论）：

| | `パンドラメイズ` | `淫白の御供` |
|---|---|---|
| 做法 | 扫值 → 断点 → 反查静态字段 | **直接 dump 类结构 → 读字段偏移** |
| 轮次 | 十几轮 | **3 轮** |
| 耗时 | 1~2 小时 | 几分钟 |

**结论**：Mono 游戏的正解是**先问游戏自己** —— 用 `mono_*` API 把类结构 dump 出来。

### 2.2 地址为什么会浮动

Mono 的 JIT 对**静态字段**做**绝对地址内联**。运行时机器码长这样：

```asm
1AFEBE2E53C: 48 B9 F8BEEAE3AF010000  mov rcx,000001AFE3EABEF8   ; ← 静态字段绝对地址，直接内联
1AFEBE2E550: 41 FF D3                 call r11
```

`0x1AFE3EABEF8` 这个地址**每次启动都不一样**，因为 `static_data` 区由 Mono 运行时分配。

**但有两样东西恒定**：

- **类名**（`VariableF`）
- **字段偏移**（`currentSAN` 在 `+0x58`）

所以「类名 + 字段偏移」就是我们要的**稳定锚点**。这也是本项目的理论基石。

> **判定特征**：只要在访问指令附近看到「把某个 `0x1A…` 绝对地址直接搬进寄存器」，
> 基本可判定它是 Mono 静态字段。这条特征在实战中非常好用。

### 2.3 三种稳定形态

| 形态 | 表达式示例 | 稳定性来源 | 适用 |
|---|---|---|---|
| **模块基址 + 全静态偏移链** | `[[[Game.exe+1A2B3C]+14]+8]` | 模块加载基址 + 编译期常量偏移 | 原生 C/C++、Go、Rust |
| **引擎字段引用** | Mono：`类.static_data + 字段offset` | 引擎对象模型：类名与偏移恒定 | Unity(Mono) ← **实测跑通的就是这条** |
| **AOB 特征码定位** | `aobscanmodule(...,Game.exe,特征字节)` | 代码/数据字节特征不随重启变化 | 特征稳定的结构体 |

**判断顺序**：先看引擎（能不能用字段引用）→ 不行就追指针链（断点最快）→ 再不行用 AOB 特征。

### 2.4 独立修改器是怎么造出来的

CE 的「制作 EXE 修改器」功能**能点但没法自动化** —— `saveTable('x.exe')` 只把向导弹出来，函数返回 `false`，**不产出任何文件**。

所以本项目**自己合成**（原理逆向自 CE 源码 `frmExeTrainerGeneratorUnit.pas`）：

```
trainer exe = standalonephase1.dat          ← 解压 stub（本身是个 PE 文件）
            + PE 资源 ARCHIVE               ← [filecount:DWORD] + raw-deflate(条目序列)
            + PE 资源 DECOMPRESSOR          ← standalonephase2.dat
   （微型模式没有 DECOMPRESSOR，ARCHIVE 直接就是表文件的内容）
```

**归档条目格式**（全部小端）：

```
[文件名长:4][文件名][目录长:4][目录][大小:4][内容]   … 逐文件重复 …
```

**模板 `.cepack` 格式**：

```
"CEPACK"（6 字节 ASCII） + [解压后大小:4] + raw-deflate(内容)
```

> `raw deflate` = zlib **去掉头尾**的流。Python 用 `zlib.decompressobj(-15)` 解、
> `zlib.compressobj(level, zlib.DEFLATED, -15)` 压。

**运行时的三段式进程链**（看到三个同名进程是**正常现象**，不是 bug）：

```
① <游戏目录>\XXX修改器.exe                     ← stub：解压 + 启动（无窗口）
   ② %TEMP%\cetrainers\CETxxxx.tmp\...         ← 解压出的启动器（无窗口）
      ③ ...\extracted\...                       ← 真正的 CE（有窗口的那个）
```

### 2.5 一个必须知道的前提：采集器不卸载

**Mono 采集器 DLL 一旦注入目标进程，就不随 CE 退出而卸载。**

后果：上一次调试留下的采集器占着通道，新修改器注入会失败
（`Library Injection failed or invalid module`，或解析不出地址）。

**所以任何"干净环境"验证都必须重启一次游戏**（关 CE 不够）。

---

## 3. 架构与目录

### 3.1 目录结构

```
NyaaTrainer/
├── README.md                  项目门面（人类阅读）
├── AGENT.md                   Agent 热 rule —— 流程 / 硬规矩 / 索引（Agent 必读）
├── USAGE.md                   本文 —— 技术文档 + 使用说明
├── LICENSE                    MIT
├── config.example.yaml        配置样例（复制为 config.yaml 后修改）
├── .gitignore
│
├── docs/                      方法论文档（Agent 与人类的共同知识源）
│   ├── 01-mono-recon.md           Unity Mono 数据结构侦察（定位数值的起点）
│   ├── 02-stable-address.md       把浮动地址固化成重启后仍有效的条目
│   ├── 03-standalone-trainer.md   打包成独立修改器 exe（含小面板 UI）
│   └── 04-ce-bridge.md            CE 与本仓库的通道（前置工作链）
│
├── src/                       可执行代码
│   ├── ce_mcp_server.py          标准 MCP 服务端（Agent 首选接入方式）
│   ├── make_trainer.py           独立修改器生成器（与游戏无关，通用）
│   ├── ce-lua.ps1                任意 Lua 通道客户端
│   ├── ce-mcp.ps1                8 个成品工具的命令行客户端
│   ├── check_lua_scope.py        Lua 作用域自查（查"使用早于 local 声明"）
│   ├── CheatEngine-Manage.ps1    CE 安装管理（Status/Sync/Migrate/Uninstall）
│   ├── NyaaTrainer_icon.ico      统一图标（7 尺寸）
│   └── NyaaTrainer_icon.svg      图标的矢量源文件（不参与打包）
│
├── lua/                       CE 侧加载的 Lua 库
│   ├── dsh_lib.lua               Lua 往返桥（结果回传）
│   └── dsh_stable.lua            稳定条目框架（声明/解析/反查/自动重建）
│
├── skills/                    Agent 技能（放进 Agent 的 skills 目录即可用）
│   ├── ce-stable-address/SKILL.md
│   └── ce-standalone-trainer/SKILL.md
│
└── examples/                  各游戏的样板（表 + 稳定地址脚本）
    ├── pandora/stable.CT         静态字段型
    ├── iyohaku/stable.CT         实例字段型（有静态单例）
    │   iyohaku/stable.lua
    └── nurtale/stable.CT         实例字段型（无静态单例）+ 调托管方法
        nurtale/stable.lua
        nurtale/README.md         该样板的专门说明
```

### 3.2 三条通道

CE 侧在 `main.lua` 里常驻三条 Agent 调用通道，按场景选：

| 通道 | 客户端 | 能力 | 何时用 |
|---|---|---|---|
| **通道 1** | `src/ce-lua.ps1` | **任意 Lua**（多行/任意字符），文本回传 | **首选**。多步逻辑、循环、复杂扫描 |
| **通道 2** | `src/ce-mcp.ps1` | **8 个成品工具**，走文件协议，**不需要 Python** | 单点查询/写入，参数化 |
| **通道 3** | `src/ce_mcp_server.py` | **标准 MCP 服务端**（stdio JSON-RPC） | 配进 Claude Code / Codex / OpenCode |

**通道 1 的工作方式**（为什么它最强）：

```
把 Lua 代码写进临时文件
  → 让 CE 用 dsh_run_file() 执行
  → 读回结果文件
```

因为是「代码走文件」，所以**支持任意多行代码与任意字符，完全不需要转义**。
`print()` 输出、返回值、运行时错误、语法错误都会分类回传：

| 返回前缀 | 含义 |
|---|---|
| `RETURN: <值>` | 脚本的返回值 |
| `PRINT: <行>` | 脚本里 `print` 的输出 |
| `ERROR: ...` | 运行时错误（带行号） |
| `LOAD ERROR: ...` | 语法错误 |

> ⚠️ **并发限制**：通道 2 与 3 **共用同一对文件**（`mcp_req.txt` / `mcp_res.txt`），
> **多个 Agent 同时调用会互相覆盖请求** —— 多 Agent 场景必须串行。
> 通道 1 走命名管道，**不受此限**。

### 3.3 四份方法论文档的分工

```
① 摸清数据结构  →  ② 固定成稳定条目  →  ③ 打包成独立程序
                         ↑
                    ④ 全程靠它驱动（通道）
```

| # | 文档 | 解决什么 | 何时看 |
|---|---|---|---|
| ① | `docs/01-mono-recon.md` | 拿到一个没碰过的 Unity Mono 游戏，怎么摸清"哪个类的哪个字段是 HP" | **起点**。不知道数据在哪时 |
| ② | `docs/02-stable-address.md` | 把找到的地址固化成**重启后仍有效**的条目（4 种方法 + 分引擎） | 地址重启就失效时 |
| ③ | `docs/03-standalone-trainer.md` | 打包成**双击即用的独立 exe**（含小面板 UI） | 要交付给用户时 |
| ④ | `docs/04-ce-bridge.md` | CE 与本仓库的**通道**（Agent 怎么驱动 CE） | 查命令、配通道时 |

---

## 4. 安装

### 4.1 环境要求

| 工具 | 版本 | 用途 | 来源 |
|---|---|---|---|
| **Cheat Engine** | **7.7**（验证版本） | 内存修改引擎 | <https://cheatengine.org/> · [GitHub](https://github.com/cheat-engine/cheat-engine) |
| **Python** | 3.8+ | 生成器 / MCP 服务端 | <https://www.python.org/downloads/> |
| **PowerShell** | 5.1+（推荐 7.x） | 通道脚本 | <https://github.com/PowerShell/PowerShell> |

> CE 是 **GPL-2.0**，Python 是 PSF，PowerShell 是 MIT。

### 4.2 装 Cheat Engine

从官网或 GitHub 下载安装即可。**记住安装目录**，下一步要用。

> 如果你的 CE 目录需要搬家，**不要直接剪切** —— 官方卸载器把绝对路径写进了 `unins000.dat`，
> 直接移动会导致卸载器失效。用本仓库的管理脚本：
>
> ```powershell
> # 先看状态（只读，安全）
> & '<CE_DIR>\CheatEngine-Manage.ps1' -Action Status
> # 搬家（会自动同步注册表与快捷方式）
> & '<CE_DIR>\CheatEngine-Manage.ps1' -Action Migrate -TargetDir 'D:\Target\Cheat Engine'
> ```

### 4.3 配置 config.yaml

```bash
cp config.example.yaml config.yaml
```

然后编辑 `config.yaml`，**至少填这两个**：

```yaml
paths:
  cheat_engine: "C:\\Program Files\\Cheat Engine 7.7"   # 你的 CE 安装目录
  games_root:   "D:\\Games"                             # 你的游戏根目录
```

`config.yaml` 已在 `.gitignore` 中，**不会被提交** —— 你的本地路径不会进仓库。

**完整配置项说明**：

| 键 | 含义 |
|---|---|
| `paths.cheat_engine` | CE 安装目录（下文记作 `<CE_DIR>`） |
| `paths.games_root` | 游戏根目录（下文记作 `<GAMES_DIR>`） |
| `paths.repo_root` | 本仓库位置（脚本用它定位 `docs/`、`lua/`、`src/`） |
| `paths.temp_dir` | 临时产物目录（留空用系统临时目录） |
| `cheat_engine.version` | CE 版本（影响部分 API 行为；7.7 为当前验证版本） |
| `cheat_engine.bootstrap` | CE 侧引导方式：`main_lua`（推荐）/ `autorun`（**CE 7.x 不执行**） |
| `cheat_engine.pipe_name` | LuaServer 管道名（默认 `CELUASERVER`） |
| `cheat_engine.mcp_poll_ms` | mcp 文件通道轮询间隔（毫秒） |
| `cheat_engine.mcp_timeout_s` | MCP 请求超时（秒） |
| `agent.mcp_command` / `mcp_args` / `mcp_env` | 各 Agent 客户端登记 MCP 服务端的命令 |
| `games[]` | 各游戏项目登记（`code` / `dir` / `process` / `table`） |
| `options.trainer_pack_mono` | 生成 trainer 时是否打包 Mono 支持（Unity Mono 必需） |
| `options.trainer_pack_symbols` | 是否打包 win64 符号库（**缺了 Mono 注入会失败**） |
| `options.panel_font_size` | 面板字号（200% 缩放下建议 12-16） |

**环境变量优先级高于配置文件**（便于临时覆盖）：

| 环境变量 | 覆盖 |
|---|---|
| `NYAA_TRAINER_CE_DIR` | `paths.cheat_engine` |
| `NYAA_TRAINER_GAMES_DIR` | `paths.games_root` |
| `CE_DIR` | 仅 `ce_mcp_server.py` 使用 |

### 4.4 引导 CE（关键步骤）

CE 需要**在启动时**加载引导代码，才能被 Agent 驱动。

**① 把 Lua 库复制到 CE 目录**：

```powershell
Copy-Item '<REPO>\lua\dsh_lib.lua'   '<CE_DIR>\' -Force
Copy-Item '<REPO>\lua\dsh_stable.lua' '<CE_DIR>\' -Force
```

> 必须放在 `<CE_DIR>\` 下，因为 **CE 从自己的目录 `dofile`**。

**② 在 `<CE_DIR>\main.lua` 末尾追加引导**：

```lua
pcall(function() openLuaServer('<pipe_name>') end)                       -- 开命名管道
pcall(function() dofile(getCheatEngineDir() .. 'dsh_lib.lua') end)       -- 加载往返桥
```

`<pipe_name>` 与 `config.yaml` 的 `cheat_engine.pipe_name` 保持一致（默认 `CELUASERVER`）。

**③ 改前先备份**：

```powershell
Copy-Item '<CE_DIR>\main.lua' '<CE_DIR>\main.lua.orig-backup' -Force
```

> ⚠️ **CE 7.x 不执行 `autorun\` 目录下的脚本**（实测落盘探针连试 3 次均未执行），
> 所以引导**必须挂 `main.lua`**，不能放进 `autorun\`。

**④ 重启 CE**，然后验证通道：

```powershell
& '<REPO>\src\ce-lua.ps1' -CeDir '<CE_DIR>' -Code "return 6*7"
# 期望输出：RETURN: 42
```

看到 `RETURN: 42` 就说明通道打通了。

### 4.5 让其它 Agent 工具接入（可选）

本仓库提供标准 MCP 服务端 `src/ce_mcp_server.py`，三者通用参数：

```
command : python（python 绝对路径）
args    : ["<REPO>\src\ce_mcp_server.py"]
env     : CE_DIR = <CE_DIR>          （可选 CE_MCP_TIMEOUT = 15）
```

| 工具 | 配置文件 | 备注 |
|---|---|---|
| **Codex CLI** | `~/.codex/config.toml` | TOML 里 Windows 路径用**单引号** |
| **Claude Code** | `~/.claude/settings.json` | 建议用 `claude mcp add` 命令式添加 |
| **OpenCode** | `~/.config/opencode/opencode.json` | 按官方字段新增 `type:"local"` / `command` / `environment` |

### 4.6 使用 skill（可选）

`skills/` 下是两个 Agent 技能，复制到你的 Agent skills 目录即可：

```bash
cp -r skills/ce-* ~/.agents/skills/
```

| skill | 何时触发 |
|---|---|
| `ce-stable-address` | 地址重启就失效 / 要做永久条目 / 指针扫描 / 找基址偏移 |
| `ce-standalone-trainer` | 打包成 exe / 双击即用 / 给游戏做个修改器 |

> skill 只放**决策表与流程骨架**；完整命令、参数、踩坑在 `docs/` 里。
> 这么分层是因为「引擎 × 方法」≈ 49 种组合，全塞进 skill 会每次白烧上下文。

---

## 5. 使用说明

> 这是本文的主体。完整走一遍大约需要：**简单游戏几分钟，复杂游戏 1~2 小时**。

### 5.1 总流程

```
① 侦察引擎        看模块：mono-2.0-bdwgc.dll = Unity Mono
   |
② 摸清数据结构    -> docs/01-mono-recon.md
   |
③ 写入验证        改一个值 -> 界面/进度条跟着变 -> 用户确认
   |
④ 固化地址        -> docs/02-stable-address.md
   |
⑤ 跨进程验证      重启游戏 -> 重新解析 -> 数值仍正确
   |
⑥ 打包修改器      -> docs/03-standalone-trainer.md (make_trainer.py)
   |
⑦ 交付            修改器 exe 放进游戏目录
```

### 5.2 每步验收判据（**不可跳**）

| 步 | 判据 |
|---|---|
| ② | 读出的数值**自洽**（比例与界面吻合 + 旁证字段说得通） |
| ③ | **写入测试**：改值 → 界面变化 → **用户确认** |
| ⑤ | **重启游戏**后脚本仍能解析出**新地址**且数值正确 |
| ⑥ | 修改器能在**干净环境**（其它 CE 全关、游戏重启过）下弹出面板并解析成功 |

> **⑤ 和 ⑥ 是排除巧合的唯一手段。** 「看起来对」不算通过。

---

### 5.3 步骤 ①：确认通道可用 + 附加进程

```powershell
$ce = '<CE_DIR>'

# 1) 通道自检
& "$ce\ce-lua.ps1" -Code "return 6*7"          # 期望 RETURN: 42

# 2) 附加目标进程
& "$ce\ce-lua.ps1" -Code "openProcess(getProcessIDFromProcessName('Pandora.exe'))"

# 3) 枚举模块，判断引擎
& "$ce\ce-lua.ps1" -Code @'
local mods = enumModules()
local out = {}
for k, m in pairs(mods) do
  local n = tostring(m.Name)
  if n:find('mono') or n:find('GameAssembly') or n:find('UnityPlayer')
     or n:find('godot') or n:find('Electron') or n:find('python') or n:find('RGSS') then
    out[#out+1] = string.format('%s  0x%X  %d', n, m.Address, m.Size)
  end
end
return table.concat(out, '\n')
'@
```

**引擎判断表**（决定后面走哪条路）：

| 模块特征 | 引擎 | 首选方法 |
|---|---|---|
| `mono-2.0-*.dll` | Unity（**Mono** 后端） | **方法 C（Mono 字段 + 反查）** ← 实测最优 |
| `GameAssembly.dll` + `il2cpp` | Unity（**IL2CPP** 后端） | 方法 A（断点）→ 结构体偏移 |
| `godot*.exe` / `*.pck` | Godot | 方法 A/B（断点 / 指针链） |
| `electron` / `node` / `.asar` | TyranoScript、NW.js 系 | V8 堆对象 → 方法 A/B |
| `python*.dll` / `*.rpa` | Ren'Py | PyObject 布局 → 方法 A/B |
| `RGSS*.dll`（Ruby） | RPGMaker XP/VX/VX Ace | Ruby 对象 → 方法 A/B |
| 无上述特征 | 原生 C/C++、自研 | **方法 A（断点）→ 方法 B（指针搜索）** |

---

### 5.4 步骤 ②：摸清数据结构（Unity Mono 走这条）

**先做前置**：让 CE 具备 Mono 能力。

> CE 自带 Mono 接口（`<CE_DIR>\autorun\monoscript.lua`），但 **CE 7.x 不执行 autorun**，必须手动加载：

```lua
dofile(getCheatEngineDir() .. 'autorun\\monoscript.lua')   -- 加载 mono_* API
LaunchMonoDataCollector()                                   -- 注入采集器到目标进程
-- 之后 mono_AttachedProcess = 目标 pid
```

**核心探索流程 5 步**：

```
①列游戏程序集 → ②dump 类清单 → ③按名字锁定候选类
→ ④dump 字段偏移 → ⑤沿引用链找到实例并验证
```

**① 列出游戏自己的程序集**

```lua
local asms = mono_enumAssemblies() or {}
for i = 1, #asms do
  local img = mono_getImageFromAssembly(asms[i])
  if img and img ~= 0 then
    local nm = tostring(mono_image_get_name(img))
    if nm:find('Assembly%-CSharp') then          -- 游戏自己的代码
      print(nm, 'classes =', #(mono_image_enumClasses(img) or {}))
    end
  end
end
```

> 实测规模：`パンドラメイズ` 13495 个类（含框架），`淫白の御供` 的 `Assembly-CSharp` **只有 123 个类**。
> **类少就是最大的优势** —— 123 个类可以直接全列出来肉眼找。

**②③ dump 类清单并按名字锁定候选**

```lua
local img = -- 上一步拿到的那张 image
local cs = mono_image_enumClasses(img)
local names = {}
for i = 1, #cs do
  local r = cs[i]
  names[#names+1] = ((r.namespace or '') ~= '' and (r.namespace .. '.') or '') .. (r.classname or '?')
end
table.sort(names)
return table.concat(names, '\n')
```

**经验法则**：

| 类名特征 | 判断 |
|---|---|
| `GameData` / `PlayerData` / `SaveData` / `Variable*` | **数据容器** → 数值就在字段里 |
| `*Manager` / `*Controller` | **入口/单例** → 从这里顺着引用找数据容器 |
| `*UI` / `*View` / `*Text` / `*Icon` | UI 层，**是副本不是源** |
| `*Type` / `*Slot` / `*Kind` | 枚举，用来理解字段语义 |

**④ dump 字段偏移**

```lua
local c = mono_findClass('', 'GameData')        -- 有命名空间就 mono_findClass('Ns', 'Class')
local fds = mono_class_enumFields(c)
local out = {}
for i = 1, #fds do
  local f = fds[i]
  if f.name ~= 'value__' then                    -- value__ 是枚举的内部字段，跳过
    local kind = f.isConst and 'const' or (f.isStatic and 'static' or 'inst')
    out[#out+1] = string.format('%-36s off=%-6s %s', tostring(f.name), tostring(f.offset), kind)
  end
end
return table.concat(out, '\n')
```

**实测输出**（`淫白の御供` 的 `GameData`）—— 字段名完全没混淆：

```
currentHp       off=24    inst      ← HP
maxHp           off=28    inst      ← HP 上限
currentMp       off=32    inst
maxMp           off=36    inst
reachedStage    off=40    inst
remainingDays   off=44    inst
day             off=48    inst      ← 天数
deathCount      off=52    inst
```

**这一步做完，数值基本就到手了。**

**⑤ 找到实例** —— 分三种情况：

| 情况 | 数据挂在哪 | 怎么走 |
|---|---|---|
| **A 静态字段型** | 直接挂在静态字段上 | `mono_class_getStaticFieldAddress(domain, c)` + `f.offset` |
| **B 实例字段型（有单例）** | 挂在对象上，有静态 `Instance` | 从单例沿引用链走 |
| **C 实例字段型（无单例）** | 没有任何静态字段持有 | ★ **UI 管理器单例兜底**（最难的一类） |

**情况 B 的代码**：

```lua
-- 第 1 跳：Manager 的静态 Instance
local mgr = mono_findClass('', 'GameManager')
local sbase = mono_class_getStaticFieldAddress(mono_enumDomains()[1], mgr)
local inst = nil
for _, f in ipairs(mono_class_enumFields(mgr)) do
  if f.isStatic and f.name:find('Instance', 1, true) then   -- 注意用模糊匹配
    inst = readPointer(sbase + f.offset)
    break
  end
end

-- 第 2 跳：实例里的 Data 引用
local data = nil
for _, f in ipairs(mono_class_enumFields(mgr)) do
  if (not f.isStatic) and f.name:find('Data', 1, true) then
    data = readPointer(inst + f.offset)
    break
  end
end

-- 读数值
print(string.format('HP = %d / %d', readInteger(data + 0x18), readInteger(data + 0x1C)))
```

> ⚠️ **最高频的坑**：编译器给 C# property 生成的字段名是 **`<Data>k__BackingField`** 形式，
> 所以**必须用 `f.name:find('Data', 1, true)` 模糊匹配**，写 `f.name == 'Data'` 会永远匹配不上。

**情况 C 的排查顺序**（实测走通的路径）：

| 顺序 | 手段 | 说明 |
|---|---|---|
| ① | 找静态单例持有数据 | 最省事 |
| ② | **全程序集扫静态字段**，确认确实没有 | 比对值是否等于目标对象 |
| ③ | **UI 管理器单例 → 子管理器 → 数据对象** | ★ 走通的这条。HUD 要显示数值，必然持有数据引用 |
| ④ | 反查指针拿上层对象 | 搜「谁存着这个地址」 |
| ⑤ | AOB 特征 | 最后手段 |

> **为什么不优先用 AOB**：实测 AOB 特征依赖**游戏数据里的具体数值**，
> **玩家一升级（35→39）就失配**。而 UI 管理器路径依赖的是**类名 + 字段偏移**，与数值无关。

**验证（不要凭"字段名像"就下结论）**：

| 步骤 | 做法 | 说明 |
|---|---|---|
| ① 数值自洽 | 读出的值是否落在合理范围 | 例：`HP=86 / MaxHP=103` → 83.5%，与界面吻合 |
| ② 旁证 | 其它字段是否也说得通 | 例：`MP=50/MaxMP=50`（满的）、`Deaths=0` |
| ③ **写入测试** | 改一个值，看界面是否跟着变 | **决定性** |
| ④ 跨进程验证 | 重启游戏，链条是否仍能解析出新地址 | 排除"碰巧命中" |

**写入测试的选值技巧**：改**分母**（`maxHp`）比改分子更直观 —— 进度条会明显缩短，而且容易还原。

```lua
writeInteger(data + 0x1C, 200)
print(readInteger(data + 0x1C))   -- 必须回读确认
```

> **验证完立刻还原**，不要把游戏留在异常状态。

---

### 5.5 步骤 ③：写入验证（用户确认）

改一个值，**让用户在游戏界面上确认变化**。这一步不能跳 —— 你自己读到值变了不代表改对了地方。

---

### 5.6 步骤 ④：固化地址

#### 定位当前值：两次筛选法（核心方法论）

**不要**用"值看起来像什么"的模式去猜。可靠做法：

1. **初扫**：对若干**假设表示**分别扫描并**保留 memscan 对象**，例如界面值 89%：
   `float 0.89`｜`float 89`｜`double 89`｜`dword 89`｜`dword 890`｜`dword 8900`
2. **让玩家改变该数值**（或让它自然变化），记录界面新值
3. 对每组执行 `ScanOption = soChanged` 的 **next scan**（只保留"值变了"的地址）
4. 再筛一次"当前值 == 满值/新值对应值" → 通常收敛到个位数
5. **写入测试** → 让玩家看界面确认 → 命中

```lua
-- 初扫（保留对象，供后续 next scan）
_G.dsh_scans = {}
local specs = { {n='float 0.89', vt=vtSingle, v='0.89'}, {n='dword 89', vt=vtDword, v='89'} }
setSpecialScanOptionsOverride({MEM_PRIVATE=true, MEM_IMAGE=false, MEM_MAPPED=true})
for _, s in ipairs(specs) do
  local ms = createMemScan()
  ms.VariableType, ms.ScanOption, ms.Scanvalue, ms.ScanWritable = s.vt, soExactValue, s.v, scanInclude
  ms.scan(); ms.waitTillDone()
  _G.dsh_scans[#_G.dsh_scans + 1] = { name = s.n, ms = ms }
end
-- 玩家改变数值后：next scan
for _, s in ipairs(_G.dsh_scans) do
  s.ms.ScanOption = soChanged
  s.ms.scan(); s.ms.waitTillDone()   -- 剩余数量 = s.ms.FoundCount
end
```

#### Unity Mono 的最短路径（推荐，实测跑通）

碰到 Mono 游戏**先走这条**，比指针扫描快一个数量级：

```
① 两次筛选法定出 T
② 读断点抓访问指令：debug_setBreakpoint(T, 4, bptAccess)    ← 不必等玩家操作，UI 每帧读
③ 反汇编 RIP 处：看到 mov reg, <绝对地址>  → 判定为 Mono 静态字段
④ 反查：dofile(getCheatEngineDir()..'dsh_stable.lua') ; dsh_stable.identifyReport(T)
   →  类名.字段名 + 0x偏移  以及 static_data 基址
⑤ 建条目：dsh_stable.define(...) → dsh_stable.installAll()
⑥ 重启游戏 → 重跑 installAll()（或事先 enableAuto()）→ 地址自动重算
```

**反查结果长这样**：

```lua
dsh_stable.identifyReport(0x1AFE3EABEF8)
-- 'VariableF' @ VariableF.currentSAN + 0x58  (base 1AFE3EABEA0)
--   S.define('currentSAN', 'VariableF', 'currentSAN', vtDword, 'currentSAN', 0x58)
```

**`dsh_stable.lua` 的完整用法**：

```lua
dofile(getCheatEngineDir() .. 'dsh_stable.lua')   -- 加载并声明条目

dsh_stable.installAll()          -- 把已声明条目写进地址列表；返回 成功数, 失败列表
dsh_stable.report()              -- 打印条目 + 当前解析地址
dsh_stable.resolve('SAN')        -- 只解析地址，不建条目
dsh_stable.installWithRetry()    -- 轮询等 Mono 附加完成后再装（重启后省心）
dsh_stable.enableAuto()          -- 包装 MainForm.OnProcessOpened，开进程后自动装

dsh_stable.define('SAN', 'VariableF', 'currentSAN', vtDword, 'SAN', 0x58)   -- 声明
dsh_stable.identifyReport(0x1AFE3EABEF8)                                    -- 反查
```

**声明一个条目的参数**：

| 参数 | 含义 |
|---|---|
| `key` | 条目标识（脚本内引用用） |
| `classname` | Mono 类名；带命名空间时写 `"Ns.Class"` |
| `fieldname` | 静态字段名 |
| `vtype` | CE 值类型（`vtDword` / `vtQword` / `vtSingle` / `vtDouble` / `vtByte`） |
| `desc` | 地址列表里显示的 Description（省略则用 key） |
| `expectOff` | 实测字段偏移，用作「游戏更新后字段漂移」的**哨兵**（可选） |

> `expectOff` 很有用：游戏小版本更新调整了字段顺序时，它会**明确报错**
> （`offset drift: ... expected 0x58 got 0x60`），而不是静默读到垃圾值。

#### 四种方法速览

| 方法 | 做法 | 适用 |
|---|---|---|
| **A 断点**（最直接） | `debug_setBreakpoint(T, 4, bptWrite)` → 让游戏自己写 → 回调读 `RIP` 与"接近 T 的寄存器" | 通用，能一次给出基址+偏移 |
| **B 指针搜索**（纯内存） | `MemScan soExactValue + vtQword` 逐级向上找 | 原生 C/C++ |
| **C Mono 字段** | `mono_*` API（见上） | Unity Mono ← **首选** |
| **D GUI 指针扫描** | CE 界面人工操作 + 重启过滤 | 自动化都不收敛时兜底 |

**方法 A 的三个要点**：

- ⚠️ **CE 自己的 `writeInteger` 不触发断点**（走 `WriteProcessMemory`，不经过目标执行流）→ **必须让游戏自己写**
- 💡 **不想等玩家操作就改用读断点 `bptAccess`**（UI 每帧读，几乎立刻命中）
- ⚠️ **数据断点报告的 RIP 是「访问指令的下一条」**（trap 语义）。
  看到命中处是 `xor eax,eax` 别困惑，真正的访问指令在 `RIP` **前面**（用 `getInstructionSize` 反推）

**方法 B 的局限**：

- ❌ **Mono 游戏在 PE 静态段找不到链顶** —— 实测 `Pandora.exe` 静态段 86016 个 qword 里**没有一个**指向目标附近。
  原因见 [§2.2](#22-地址为什么会浮动)：Mono 静态字段在**运行时分配的 static_data 区**，根本不在 PE 数据段。
  **这类游戏直接走方法 C，不要浪费时间做指针扫描。**
- 追指针时**必须带 `MEM_MAPPED`**：`setSpecialScanOptionsOverride({MEM_PRIVATE=true, MEM_IMAGE=false, MEM_MAPPED=true})`

#### 建立条目并验证

```lua
local al = getAddressList()
local mr = al.createMemoryRecord()
mr.Address     = '[[[Game.exe+1A2B3C]+14]+8]'   -- 指针表达式
mr.Type        = vtDword
mr.Description = 'SAN'                          -- ⚠️ 用 ASCII
```

> ⚠️ **删除**记录只能用 **`memoryrecord:delete()`**（对象自删）——
> `AddressList` 上**没有** `removeRecord` / `deleteRecord` / `delete`（调 nil 会被 `pcall` 静默吞掉）。
>
> 清空列表：`for i = al.Count - 1, 0, -1 do local mr = al.getMemoryRecord(i); mr:delete() end`
>
> **Mono 静态字段无法写成指针表达式**（运行时才知道地址），所以它的"条目"是
> **声明（类名+字段名）+ 一段解析脚本**。

**验证清单（照着做，别跳）**：

| 检查 | 方法 |
|---|---|
| 条目能否解析出当前值 | 读 `mr.Value`，与界面数值对得上 |
| 数值改变后条目跟随 | 让游戏改数值 → 条目值同步变化 |
| **重启/读档后仍正确** | 重启游戏 → 重新解析 → 条目值仍等于界面值 ← **决定性** |
| 写入生效且可回读 | 写一个明显值 → 回读 → 让玩家看界面 |

---

### 5.7 步骤 ⑤：跨进程验证

**重启游戏**，重新 `LaunchMonoDataCollector()`（**游戏重启会让采集器掉线**），再跑 `installAll()`。

实测数据（`パンドラメイズ`）：

| | 重启前 | 重启后 |
|---|---|---|
| static_data 基址 | `1AFE3EABEA0` | `2DB5D13BEA0` ← **变了** |
| SAN 绝对地址 | `1AFE3EABEF8` | `2DB5D13BEF8` ← **变了** |
| `currentSAN` 偏移 | `+0x58` | `+0x58` ← **一字节不差** |

**结论**：地址整体搬迁、偏移恒定 → `类名 + 字段偏移` 确实是稳定锚点。

---

### 5.8 步骤 ⑥：打包成独立修改器

#### 先选产物形态

| 形态 | 玩家看到什么 | 成本 |
|---|---|---|
| **A. 完整 CE 窗口** | 一个普通 CE 主窗口，地址列表里已躺着条目 | 最低（表里不加建面板的代码即可） |
| **B. 小面板修改器**（推荐交付） | 一个小窗口：属性 / 当前值 / 目标值 / 写入按钮 | 中等（多一段 `createForm` 代码） |

`hideAllCEWindows()` 是"变成修改器样貌"的关键 —— 它把 CE 的正常窗口全部隐藏。

#### 表脚本要做的四件事

```lua
① 附加目标进程        openProcess(getProcessIDFromProcessName('Pandora.exe'))
② 等 Mono 采集器就绪   dofile(…'autorun\monoscript.lua') + LaunchMonoDataCollector()
③ 解析静态字段地址     mono_findClass + mono_class_getStaticFieldAddress + 字段 offset
④ 建面板（可选）       hideAllCEWindows() + createForm/createLabel/createEdit/createButton
```

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

#### 必备：文件日志

> **trainer 里的 CE 没有 `CELUASERVER` 管道**，看不到它的 Lua 输出，
> 所以表脚本**必须自带文件日志**，否则出问题只能靠猜。

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

> CE 的 Lua **保留了完整 `io` / `os` 标准库**（实测可读写文件）—— 排障全靠它。
> 脚本开头用 `'w'` 模式清空一次，避免多次运行的日志混在一起。

#### 生成 exe

```powershell
python '<REPO>\src\make_trainer.py' `
  --table '<CE_DIR>\Pandora_stable.CT' `
  --out   '<GAMES_DIR>\2026-6\パンドラメイズ260427\PandoraTrainer.exe' `
  --ce-dir '<CE_DIR>'
```

**`make_trainer.py` 全部参数**：

| 参数 | 必填 | 说明 |
|---|---|---|
| `--table` | ✅ | 表格文件（`.CETRAINER` 或 `.CT`） |
| `--out` | ✅ | 输出的 exe |
| `--ce-dir` | | CE 安装目录（默认取脚本所在目录） |
| `--table-name` | | 归档内的表文件名（默认 `CET_TRAINER.CETRAINER`，**CE 硬编码，别改**） |
| `--icon` | | exe 图标（`.ico`），默认用同目录的 `NyaaTrainer_icon.ico` |
| `--no-icon` | | 不写图标资源 |
| `--no-mono` | | 不打包 Mono 支持 |
| `--no-decompressor` | | 不写 DECOMPRESSOR 资源 |
| `--tiny` | | 微型模式（约 70 KB，**依赖已安装的 CE**） |
| `--level` | | 压缩级别 0-9（默认 9） |

脚本自动完成：**解 `.cepack` → 收文件 → 建归档 → 复制 stub → 写 PE 资源 → 写图标**。

**两种图标分别设置，机制不同**：

| 位置 | 谁负责 | 做法 |
|---|---|---|
| **exe 文件图标**（explorer 里看到的） | `make_trainer.py` | 写 PE 资源 `RT_ICON` + `RT_GROUP_ICON` |
| **窗口左上角图标** | **表脚本** | `createPicture().loadFromFile()` 后赋给 `f.Icon` |

> `make_trainer.py` 会**现场派生两种形态**（源 ICO 是 Vista+ 的「内嵌 PNG」格式，
> 而两处使用方的格式要求正好相反）：
>
> | 派生 | 用途 | 为什么 |
> |---|---|---|
> | **传统 DIB 格式** | 写进 exe 的 `RT_ICON` | PE 图标资源必须是 `BITMAPINFOHEADER` + BGRA + AND 掩码 |
> | **PNG（32×32 / 16×16）** | 打进归档，供窗口图标用 | CE 的 `Picture.loadFromFile()` 需要 PNG |
>
> **换图标只需替换 `src/NyaaTrainer_icon.ico`，其余全自动。**

**表脚本设置窗口图标**（PNG 解压后在 `getCheatEngineDir()` 下）：

```lua
pcall(function()
  local d = getCheatEngineDir()
  if d:sub(-1) ~= '\\' then d = d .. '\\' end
  local pic = createPicture()
  pic.loadFromFile(d .. 'NyaaTrainer_icon_32.png')
  if pic.Icon.Width > 0 then f.Icon = pic.Icon end   -- 宽度 0 表示加载失败
end)
```

#### 生成后自检（每次都做）

**1) 表的 LuaScript 没有裸 `<` / `&`（XML 必须能解析）**

```powershell
python -c "import re,xml.etree.ElementTree as ET; p=r'<.CT路径>'; raw=open(p,encoding='utf-8').read(); txt=re.search(r'<LuaScript>(.*?)</LuaScript>',raw,re.S).group(1); print([l for l in txt.split(chr(10)) if '<' in l or '&' in l]); ET.parse(p); print('XML OK')"
```

**2) Lua 作用域自查**（强烈建议做）

```powershell
python '<REPO>\src\check_lua_scope.py' <提取出的脚本.lua>
```

> **为什么必须查**：这是**最隐蔽的一类 bug**。Lua 的 `local` 是**词法作用域** ——
> 函数定义时不可见的 local，在函数体里会退化成**读全局**（一边写 local、一边读 global，
> 永远读不到，**且完全不报错**）。症状是"日志显示解析成功，运行却报未解析"。

**3) 结构自检**：条目数对得上、脚本能 `loadstring` 通过（CE 里试跑一次，看文件日志）。

---

### 5.9 步骤 ⑦：运行侧验证（**必须干净环境**）

1. 关掉所有 CE 与旧修改器进程
2. **重启一次游戏**（清掉已注入的旧采集器）
3. 双击独立修改器（**用户原生双击**，不要只在 Agent 会话里验证）
4. 看日志：应为 `resolved N entries` + `panel created`
5. 改一个数值 → 游戏里确认生效
6. **看面板有没有超屏**
7. 关闭修改器 → **确认无残留进程**
8. **清理自己启动的一切**

> ⚠️ **不要在 Agent 会话（Session 0）里验证面板尺寸** —— 本机实测两端字体度量差一倍
> （`textH` 21 vs 43），你会看到一个"正常"的小面板，而用户实际看到的是两倍大的版本。
> **面板尺寸必须在用户会话里目视确认。**

**实测的关闭行为**（在 `淫白の御供` 上反复实测）：

| 关闭方式 | 结果 |
|---|---|
| 面板右上角 **X** | ✅ 整条链干净退出 |
| 面板底部 **「关闭」按钮** | ✅ 干净退出（日志出现 `exit: best-effort cleanup`） |
| 外部 **WM_CLOSE**（等效点 X） | ✅ 干净退出 |
| 外部 **`Stop-Process` 强杀 ③** | ✅ ①② 随之退出 |

**结论：正常关闭路径下不会残留。** 但崩溃、任务管理器结束、断电等异常路径仍可能留下 ①②，
所以可选的看门狗启动器值得做，**但它是保险，不是必需品**。

---

### 5.10 步骤 ⑧：交付

| 交付物 | 位置 |
|---|---|
| 独立修改器 exe | `<游戏目录>\<游戏>修改器.exe` |
| 表 + 稳定地址脚本（可再生成） | `<CE_DIR>\<代号>_stable.CT` / `.lua` |
| 生成器（通用，与游戏无关） | `<REPO>\src\make_trainer.py` |
| 留档副本 | `examples/` |

**验收记录要点**：修改器 exe 的 SHA256、表文件的 SHA256、机器验收日期、用户验收日期、卸载方法。

---

### 5.11 换一个游戏怎么做（复用清单）

1. 先找到**稳定锚点**（类名 + 字段偏移 / 指针链 / AOB）
2. 复制一份最接近的表：

   | 你的数据形态 | 抄哪份 | 定位链 |
   |---|---|---|
   | **静态字段型** | `examples/pandora/stable.CT` | `VariableF.currentSAN + 0x58`（JIT 内联静态地址） |
   | **实例字段型（有单例）** | `examples/iyohaku/stable.CT` + `.lua` | `GameManager.Instance → +0x20 → GameData → +字段偏移` |
   | **实例字段型（无单例）+ 需调方法** | `examples/nurtale/stable.CT` + `.lua` | `GUIHUDManager.instance → healthGUI → health` |

3. 改三处：`<CheatEntries>` 的条目、表脚本的 `PROCESS_NAME`、表脚本的 `WANT`（显示名 → 字段名）
4. 改面板标题 `f.Caption`
5. 跑 `make_trainer.py` 生成、按 [§5.9](#59-步骤-运行侧验证必须干净环境) 验证

> `make_trainer.py` **与游戏无关**，任何表都能打包 —— 不用改。
> `.CT` 与 `.CETRAINER` **是同一套 XML**，可直接喂给它。

---

### 5.12 小面板 UI 规范

#### 四模块分区（用户定稿的规范）

把面板信息按职责分成四个模块，从上到下排列。目标是**让用户一眼知道哪块在改游戏、哪块是工具本身**。

| 模块 | 放什么 | 控件形态 |
|---|---|---|
| **① 工具条** | **修改器本体功能**（刷新、重连进程、版本号等） | 顶部横条，标准软件布局 |
| **② 数值修改** | 用户**可填任意值**的数值（HP、体力…） | 数值行控件（见下） |
| **③ 状态开关** | **无数值**的通断状态（无敌模式…） | 开关（不是"开/关"两个按钮） |
| **④ 定值选项** | 取值被游戏**硬约束在有限集合**、互斥、**不允许填任意值**的项 | 每个取值一个按钮 |

> **命名规范**：第 ④ 类叫 **「定值选项」**，不是「定制选项」。
> 含义是"**取值已定**、只能从给定档位里挑"。

#### 数值修改的控件排布

```
[属性名]  [当前值]  | [0] [-] [+] [MAX] | [设定值输入框] [应用] | [锁定]
```

**分组逻辑（关键）**：

- **`0` / `-` / `+` / `MAX` 是一组** —— 它们**直接改值，不需要"应用"**
- **输入框 + `应用` 是一组** —— 输入的值**需要提交才生效**

**各控件规格**：

| 控件 | 规格 | 说明 |
|---|---|---|
| `-` `+` | **正方形**（宽=高） | 整列按正方形边长对齐，排版工整 |
| `0` | 正方形 | **仅"当前值"性质的项开放**；**上限性质隐藏**（`HP上限=0` 可能让游戏出错） |
| `MAX` | 正方形 | **仅定义了"运行时上限"的项开放**。语义 = 把当前值改为运行时上限值 |
| 输入框 | 约"十个 9"宽度 | 名字列则按最长标签动态算 |
| `应用` | 够 2 个字 | 原名"写入"，改叫"应用"更贴合"提交输入"的语义 |
| 锁定 | **正方形状态开关** | 用 `□`/`■` 自绘符号表达二态 |

> **隐藏按钮要保留占位**：不创建该控件即可，坐标天然留空 ——
> 这样各行的按钮仍是**矩阵对齐**的，不会因某项缺按钮而错位。

#### ⭐ 锁定功能只能有一个入口

> **每个数值条目的锁定，只由该行自己的 `□` 按钮负责，唯一入口。**
> 底部快捷按钮区**只放一次性动作**，**不放**任何锁定类按钮
> —— 包括「全部锁定 / 全部解锁」，以及「<某项>锁定N% / 解锁」这类重复按钮。

**为什么（实测踩坑）**：某项目里同时在两处提供性快感的锁定，两条路各自为政：

- 用**行内 `□`** 锁定时，通用重设循环用**写内存**的方式处理它 ——
  而该数值**必须调游戏方法**才有效 → **看起来锁了、实际没锁**
- 底部按钮走的是正确路径，但**它设的变量在行内路径里不被识别**

**消除重复入口 = 从结构上消灭这类 bug。**

**配套的显示约定**：锁定中**一律显示真值**（不是目标值）；与目标值不符时**标红**。
否则锁定失效时界面照样显示目标值，把失败掩盖掉。

#### 四个"看着能用、实际不能用"的 API（全部实测）

| API | 期望 | 实测结果 |
|---|---|---|
| `getScreenDPI()` | 拿到真实 DPI 好算缩放 | ❌ **恒返回 96**（真实 200% 也读不到） |
| `form.fixDPI()` | 按 DPI 自动缩放布局 | ❌ **空操作**（倍率恒为 1） |
| `Canvas.TextWidth()` | 量文字宽度 | ❌ 在 CE 的 Lua 里是 **`nil`** |
| `AutoSize = true` | 让 Label 自适应文字 | ❌ 对**未显示**的窗体不重算，恒返回默认 `65x17` |

**结论：不要在 CE 的 Lua 里试图测量文字宽度或靠 DPI 自动缩放。**

**唯一可靠的度量是 `Font.Height`**：

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

**布局公式**（本机实测产出 581x618，玩家反馈"效果满意"）：

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

> ⚠️ **所有尺寸算式必须 `math.floor`**：Lua 5.3 里 `9 * 1.30` 是浮点数，
> 直接丢给 `string.format('%d')` 会抛 `number has no integer representation`。

**面板宽度策略**（因为两个"屏幕宽度"API 都不可信）：

1. 面板宽度**由内容决定**
2. 上限取**固定值**（按用户会话逻辑宽留余量）
3. 压缩时给**名字列设保底宽度**：绝不窄于最长标签所需
4. 字号取小一点

> **教训**：与其猜屏幕宽度猜错导致标签截断，不如给一个宽松的固定上限 ——
> 面板是独立窗口，正常屏幕都远宽于它。

**其它面板行为约定**：

| 约定 | 做法 | 理由 |
|---|---|---|
| 关闭面板 = 退出修改器 | `f.OnClose = function(sender) pcall(closeCE) end` | 符合商业修改器习惯 |
| 面板不进表 | `f.DoNotSaveInTable = true` | 避免每次 `loadTable` 都重建控件 |
| 当前值自动刷新 | 500ms timer 只改 `label.Caption` | 不碰输入框，避免打断玩家输入 |
| 输入框用完即清 | `writeField()` 里 `edit.Text = ''` | 一眼看出"已写入" |
| 任务栏显示 | `f.ShowInTaskbar = 1` | **必须用数字**，枚举常量名在 CE 里是 `nil` 会静默失败 |
| 枚举窗体控件 | `form.getControl(i)` + `form.ControlCount` | ⚠️ `form.Controls` 是 **`nil`** |
| 模块标题不要用 `Font.Style` 设粗体 | 用 `Font.Size` + 颜色 + 分隔线 | LCL 的 `Style` 是集合类型，CE 的 Lua 里设不了（回读恒为 `[]`） |

---

## 6. 命令速查

> 下文 `$ce = '<CE_DIR>'`、`$repo = '<REPO>'`、`$g = '<游戏目录>'`。

### 6.1 通道

```powershell
# 任意 Lua（首选，支持多行）
& "$ce\ce-lua.ps1" -Code "return 6*7"                    # => RETURN: 42
& "$ce\ce-lua.ps1" -File "$ce\my.lua"                    # 长脚本走文件更稳
& "$ce\ce-lua.ps1" -Code "..." -StartCe                  # CE 没开就自动拉起并等管道

# 8 个成品工具（不需要 Python）
& "$ce\ce-mcp.ps1" -Tool get_modules
& "$ce\ce-mcp.ps1" -Tool read_memory  -Addr 0x100000000 -Type 4 -Hex true
& "$ce\ce-mcp.ps1" -Tool write_memory -Addr 0x144BAF0 -Val 54321 -Type 4
& "$ce\ce-mcp.ps1" -Tool aob_scan    -Aob "E8 03 00 00"
& "$ce\ce-mcp.ps1" -Tool calc        -Expr '0x1000+0x234'
& "$ce\ce-mcp.ps1" -Tool auto_assemble -Script $aaScript
& "$ce\ce-mcp.ps1" -Tool get_address -Expr "Game.exe+0x1234"
& "$ce\ce-mcp.ps1" -Tool disassemble -Addr 0x100001000 -Count 8
```

> 8 个工具都需要 **CE 已附加进程**，否则统一返回
> `{"status":"error","message":"CE is not attached to any process."}`。
>
> **`aob_scan` 返回有上限**（实测同一目标 CE 原生 `AOBScan` 得 573 个命中，
> MCP 的 `aob_scan` 只返回前 20 条）→ **需要全量命中时走通道 1**。

### 6.2 状态自检（通道是否还活着）

```powershell
# CE 在跑吗、管道在吗
Get-Process | Where-Object { $_.Path -like "$ce\*" } | Select-Object Id,Name
[bool]([IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -ieq '\\.\pipe\CELUASERVER' })

# CE 侧桥接库是否已加载（直接问 CE）
& "$ce\ce-lua.ps1" -Code "return 'lib='..tostring(type(dsh_eval)=='function')"

# 手动重启 MCP 轮询（通道 2/3 异常时）
& "$ce\ce-lua.ps1" -Code "CEMCP_stop() CEMCP_start() return 'mcp restarted'"
```

### 6.3 找值 / 固化

```powershell
# 附加进程
& "$ce\ce-lua.ps1" -Code "openProcess(getProcessIDFromProcessName('Game.exe'))"

# 加载 Mono 能力
& "$ce\ce-lua.ps1" -Code "dofile(getCheatEngineDir()..'autorun\\monoscript.lua') LaunchMonoDataCollector()"

# 稳定条目
& "$ce\ce-lua.ps1" -Code "dofile(getCheatEngineDir()..'dsh_stable.lua') dsh_stable.installAll()"
& "$ce\ce-lua.ps1" -Code "dofile(getCheatEngineDir()..'dsh_stable.lua') dsh_stable.report()"
& "$ce\ce-lua.ps1" -Code "dofile(getCheatEngineDir()..'dsh_stable.lua') dsh_stable.identifyReport(0x1AFE3EABEF8)"
```

### 6.4 生成修改器

```powershell
# 标准生成
python "$repo\src\make_trainer.py" `
  --table "$ce\Pandora_stable.CT" `
  --out   "$g\PandoraTrainer.exe" `
  --ce-dir "$ce"

# 微型版（约 70 KB，但目标机器必须已装 CE）
python "$repo\src\make_trainer.py" --table "$ce\Pandora_stable.CT" --out '<输出.exe>' --tiny

# 覆盖 exe 前先释放被占用的文件
Get-Process -Name PandoraTrainer -ErrorAction SilentlyContinue | Stop-Process -Force
```

### 6.5 验证与清理

```powershell
# 看运行日志（trainer 没有 Lua 管道，只能看文件）
Get-Content "$env:TEMP\iyohaku_trainer_log.txt"
Get-Content 'C:\Windows\Temp\pandora_trainer_log.txt'

# Lua 作用域自查
python "$repo\src\check_lua_scope.py" '<脚本.lua>'

# 检查残留进程
Get-CimInstance Win32_Process | Where-Object { $_.Name -match '修改器|cheatengine' } |
  Select-Object ProcessId,ParentProcessId,ExecutablePath | Format-Table -AutoSize -Wrap

# 临时解压目录（每个约 30 MB）
foreach ($t in @("$env:TEMP\cetrainers", 'C:\Windows\Temp\cetrainers')) {
  if (Test-Path $t) { Get-ChildItem $t -Directory | Select-Object FullName }
}
```

### 6.6 CE 安装管理

```powershell
& "$ce\CheatEngine-Manage.ps1" -Action Status                                    # 只读检查
& "$ce\CheatEngine-Manage.ps1" -Action Sync                                      # 修复注册表/快捷方式指向
& "$ce\CheatEngine-Manage.ps1" -Action Migrate -TargetDir 'D:\Target\Cheat Engine'  # 搬家
& "$ce\CheatEngine-Manage.ps1" -Action Uninstall -DryRun                         # 卸载预演
```

---

## 7. 常见任务配方

### 7.1 我要找某个数值的稳定地址

1. 确认通道可用 + 附加进程（[§5.3](#53-步骤-确认通道可用--附加进程)）
2. `enumModules()` 判断引擎
3. Mono 游戏 → [§5.4](#54-步骤-摸清数据结构unity-mono-走这条) 走 dump 类结构
4. 非 Mono → 用两次筛选法定出当前地址，再用方法 A（断点）追根
5. 建条目并验证（[§5.6](#56-步骤-固化地址)）
6. **重启游戏重新解析**（[§5.7](#57-步骤-跨进程验证)）

### 7.2 我要给某个游戏做个修改器

1. 先确保已有**经过重启验证**的稳定条目
2. 抄一份最接近的样板表（[§5.11](#511-换一个游戏怎么做复用清单)）
3. 改用 `make_trainer.py` 生成（[§5.8](#58-步骤-打包成独立修改器)）
4. 干净环境验证（[§5.9](#59-步骤-运行侧验证必须干净环境)）

### 7.3 写字段后界面不刷新

**症状**：回读值确实变了，但**界面不动**，且游戏下次更新就覆盖回来。

**结论**：那个字段是**显示副本**，值的变更靠**事件通知**驱动 UI。

**找真源**：看**继承链**（`mono_class_getParent`）——
`enumFields` / `enumMethods` **只列本类声明的成员，看不到继承的**。

**解法**：**调游戏自己的方法**（`Set` / `ForceActivate` / `TrySetLevel`…），
方法内部会一并处理事件通知与 UI 刷新。

```lua
local dom = mono_enumDomains()[1]

-- ① 取方法指针（enumMethods 元素含 {method=, name=, flags=}）
local c = mono_findClass('', 'SexualHeatManager')
local m = nil
for _, e in ipairs(mono_class_enumMethods(c)) do
  if e.name == 'Set' then m = e.method break end
end

-- ② 需要字符串参数时先造托管字符串
local s = mono_new_string(dom, 'some_id')

-- ③ 调用（第 4 个参数是 args 数组）
local ok, r = pcall(mono_invoke_method, dom, m, instanceAddr, { value })
```

> ⚠️ **调用托管方法前必须检查管道健康**（见 [§9 硬规矩 12](#9-硬规矩)）。
>
> 实测案例：`ArouseGaugeManager.currentarouse` 写不动界面 → 真源是父类
> `SexualHeatManager._heat` → 调 `SexualHeatManager.Set(v)` 后数据与 UI 同时同步。

### 7.4 我找不到任何静态字段持有数据

走「UI 管理器兜底」路径：

```
GUIHUDManager.instance                     ★ 静态字段 @ offset 0
  +0x28  healthGUI → HealthCanvasManager
           +0x20  health → Health           ← 数据对象到手
```

**为什么这条比指针扫描好**：HUD 要显示数值，就必然持有数据对象的引用，
而管理器本身往往是**静态单例**；依赖的是「类名 + 字段偏移」，与数值无关。

### 7.5 我要用 MCP 在其它 Agent 里改游戏

见 [§4.5](#45-让其它-agent-工具接入可选)，或用通道 3 的工具：

| 工具 | 用途 |
|---|---|
| `get_address` | 解析 CE 地址表达式（模块基址、多级指针） |
| `get_modules` | 列出模块基址与大小 |
| `disassemble` | 反汇编若干条 |
| `read_memory` | 读内存（单值或块） |
| `write_memory` | 写内存 |
| `aob_scan` | 字节特征扫描（支持 `??` 通配） |
| `auto_assemble` | 运行 CE Auto Assembler 脚本 |
| `calc` | 十六进制计算 |

---

## 8. 故障排查

### 8.1 通道类

| 症状 | 原因 / 处理 |
|---|---|
| `CE 的 LuaServer 管道 'CELUASERVER' 不存在` | 启动 CE（或 `-StartCe`）；确认 `main.lua` 里 `openLuaServer` 那行**没被注释** |
| `请用 -Code 或 -File 提供 Lua 代码` | PowerShell here-string 的**赋值变量名与引用变量名不一致**（`$lua = @'…'@` 却写 `-Code $arm`） |
| 工具返回 `CE is not attached to any process.` | 先在 CE 里附加进程，或用通道 1 执行 `openProcess(...)` |
| 通道 2/3 响应超时 | 通道 1 执行 `return type(CEMCP_start)=='function'` 检查；必要时 `CEMCP_stop() CEMCP_start()`；核对 `CE_DIR` |
| 多 Agent 同时调用通道 2/3 互相覆盖 | **共用同一对文件**，必须串行；或改用通道 1（命名管道） |
| CE 启动后 CPU 偏高 | 确认没有遗留的 socket 轮询脚本 |

### 8.2 Mono 类

| 症状 | 原因 / 处理 |
|---|---|
| `mono_enumDomains()` 返回 nil | **游戏重启/切场景会让采集器掉线** → 重新 `LaunchMonoDataCollector()` + 等约 5 秒（**只 `openProcess` 不够**） |
| `resolve` 报 `mono collector not attached` | 同上 |
| `mono_findClass('', 'Foo')` 找不到 | 类名**带命名空间** → `mono_findClass('My.Ns', 'Foo')` |
| `mono_class_getName(元素)` 返回空串 | `mono_image_enumClasses` 返回的是 **table**（元素 `{class=, classname=, namespace=}`），要取 `rec.class` |
| `GameData is null`（精确匹配 `Data` 失败） | 字段真名是 **`<Data>k__BackingField`** → 用 `f.name:find('Data', 1, true)` 模糊匹配 |
| `mono_object_getClass(x)` 返回 nil | 它**只接受对象起始地址**；对字段地址必然返回 nil |
| `mono_object_getClass` 返回一堆垃圾类名 | 它对**任意地址**都会返回字符串（不是 nil）→ **必须严格校验类名**（过滤不可打印字符） |
| 子类上找不到 `Set` / 父类字段找不到 | `enumFields` / `enumMethods` **只列本类声明**，去**父类**（`mono_class_getParent`）找，再对子类实例调用 |
| `mono_class_findInstancesOfClass` 返回 nil | 采集器状态不健康时静默失败 → **重新注入采集器**再试 |
| 枚举类里混进 `value__` | 那是枚举的内部字段 → `if f.name ~= 'value__' then` 过滤 |

### 8.3 断点类

| 症状 | 原因 / 处理 |
|---|---|
| 写断点命中 0 次 | **CE 自己的 `writeInteger` 不触发断点**（走 `WriteProcessMemory`）→ 必须让**游戏自己写**；或改用读断点 `bptAccess` |
| 命中处的指令看起来没访问任何东西 | 数据断点是 **trap 语义**：`RIP` 已指向**下一条**。真正的访问指令在 `RIP` **前面**（用 `getInstructionSize` 反推） |
| 读断点导致游戏卡顿 | 读断点**每帧触发** → 回调里计数，抓够 N 次就 `debug_removeBreakpoint` |
| 回调后游戏卡死 | 忘了 `debug_continueFromBreakpoint(co_run)` + `return 1` |

### 8.4 地址列表类

| 症状 | 原因 / 处理 |
|---|---|
| 删不掉记录，`pcall` 静默"成功" | `AddressList` 上**没有**删除方法 → 用 **`memoryrecord:delete()`**（对象自删） |
| `string.find(desc,'候选')` 匹不上 | CE 记录的 `Description` 与匹配关键字**一律用 ASCII** |
| `invalid option '%~'` | Lua `string.format` 里字面百分号要写 **`%%`** |
| `enumModules()` 当对象用报错 | 它是**普通表**（`pairs` 遍历），不是对象，没有 `.Count` |
| 用 `getNameFromAddress()` 判断"是否在模块内" | 对堆地址返回地址字符串本身 → 用 `enumModules()` 的 `Address/Size` 自己比区间 |

### 8.5 扫描类

| 症状 | 原因 / 处理 |
|---|---|
| 只扫 `MEM_PRIVATE`，指针全漏 | 指向目标的指针在 `MEM_MAPPED` → `setSpecialScanOptionsOverride({MEM_PRIVATE=true, MEM_IMAGE=false, MEM_MAPPED=true})` |
| `soValueBetween` 参数不生效 | **实测无效**（扫出 174 万全范围随机值）→ 用 `soExactValue`，或 AOBScan 高字节通配 + Lua 过滤 |
| 命中的全是颜色分量 | 实测 `214/255 = 0.839216` 被误当成 HP 比例 → **不要用模式猜测**，改用两次筛选法 |
| 一批候选值彼此不一致 | 真值的多份副本应**完全一致**，不一致即可排除 |
| `dword 8900` 剩余候选值很怪 | **非对齐命中** → 按类型对齐扫描/过滤 |

### 8.6 修改器生成/运行类

| 症状 | 原因 / 处理 |
|---|---|
| `loadTable` 返回 `true` 但 `getAddressList().Count == 0` | **LuaScript 里有裸 `<` / `&`** → `.CT` 是 XML，改写成 `>` 形式（`if x > 3 then`） |
| `Library Injection failed or invalid module` | 缺 `win64\dbghelp.dll` / `symsrv.dll` / `dbgshim.dll`（**其实 DLL 已注入成功**，是 CE 靠符号名确认）→ 补符号库 + `reinitializeSymbolhandler(true)` |
| `number has no integer representation` | 尺寸算式丢给 `string.format('%d')` 的是浮点 → 全部套 `math.floor` |
| 生成时报 `Permission denied` | 运行中的 stub 锁住了 exe → 先 `Stop-Process -Name <修改器名>` |
| `saveTable('x.exe')` 不产出文件 | **正常**（只叫出向导、返回 `false`）→ 用 `make_trainer.py` |
| `ce-lua.ps1` 连不上修改器 | **正常**：trainer 的 CE 没有 Lua 管道（它的 `main.lua` 是原版）→ 靠表脚本的**文件日志** |
| `extracted\CET_TRAINER.CETRAINER` 启动后消失 | **正常**：CE 读入后自行清理 |
| 关掉 CE 后游戏里仍有 `MonoDataCollector64.dll` | **正常**（不卸载）→ 验证独立修改器前**重启一次游戏** |
| 两个 CE 同时附加同一游戏 | 后启动的 Mono 用不了 → 同一时间只留一个 |
| `FindResource` 说资源不存在 | 参数顺序是 **`(name, type)`**，而 `UpdateResource` 是 **`(type, name)`** |
| 顶点进程残留 | 用看门狗启动器（CE 内部发不起脱离式清理进程） |

### 8.7 面板 UI 类

| 症状 | 原因 / 处理 |
|---|---|
| 面板不在任务栏 | `f.ShowInTaskbar = 1`（**必须用数字**，枚举常量名在 CE 里是 `nil` 会静默失败） |
| 想遍历控件改不了 | `form.Controls` 是 **`nil`** → 用 `form.getControl(i)` + `form.ControlCount` |
| 面板被压缩到标签截断 | 用了 `getScreenWidth()` / `MainForm.Width` 当屏幕宽度（两者都不可信）→ 宽度由内容决定 + 固定上限 + 名字列保底 |
| 面板下方某区按钮超出右边界看不到 | `FW = max(...)` **漏算了某个横向布局区** → 每个区都要算进去 |
| 压缩时最右侧按钮仍溢出 | 压缩分支里**漏缩放某个控件宽** → 所有参与横向排布的宽度都乘系数 |
| 在 Agent 会话里面板正常、用户那边截断 | 两端字体度量差约一倍 → **面板尺寸只能在用户会话目视确认** |
| `createIcon(w,h)` 拿到空白图标 | 用 `createPicture()` → `loadFromFile(path)` → `f.Icon = pic.Icon` |
| 模块标题设不了粗体 | LCL 的 `Font.Style` 是集合类型，CE 的 Lua 里设不了（回读恒为 `[]`）→ 用 `Font.Size` + 颜色 + 分隔线 |

### 8.8 脚本类

| 症状 | 原因 / 处理 |
|---|---|
| 日志显示解析成功，运行却报"未解析" | **Lua `local` 作用域问题** —— 共享变量统一声明在**脚本最前面**。用 `check_lua_scope.py` 自查 |
| 手动能改，定时器里的重设从不生效且日志空白 | ① `pcall(fn)` 会吞掉返回值 → 周期任务**成功/失败都要留痕**（含心跳）；② 定期器可能跑在没管道的线程 → `pipeOK()` 要能**建立**管道而不只是检查 |
| 高频调托管方法偶发游戏崩溃 | `mono_invoke_method` 走每线程管道，失效时继续调用会写坏管道 → 调用前 `pipeOK()` 自检；一次只做一个操作；周期调用间隔 ≥200ms 并限流 |
| 手工改托管容器后游戏崩溃 | **`Dictionary` / `List` 的 entries/buckets/count 一律只读**！实测数据层验证全对但游戏崩溃 → 要改就调游戏自己的方法 |
| Lua 数组下标导致整体错一格 | Lua 下标从 **1** 开始而业务值从 0 起 → 用**显式映射** `{ [0]='a', [1]='b' }`，不要依赖数组顺序 |

### 8.9 编码类

| 症状 | 原因 / 处理 |
|---|---|
| `.ps1` 脚本静默无输出、退出码 0 | **中文进程名匹配不上** → `.ps1` 必须带 **UTF-8 BOM**（PS 5.1 无 BOM 按 ANSI 解析） |
| `.bat` 中文乱码 | `.bat` 反之用 **GBK（代码页 936）**，并在开头加 `chcp 65001 >nul` |
| 按路径筛进程筛不到 | `Get-Process.Path` 常返回空 → 用 **`Get-CimInstance Win32_Process` 的 `ExecutablePath`** |

```powershell
# 带 BOM 写 .ps1
[IO.File]::WriteAllText($path, $content, (New-Object Text.UTF8Encoding($true)))
# 校验 BOM（应为 EF BB BF）
$b = [IO.File]::ReadAllBytes($path); ($b[0..2] | % { $_.ToString('X2') }) -join ' '
```

---

## 9. 硬规矩

> 这些是**实测踩过坑**换来的约定。Agent 作业时同样适用（详见 `AGENT.md` §5）。

1. **改动前先备份** —— `<CE_DIR>\main.lua` 等有 `.orig-backup` 的，改前确认备份在。
2. **不硬编码路径** —— 一切路径从 `config.yaml` 拼接；仓库内文件用相对路径。
3. **不要动用户的其它程序** —— 只操作明确指定的游戏/进程。
4. **写入必回读** —— 任何 `writeInteger` 后都要 `readInteger` 确认，且**验证完要还原**。
5. **表脚本里禁止裸 `<` 和 `&`** —— `.CT` 是 XML，会**静默**导致脚本不执行。
6. **一个游戏一个表** —— 命名 `<code>_stable.CT`，与游戏目录同级管理。
7. **验证不跳步** —— 特别是"重启后仍有效"和"干净环境下能跑"，这是排除巧合的唯一手段。
8. **两个 CE 不能同时附加同一游戏** —— Mono 采集器 DLL 注入后不随 CE 退出而卸载。
9. **自己启动的进程必须自己关**（见 [§9.2](#92-清理规范)）。
10. **不要替用户关他在用的程序**（见 [§9.3](#93-不要替用户关他在用的程序)）。
11. **面板尺寸必须在用户会话验证** —— 不同会话的字体度量可能差一倍。
    **`getScreenWidth()` 与 `MainForm.Width` 都不能当屏幕宽度用**。
12. ⭐ **调托管方法前必须检查管道健康** —— `mono_invoke_method` 走**每线程命名管道**，
    管道失效时继续调用会**让目标进程崩溃**（实测崩过两次）。调用前 `pipeOK()` 自检；
    **一次只做一个操作**；循环时每步复查；周期调用间隔 ≥200ms 并限流。
13. ⭐ **绝不手工改托管容器的内部结构** —— `Dictionary` / `List` 的 entries/buckets/count
    一律**只读**。实测手工插条目并修好哈希链，数据层验证全对但**游戏崩溃**。
14. ⭐ **共享变量声明在脚本最前面** —— Lua 的 `local` 是**词法作用域**，
    函数定义时不可见的 local 在函数体里会退化成**读全局**（且**不报错**）。
15. **写字段没反应就去调方法** —— 回读值变了但**界面不刷新** = 那个字段是**显示副本**。
    真源常在**父类**（`enumFields`/`enumMethods` **只列本类声明**）。
16. ⭐ **锁定功能只能有一个入口** —— 每个数值的锁定**只由该行自己的 `□` 按钮**负责；
    底部快捷按钮区**只放一次性动作**（见 [§5.12](#512-小面板-ui-规范)）。
17. ⭐ **面板宽度上限要用"实际可用宽度"** —— `FW = max(每个横向区的宽度需求)`，
    **别漏区**；压缩分支里**所有**参与横向排布的宽度都要乘系数。
18. **锁定中的显示要读真值** —— 显示目标值会把"锁定失效"掩盖掉。真值 ≠ 目标时**标红**。
19. **周期任务必须留痕** —— `pcall(fn)` 会吞掉返回值 → 故障变成"日志一片空白"。
    周期重设要记录成功/失败（含心跳）；**限流时间戳只在成功后**更新。
20. ⭐ **修改器界面按四模块分区** —— ① 工具条 ② 数值修改 ③ 状态开关 ④ **定值选项**
    （**叫「定值选项」不是「定制选项」**）。状态开关类项目**不得**同时出现在数值区。
21. **数值行控件排布** —— `[属性][当前] | [0][-][+] [MAX] | [输入框][应用] | [锁定]`。
    上限性质的项隐藏 `0`；无运行时上限的项隐藏 `MAX`；隐藏时**保留占位**以维持对齐。
22. ⭐ **图标统一用 `src/NyaaTrainer_icon.ico`**（`.svg` 是矢量源，不参与打包）；
    换图标只需替换那个 ico。
23. **模块标题不要用 `Font.Style` 设粗体** —— 用 `Font.Size` + 颜色 + 分隔线。

### 9.1 交付物 vs 临时物

| 类别 | 例子 | 处置 |
|---|---|---|
| **交付物** | 修改器 exe、表 `.CT`、样板 | **保留**（游戏目录 / `examples/`） |
| **临时物** | 进程、`cetrainers` 目录、探针脚本 | **用完即清** |
| **证据物** | 运行日志（`*_trainer_log.txt`） | 排障期保留，结论落文档后可清 |

### 9.2 清理规范

> **教训**：曾为验证"删掉外部脚本后修改器还能不能跑"而启动修改器，检查完**忘了关**，
> 留下 3 个进程。用户此时已关掉自己的游戏和修改器，看到进程后以为是残留 bug。
> **悬空进程会污染用户判断，还会占着 Mono 采集器通道影响下次测试。**

**铁律一：谁启动，谁关闭** —— 验证必须**"启动 + 检查 + 关闭"三步一体**。

```powershell
# ✗ 反例：启动了，检查完没下文
Start-Process $trainer; Start-Sleep 50; Get-Content $log

# ✓ 正例：同一段里收尾
$p = Start-Process $trainer -PassThru
Start-Sleep -Seconds 50
Get-Content $log                                                                    # 检查
Get-Process -Name '<修改器名>' -ErrorAction SilentlyContinue | Stop-Process -Force   # 关闭
```

**铁律二：涉进程的操作，收尾查四样** —— 遗留进程 / `%TEMP%\cetrainers` / 自己起的调试 CE / 探针脚本
（命令见 [§6.5](#65-验证与清理)）。

**铁律三：清理要清到底**

| 对象 | 清理方式 |
|---|---|
| 修改器进程链（3 个） | `Get-Process -Name '<修改器名>' \| Stop-Process -Force` |
| `%TEMP%\cetrainers\CETxxxx.tmp` | `Remove-Item ... -Recurse -Force`（先确认无进程占用） |
| 调试用 CE | `Get-Process -Name 'cheatengine-x86_64*' \| Stop-Process -Force` |
| 临时探针脚本 | 清掉自己在临时目录建的那些 |

### 9.3 不要替用户关他在用的程序

> **教训**：曾为"清出干净测试基线"，一条命令里把**用户正在玩的游戏**也强杀了。
> 用户看到的是**游戏闪退**，并一度怀疑是修改器把游戏搞崩的。

- **只清自己启动的东西**；用户的游戏 / CE / 修改器 —— **先问再动**
- 要动就说清楚：*"为了做隔离测试，需要关掉你正在运行的游戏，可以吗？"*
- 拿不准就只做**只读检查**（`Get-CimInstance` 查状态）
- **万一误关**：立刻承认是我做的、说明原因

### 9.4 签名约定

本仓库所有**代码类产物**（`.py` / `.ps1` / `.lua` / `.CT` 内嵌脚本）应包含签名：

```
Nyaa be with you.
```

**要求**：非注释、非 UI 显性、**不影响业务逻辑**。推荐做法是放一个**惰性常量**，
使其自然参与某次无副作用的计算或写入，而不是仅作为一句注释。

```python
_SIGNATURE = b"Nyaa be with you."
```

---

## 10. 边界与免责

### 10.1 能力边界

| 事项 | 说明 |
|---|---|
| **仅限 Unity Mono** | 目前只跑通 Mono；IL2CPP 后端（`GameAssembly.dll`）**未探索** |
| **非 Unity 引擎** | Godot / Ren'Py / RPGMaker 等无此数据层，走传统断点+指针链 |
| **反作弊** | 联网游戏或有反调试的游戏慎用；采集器注入会被检测 |
| **安全** | `openLuaServer` 是**无认证的本地管道**（等于任意 Lua 执行），仅在本机自用环境开启 |

### 10.2 各引擎成熟度

| 引擎 | 能力 | 状态 |
|---|---|---|
| **Unity Mono** | 静态字段 / 实例字段 / 无单例兜底 / 调托管方法 | ✅ 全部实测跑通 |
| **Unity IL2CPP** | — | ⏳ 待实测 |
| **Godot** | — | ⏳ 待实测 |
| **TyranoScript / Electron(V8)** | — | ⏳ 待实测 |
| **Ren'Py（Python）** | — | ⏳ 待实测 |
| **RPGMaker（RGSS / NW.js）** | — | ⏳ 待实测 |
| **原生 C/C++** | — | ⏳ 待实测 |

> 原则：**只写真实做过的**。没有实测的引擎留占位，等真实项目遇到时补，不做纸上推演。

### 10.3 安全开关

- `openLuaServer('CELUASERVER')` 是**无认证的本机命名管道**：
  本机任何进程都能让 CE 执行任意 Lua（= CE 的全部权限）。**仅限本机自用。**
- **临时关闭**：注释 `main.lua` 里 `pcall(function() openLuaServer('CELUASERVER') end)` → 重启 CE
- **彻底移除**：删 `dsh_lib.lua` / `ce-lua.ps1` / `ce-mcp.ps1` / `mcp\` / `extras\`，
  并用 `main.lua.orig-backup` 还原 `main.lua`
- **写值必须回读**；`auto_assemble` 会真的注入代码，先只读侦察

### 10.4 免责声明

本项目仅用于**单机游戏的个人学习与娱乐性修改**，以及逆向工程方法的学习记录。

- 请勿用于联机游戏、竞技游戏或任何违反游戏服务条款的场景
- 请勿用于商业用途或传播修改后的游戏本体
- 使用本仓库工具产生的一切后果由使用者自行承担

### 10.5 许可证

本项目采用 [MIT](LICENSE) 协议。第三方工具的协议见 `config.example.yaml` 的 `tools` 段：

| 工具 | 协议 |
|---|---|
| Cheat Engine | GPL-2.0 |
| Python | PSF |
| PowerShell | MIT |

---

## 附录：文档导航

| 我想…… | 看哪 |
|---|---|
| **快速上手用起来** | 本文 [第 4 章](#4-安装) → [第 5 章](#5-使用说明) |
| 查某条命令 | 本文 [第 6 章](#6-命令速查) |
| 出问题了 | 本文 [第 8 章](#8-故障排查) |
| 理解为什么这样设计 | 本文 [第 2 章](#2-核心原理) |
| 摸清一个 Mono 游戏的数据结构 | `docs/01-mono-recon.md` |
| 把找到的地址固定成重启后仍有效的条目 | `docs/02-stable-address.md` |
| 把条目打包成双击即用的独立修改器 | `docs/03-standalone-trainer.md` |
| CE 通道怎么用、怎么配 | `docs/04-ce-bridge.md` |
| 让 Agent 按标准流程作业 | `AGENT.md` |
| 照着现成的样板改 | `examples/`（先看 `examples/nurtale/README.md`） |

---

<div align="center">

**Nyaa be with you.**

</div>
