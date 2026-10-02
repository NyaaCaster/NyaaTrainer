# 游戏引擎数据修改方法论：总览与决策

> **本文解决什么**：拿到一个**非 Unity Mono**（或干脆不是 Unity）的游戏想改数值时，不知道"该走哪条路、
> 每条路的原理是什么、自家引擎吃哪一套"。本文给出**方法分类总表 + 每种方法适用引擎 + 选择决策树**，
> 细节在各方法分篇。
>
> **来源**：本仓库原有四篇（01~04）只覆盖 Unity Mono + CE 通道；本篇与 06~11 是对**一类成熟的多引擎
> 通用修改器实现**（对十几个引擎建立稳定变量修改的公开工具）的机制剖析与归纳，去工具名化后沉淀为
> 方法论，供后续遇到对应引擎时直接按方法作业。**实证载体**：`tools\` 下某多引擎通用修改器的
> V8 字节码主体与各引擎 hook DLL 的字符串/导出分析（2026-10-02 完成逆向归纳）。
>
> **配套 skill**：无（本篇是知识层，不涉及本仓库工具链的运行）。
> **与既有文档的关系**：方法 D 与 `01-mono-recon.md` / `02-stable-address.md` §7 同源互补；
> 方法 E 与 `02-stable-address.md` §3 两次筛选法同源。
> 建立：2026-10-02。

---

## 0. 核心思想：六条方法论

一个"通用多引擎修改器"能稳定工作，靠的不是万能内存扫描，而是**先判引擎 → 再选该引擎的"正规数据通道"**。
所有实现最终归纳为六条独立的方法论（每一篇文档一条）：

| # | 方法 | 一句话原理 | 分篇 |
|---|------|-----------|------|
| **A** | **运行时脚本求值（eval 通道）** | 往游戏**正在运行的脚本解释器**里注入一行脚本（JS/Ruby/TJS/Python/GDScript），让**游戏自己**报告与修改自己的变量 | `06-method-runtime-script-eval.md` |
| **B** | **数据文件与存档解析重写** | 按**引擎官方数据格式**直接解析/重写游戏数据文件与存档文件（`Game.dat`、`*.rpgsave`、`*.rxdata`…），不碰进程内存 | `07-method-data-file-parsing.md` |
| **C** | **引擎对象模型映射** | 引擎有**全局游戏状态单例**（`$gameParty`、`$game_switches`、`Agtk.variables`…）时，先把这些对象**枚举成"变量表"**再按 id 修改——这是 A 的数据层标准件 | `08-method-object-model-mapping.md` |
| **D** | **Mono/托管运行时调用** | Unity Mono 游戏直接调引擎的 Mono API：dump 类 → 找字段 → 调方法。必要时注入 DLL 用 WebSocket 服务**在进程内架桥** | `09-method-mono-runtime-invoke.md` |
| **E** | **内存扫描 + 锁定（兜底）** | 引擎没有暴露任何可编程通道时，退回"扫值 → 两次筛选 → 写入/锁定"；锁定的稳定实现是 **hook 写入函数**而不是周期重写 | `10-method-memory-scan-lock.md` |
| **F** | **解释器指令注入** | 脚本不可 eval 的引擎（RPG Maker 2k/2k3），通过**替换/扩展事件指令集**（给解释器加命令）实现修改——本质是"借用游戏自己的解释器跑我们的代码" | `11-method-interpreter-command-injection.md` |

**三种数据修改语义**（贯穿六法，先分清再动手）：

1. **改运行时值**：改"当前这一局"的变量（HP、金钱、好感度）。→ 方法 A/C/D/E
2. **改数据库**：改"定义"（物品数量上限、初始属性、事件指令）。→ 方法 B（编辑数据文件）
3. **改存档**：改"进度"（已获得物品、已开启开关、脚本变量快照）。→ 方法 B（编辑存档文件）

---

## 1. 引擎适用矩阵（每篇细节表的汇总）

| 引擎 / 运行时 | 判定特征 | A eval | B 文件 | C 对象映射 | D Mono | E 内存 | F 指令 |
|---|---|---|---|---|---|---|---|
| **RPG Maker MV/MZ**（NW.js/Electron, V8） | `www/js/rpg_core.js`（MV）/ `js/rmmz_core.js`（MZ）+ `package.json` | ✅ JS eval | ✅ `*.rpgsave`/数据 JSON | ✅ `$gameVariables`/`$gameSwitches`/`$gameParty` | — | ⚠️ 可用但多余 | — |
| **RPG Maker XP/VX/VX Ace**（RGSS, Ruby） | `Game.rgssad/rgss2a/rgss3a`、`Data/Actors.rxdata/rvdata/rvdata2`、Ruby DLL（1.8/1.9/3.1） | ✅ Ruby eval | ✅ 存档文件 | ✅ `$game_switches`/`$game_variables`/`$game_party` | — | ⚠️ | — |
| **RPG Maker 2k/2k3**（Ruby-less，需兼容运行时） | `RPG_RT.ldb` / `RPG_RT.lmt`、注册表 `ASCII\RPG2000` / `Enterbrain\rpg2003` | ❌ 无脚本通道 | ⚠️ 存档格式封闭 | ⚠️ 变量表经兼容运行时读取 | — | ✅ 内存锁定 | ✅ **主通道**（扩展指令） |
| **Wolf RPG Editor** | `Data/BasicData/Game.dat`、`DataSys/Data.wolf`、PE 版本资源 `WOLF RPG Editor` | ❌（C++ 引擎无脚本） | ✅ **主力**：`Game.dat`/存档解析 | ✅（以文件 DB 形态呈现变量） | — | ⚠️（可崩） | — |
| **Ren'Py**（Python 2.7/3.x） | `renpy.exe` / `renpy.py` / `*.rpa`、`renpy/__init__.py` | ✅ **Python eval**（接管主循环后常驻） | ✅ 存档 + `persistent` | ✅（`renpy.store` / store 变量树） | — | ⚠️ | — |
| **TyranoScript / TyranoBuilder**（NW.js, V8） | `package.json` + Tyrano 特征、`TYRANO.kag` 全局对象 | ✅ JS eval | ⚠️（存档 JSON） | ✅（`TYRANO.kag.stat.f` / `sf` / `tf`） | — | ⚠️ | — |
| **KiriKiri / krkr2 / krkrz**（TJS2） | `krkr*.exe`、`*.xp3`、TJS 符号（`tjsjson32/64.dll`） | ✅ TJS evalScript | ⚠️ 存档解析 | ✅（`Dictionary.saveStruct`） | — | ⚠️ | — |
| **SRPG Studio** | `srpg*.exe` 特征 | ✅ 专用 eval 通道 | ⚠️ 存档 | ✅ | — | ⚠️ | — |
| **Action Game Maker (AGTK)**（cocos2d-x, JS） | `Agtk` 全局、cocos2d 符号 | ✅ JS eval | ⚠️ | ✅（`Agtk.switches`/`Agtk.variables` + 实例对象） | — | ⚠️ | — |
| **Godot**（GDScript→字节码） | `*.pck`、`godot*engine` 串 | ✅ GDScript **文件执行**（非 eval 字符串） | ⚠️ | ✅（脚本内拿 `SceneTree`/autoload） | — | ✅（原生层） | — |
| **RPG Developer Bakin**（Unity Mono，Yukar 框架） | `SharpKmy*` / `Yukar.*` 程序集、`bakinplayer.exe` | — | ⚠️ | ⚠️ | ✅ **主力**（进程内 WebSocket 服务 + 调 `Yukar.Common.GameData`） | ⚠️ | — |
| **Unity（通用 Mono 游戏）** | `mono-2.0-*.dll` / `UnityPlayer.dll` + `Assembly-CSharp.dll` | — | ⚠️（IL 层可控时） | ⚠️ | ✅ **主力**（CE Mono API 或注入桥） | ✅ 兜底 | — |
| **Unity（IL2CPP）** | `GameAssembly.dll` | — | ⚠️ | ⚠️ | ⏳ 未探索 | ✅ | — |
| **通用原生 C/C++** | 以上全不中 | — | — | — | — | ✅ **唯一通道** | — |

> 优先级：**A（有就先 A）→ C（A 的数据层）→ D（Unity 系）→ B（改库/改档时）→ F（RM2k 类）→ E（兜底）**。
> B 与 A/C/D/E **正交**（改的是文件不是内存），按"要改的是运行时值还是定义/存档"另选。

---

## 2. 选择决策树

```
拿到一个游戏
│
├─ ① 判引擎：文件特征优先（§3），PE 版本资源兜底（§3.2）
│
├─ ② 是 Unity Mono 吗？
│     ├─ 是 → 方法 D（09 篇；本仓库 01/02 已跑通）+ E 兜底
│     └─ 否 ↓
├─ ③ 游戏是脚本解释器架构吗？（NW.js/RGSS/TJS/Python/GDScript…）
│     ├─ 是 → 方法 A（06 篇）：把一行脚本送进解释器
│     │        └─ 用方法 C（08 篇）的"对象映射"作为读写协议：
│     │           引擎有 $gameXXX / Agtk.variables 等全局单例 → 枚举成变量表改
│     └─ 否（原生引擎：Wolf / RM2k / Godot / 自研）↓
├─ ④ 要改的是"数据库/存档"还是"运行时值"？
│     ├─ 数据库/存档 → 方法 B（07 篇）：按引擎官方格式解析重写
│     ├─ RM2k/2k3 类 → 方法 F（11 篇）：扩展事件指令
│     └─ 其余运行时值 → 方法 E（10 篇）：内存扫描+锁定
│
└─ ⑤ 以上有产出后，固化成稳定条目 → `02-stable-address.md`；打包 → `03-standalone-trainer.md`
```

---

## 3. 引擎判定（动手前的第一件事）

### 3.1 文件特征判据（主判据，先看目录）

| 引擎 | 看什么 | 备注 |
|---|---|---|
| RPG Maker MV | `www/js/rpg_core.js` + `www/index.html` + `package.json` | MV 的 `rpg_core.js` 与 MZ 的 `rmmz_core.js` 名字不同 |
| RPG Maker MZ | `js/rmmz_core.js` + `data/System.json` | |
| RPG Maker XP/VX | `Game.rgssad` + `Data/Actors.rxdata`（XP）/ `.rvdata`（VX） | 归档在游戏根目录 |
| RPG Maker VX Ace | `Game.rgss3a` + `Data/Actors.rvdata2` | |
| RPG Maker 2k/2k3 | `RPG_RT.ldb` + `RPG_RT.lmt`（数据库/地图树） | 老引擎，通常配兼容运行时（EasyRPG 类）跑 |
| Wolf RPG Editor | `Data/BasicData/Game.dat` + `DataSys`/`DataBasic` 目录 | Game.dat 是**三大数据库 + 变量定义**的容器 |
| Ren'Py | `renpy.exe`（或 `lib/` 下 Python DLL）+ `*.rpa` 归档 + `renpy/` 目录 | 版本号可从 `renpy/vc_version.py` 读 |
| TyranoScript | `package.json` + `TYRANO.kag`（运行时）+ `data/` | TyranoBuilder 打包产物同源 |
| KiriKiri krkr2/krkrz | `*.xp3` 归档 + `krkr*.exe`；z 版带 `tjsjson32/64.dll` | krkrz 分 32/64 位 |
| SRPG Studio | `srpg` 相关文件名 + 自家数据目录 | 有专用 eval 通道 |
| AGTK | `Agtk` JS 全局 + cocos2d-x DLL 特征 | 变量/开关在 `Agtk.variables`/`Agtk.switches` |
| Godot | `*.pck`（+ 版本探测：hook 内有版本桶机制） | 4.x 与 4.2+ 的 GDScript 接口不同，需分桶 |
| RPG Developer Bakin | `bakinplayer.exe`、`SharpKmyGfx`/`SharpKmyBase`、`Yukar.*` | Unity Mono 的游戏引擎框架 |
| Unity 通用 | `UnityPlayer.dll` + `*_Data/Managed/Assembly-CSharp.dll`（Mono）；`GameAssembly.dll`（IL2CPP） | |
| NW.js / Electron 通用 | `package.json` + `node_modules` / `.asar` | RPG Maker MV/MZ 与 Tyrano 均属此类 |

### 3.2 PE 版本资源判据（文件特征不够时）

读游戏 exe 的 **PE 版本信息**（`ProductName`/`FileVersion`）：

- `WOLF RPG Editor` + 版本串（`2.x`/`3.x`）→ Wolf（2 与 3 数据格式不同，要分版本处理）
- `RGSS Player` → RPG Maker XP/VX/VX Ace
- Godot 版本从字符串探测（`godot *engine` 形态的版本标记）

### 3.3 运行时模块判据（已在 `02-stable-address.md` §4）

`mono-2.0-*.dll`（Unity Mono）、`GameAssembly.dll`（IL2CPP）、RGSS Ruby DLL、Python DLL、Electron/NW.js —— 见该表。

---

## 4. 承载通道：所有方法共用的"进不去就没法改"层

方法 A~F 都需要把代码/请求**送达**游戏进程。被剖析的工具实现了四种承载，从稳到险：

| 承载方式 | 原理 | 适用 | 特点 |
|---|---|---|---|
| **被动 DLL 注入（代理 DLL）** | 往游戏目录写 `winmm.dll` 或 `version.dll`（Windows 加载器搜索顺序自动加载） | 几乎所有 Win32 游戏 | 不改 exe；杀软误报率最低；游戏启动即注入 |
| **启动注入（OEP 注入）** | 用注入器**代替**游戏 exe 启动：以挂起方式创建进程 → 在入口点（OEP）写 shellcode → 加载 hook DLL | 几乎所有 Win32 游戏 | 最主动；需处理反作弊/杀软 |
| **运行中注入** | 直接 `CreateRemoteThread`/`LoadLibrary` 注入**正在运行**的进程 | MV/MZ、XP/VX/VXAce、Tyrano、Ren'Py | 调试期最方便；对启动链敏感的游戏（Steam 链）不适用 |
| **等待式注入** | 正常启动游戏，后台轮询**新出现的进程**并注入 | Steam 重启链、launcher 游戏 | 对"不许被动注入文件"的场景兜底 |

**回连通道**：注入的 hook DLL **不与外部共享内存**，而是作为 **WebSocket 客户端连回工具进程**
（`ws://127.0.0.1:<port>`，固定端口段；端口被占/被本地流量过滤软件拦截时全体功能失效——
排障先看这个）。DLL 内维护一个 **eval 队列**（生产者=WS 线程，消费者=游戏主线程定时取任务执行），
把"外部请求"转成"游戏线程内的安全调用"。

> ⚠️ **回连被拦截是通用修改器最大的环境坑**：本地环回被 AdGuard/杀软流量过滤/强制代理接管后，
> 所有引擎的修改功能集体失灵（表现为游戏起来了但工具连不上游戏）。这不是某个引擎的问题，
> 判据与解法见 `10-method-memory-scan-lock.md` §排障。

**进程内服务（Unity 系特有）**：对 RPG Developer Bakin 这类 Unity Mono 游戏，注入的 DLL 用 **0Harmony**
在进程内直接挂 .NET 方法，并起一个**进程内 WebSocket 服务**对外暴露（与回连方向相反：这次 DLL 是服务端）。

### 4.1 载体依赖的获取（两种方式，按依赖性质分流）

承载层用到的 hook DLL / 工具，按**是否有开源仓库来源**分两种获取方式：

| 方式 | 适用 | 做法 |
|---|---|---|
| **开源工具** | 有公开代码仓库的（如 RM2k 兼容运行时 Player） | 在对应分篇**标注下载来源**（仓库地址），工序用到时下载到 `runtime\tools\` |
| **无开源来源的钩子依赖** | 各引擎 hook DLL（版本桶、注入器、代理 DLL 池、PE 工具、Wolf 版本桶等） | 由 `runtime\bootstrap.ps1` 统一装配：下载 `GameHooks.7z`（URL 与 SHA256 白名单成对维护，见脚本顶部常量）→ 7z 免安装解压到 `runtime\tools\GameHooks\` → 安装包用后即删 |

> 分篇内提及的具体 hook 依赖（如 `wolfHook.dll`、`kmyHookUnity.dll`、Godot 版本桶 hook）默认都来自
> `runtime\tools\GameHooks\`；**方法论文档不指认这些依赖的出处来源，只声明"由 bootstrap 装配"**。
> 依赖缺失时先跑 `runtime\bootstrap.ps1`（或 `-SkipCeDeploy` 只补钩子段），不要临场找替代品。

---

## 5. 通用保险：改前的三件事（跨引擎 MUST）

1. **存档备份**：修改前把游戏存档整目录备份（存档格式各引擎不同，备份永远是安全的）；
   Wolf 类引擎甚至存在"原版 exe 无法读工具生成的存档"的格式兼容问题——**卸载工具前先删工具格式的存档**。
2. **改值先读值**：任何写入前先读回当前值建立基线；写入后回读验证。
3. **锁定要挂对位置**：锁定（数值不被游戏改回）优先用"引擎的写入口 hook"（方法 A/C/D 的天然优势），
   没有引擎通道才用周期重写；周期重写要限流并记录失败（对照 `02-stable-address.md` 的锁定章节）。

---

## 6. 分篇索引

| 分篇 | 方法 | 适用引擎（详表在篇内） |
|---|---|---|
| `06-method-runtime-script-eval.md` | A 运行时脚本求值 | MV/MZ、XP/VX/VXAce、Ren'Py、Tyrano、krkr2/krkrz、SRPG Studio、AGTK、Godot（文件形态） |
| `07-method-data-file-parsing.md` | B 数据文件与存档解析 | Wolf（主力）、MV/MZ、RGSS 系、Ren'Py、Tyrano、krkr（存档编辑共用底层） |
| `08-method-object-model-mapping.md` | C 引擎对象模型映射 | MV/MZ（`$gameXXX`）、RGSS（`$game_xxx`）、AGTK（`Agtk.*`）、Tyrano（`kag.stat.f`）、EasyRPG（变量表 API） |
| `09-method-mono-runtime-invoke.md` | D Mono/托管运行时调用 | Unity Mono 通用、RPG Developer Bakin（Yukar 框架） |
| `10-method-memory-scan-lock.md` | E 内存扫描+锁定 | 全引擎兜底；RM2k/2k3 的主力；原生引擎唯一通道 |
| `11-method-interpreter-command-injection.md` | F 解释器指令注入 | RPG Maker 2k/2k3（经兼容运行时的扩展指令） |
