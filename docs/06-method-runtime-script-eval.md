# 方法 A：运行时脚本求值（eval 通道）

> **本文解决什么**：游戏本身就是**脚本解释器**（JS/Ruby/TJS/Python/GDScript）时，
> 把一行脚本送进**游戏自己的解释器**执行——游戏自己就拥有全部变量，根本不需要扫内存。
>
> **上位总览**：`05-engine-mod-methods-overview.md`。
> **数据层搭档**：读什么/写什么 → `08-method-object-model-mapping.md`（引擎全局对象映射）。
> 建立：2026-10-02。

---

## 0. 原理

脚本架构的游戏，所有游戏状态都活在**解释器的变量空间**里。外部工具只要能：

1. 把一段脚本字符串**送达解释器**（注入通道见总览 §4）；
2. 解释器**在游戏主线程**执行它（读/写变量、调函数都合法）；
3. 把执行结果**序列化回传**（字符串/JSON）。

——就得到了一个**完整的、类型安全的、引擎官方语义**的读写通道。优势：

| 优势 | 说明 |
|---|---|
| **零地址漂移** | 变量按**名字**访问，重启/读档不失效（对应 `02-stable-address.md` 的"引擎字段引用"思想） |
| **类型正确** | 解释器自己报类型（整数/字符串/对象），不会把 0.89 浮点误当 dword |
| **写入口正宗** | 走引擎的 `setValue`/`gain_item`，事件通知、UI 刷新自动发生（对照 01 篇 §8.6"必须调方法"的教训） |
| **免扫描** | 界面不显示的数值（好感度、事件开关）也能按 id 直接读写 |

---

## 1. 各解释器的 eval 原理与要点

### 1.1 NW.js / Electron（V8）→ JS eval —— RPG Maker MV/MZ、TyranoScript、VNMaker

**适用**：`www/js/rpg_core.js`（MV）/ `js/rmmz_core.js`（MZ）/ Tyrano。

**原理**：游戏是 V8 跑的网页应用。专用 hook DLL 被注入后：

1. 在游戏进程内**找 V8 Isolate**（导出符号 `v8::Isolate::GetCurrent` 等明文 mangling 名，
   按引擎自带的 V8 版本符号表匹配；两套符号集对应 V8 0.12.x 与新版——"Can't Find v8 Calls"即两套都没匹配上的报错）；
2. 用 `Isolate::RequestInterrupt` 把 eval 任务**安全地投递进主线程**（比粗暴起线程执行安全得多——
   V8 有 Isolate 线程亲和性）；
3. `Script::Compile` + `Script::Run` 执行 JS 字符串，结果 `JSON.stringify` 后经回连通道送回工具；
4. V8 对象（变量快照）通过 `Object::Get`/`Object::Set` 直接操作。

**注入入口（代码级）**：MZ/MV 的标准做法是 **hook 游戏的 `DataManager.loadDataFile`**（引擎加载第一个
数据文件的地方，此时 `$gameXXX` 尚未初始化但 V8 环境已就绪），在回调里预置修改器 bootstrap；
以及 hook `CreateProcessW`（游戏自行重启时保持注入）。

**加密游戏处理**：加密发行（`data/encryptData`、V8 加密资源 `InvokeVM encrypted resource`）时
`p2`（文件直读）不可靠，要改走 V8 eval 路径。

**坑**：

- 工具与游戏**必须有一个空闲 TCP 端口**做回连（端口被占→全体 cheat 功能失效，报"TCP port busy"）。
- V8 版本不匹配时先看符号表命中了哪套（`mzHookStage === 0` 是自检探针）。

### 1.2 RGSS（Ruby 1.8.7 / 1.9.3 / 3.1.3）→ Ruby eval —— RPG Maker XP/VX/VX Ace

**适用**：`Game.rgss3a`（VXAce）等 + `Data/Actors.rvdata2`。

**原理**：hook DLL 在游戏进程内**解析 Ruby 解释器的导出符号**（`rb_eval_string`、`rb_protect`、
`rb_string_value_ptr`、`rb_str_new_cstr`、`rb_define_global_function`、`rb_thread_call_without_gvl`）：

1. `rb_define_global_function` 注册一个**游戏侧 eval 命令**（这样游戏脚本也能主动请求工具）；
2. eval 队列（`concurrent_queue`）——WS 线程收任务，**游戏主线程**在每帧的调度点取出执行；
   每帧多取几次可用 `rapidEvalOn`/`rapidEvalOff` 切换（高频模式用于密集读写，平时关掉省帧）；
3. 执行用 `rb_eval_string` + `rb_protect`（异常保护，错误消息回传而非崩游戏）；
   `rb_thread_call_without_gvl` 用于在 Ruby 锁外做阻塞等待。

**版本分桶**：Ruby 1.8.7（XP/VX）、1.9.3（VX Ace）、3.1.3（mkxp-z 自定义运行时）三桶，符号地址不同必须分别解析。
**引擎版本探测**：向解释器送一行 Ruby——`defined?(rgss_main) ? '3' : defined?(Hangup) ? '1' : '2'`
（RGSS3 有 `rgss_main`、RGSS1 有 `Hangup`，其余为 RGSS2），配合 `load_data('Data/MapInfos.rvdata2')` 等文件探测双保险。

**eval 结果协议**：脚本自己用分隔符拼结果串（如 `varSpilt`/`lineSpilt`——工具与脚本约定好
分隔符），Ruby 端逐字段 `out << value << varSpilt`，工具端按分隔符拆列。
**老引擎兼容**：XP/VX 的 `$data_system.words` 与 VXAce 的 `$data_system.terms` 字段名不同，
脚本里用 `defined?`/`instance_variable_get` 做版本分支（HP/MP/TP 的名称字段三版各异）。

### 1.3 TJS2 → TJS evalScript —— KiriKiri krkr2 / krkrz

**适用**：`*.xp3` 游戏、`krkr*.exe`、krkrz 的 32/64 位两版。

**原理**：krkr 是插件式引擎，hook DLL 以 **V2 插件链接**（`V2Link` 导出，KAG 插件标准入口）被引擎加载：

1. 引擎启动时 DLL 的 `V2Link` 被调用（krkrz 32/64 两版分别匹配位数）；
2. 对外提供 `evalScript`（执行任意 TJS 语句）与 `evalExpression`（求表达式）；
3. 数据读取用引擎 API：`TVPCreateTextStreamForRead` / `TVPCreateIStream` / `getFileDataBin`
   （能读 xp3 内部文件——**xp3 归档由引擎解密，hook 借引擎之手读**）。

**修改变量的 TJS 惯用法**（引擎对象映射，详见 08 篇）：

```tjs
// 一次性导出游戏状态树(工具用约定分隔符读)
(function(){ try{ return (Dictionary.saveStruct incontextof %["f"=>f, "tf"=>tf, "sf"=>sf])("…"); }catch(e){ return e.message; } })()
```

**注入方式**：krkrz 支持环境变量指定插件目录（`GetEnvironmentVariableW`/`SetEnvironmentVariableW`），
也支持标准 Windows hook（`SetWindowsHookExW`）兜底加载。

### 1.4 Python → eval / 接管主循环 —— Ren'Py

**适用**：`renpy.exe` + `*.rpa`。

**原理**（这是**最精巧的一路**，也是对 Ren'Py 修改唯一稳定的路）：

1. **版本探测**：读主模块里注入器自带的版本标记常量（`__main__` 命名空间的注入标记属性）；
   7.x（6.18~7.7 各小版本，符号 `renpy6183`~`renpy773`）与 8.x（`renpy803`~`renpy860`）桶不同。
2. **Bootstrap 注入**：把一份**自研 Python 引导包**（路径/存档/字体/脚本加载补丁等若干 `.py`）
   通过 `*.rpa` 归档叠加（archive overlay）或直接 `exec` 注入游戏，**接管 renpy 主循环**
   （`mainLoopTakeover`）——接管后外部代码可在**每次主循环 tick**被调度，等于获得常驻执行权。
3. **Python eval 命令**：hook DLL（`PyImport_AddModule` / `PyImport_ImportModule` / `PyEval_InitThreads`）
   提供 `evalsingle`（单表达式）、`evalfile`（执行 .py 文件）、`evalIBin`（执行字节码）。
   工具侧的修改函数集（`RenpyCheat\initFuncs.py`）**作为 .py 文件注入游戏进程内注册成函数**，
   之后每条修改命令只是一次函数调用（`dict_to_json_data(search_variables(...))` 形态）。
4. **函数级 hook**：`hook_func_in_scope(fn, ...)` —— 对游戏脚本内的函数做**作用域安全**的包装
   （先验证 `fn.__globals__[name] is fn` 确认可替换，lambda 等匿名函数走 config 层包装）。
   例：包装 `renpy.config.say_menu_text_filter`、`renpy.store.parse_tstr` 观察文本流。

**锁实现**（详见 10 篇 §3）：`lock_set` / `lock_tick` —— 游戏侧记录锁条目，**每 tick 由接管的主循环**重写；
连续失败自动停摆（防错误锁把游戏拖死）。

**坑**：

- 游戏自带 Python 与工具注入 Python 的**版本不匹配**会导致 import 失败——先探测再用游戏自己的库（`useGameRenpyLib`）。
- 游戏带原生扩展模块（.pyx 编译产物）跨平台不能加载——属游戏自身限制，别当成注入失败。

### 1.5 GDScript → 脚本文件执行 —— Godot

**适用**：`*.pck`，4.x 系（hook DLL **按 Godot 版本分桶**：`ProbeGodotVersion` 探测 → 加载对应版本桶的
hook 实现；不兼容时报 "no compatible version bucket found"）。

**原理**：Godot 4.2+ 的 GDScript 用 **`Callable`** 体系，字节码字符串 eval 受限，
所以**不是 eval 字符串，而是落一个 `.gd` 文件再让引擎执行**：

1. 注入 DLL（`ExecuteScript` 导出 / `StartGodotHook`）在游戏进程内建立**主线程任务队列**
   （条件变量 + SRW 锁：外部线程投递，`SceneTree` 主循环执行——Godot 节点操作必须主线程）；
2. 工具把 GDScript 代码（如 `get_game_info.gd`、`extract_strings.gd`、`refresh_text_layout.gd`、
   `apply_visible_text.gd`）写到游戏可读位置，命令"执行 `GDScripts\<名>.gd`"；
3. 脚本里用 `Engine.get_main_loop()`（即 `SceneTree`）遍历节点、读写 autoload/变量，结果经回连通道返回
   （结果回传需要主循环就绪，主循环未就绪时 eval 结果无法返回）；
4. GDScript 可 `reload()`（`GDScript.reload failed` 是脚本错误时的报错），字体等资源操作走引擎 API
   （`FontFile` 加载失败会带 Godot 错误码回传）。

**注意**：这是 Godot 修改的**唯一脚本通道**——Godot 无运行时字符串 eval，别去找 `eval()`。

### 1.6 cocos2d-x（JS）→ JS eval —— Action Game Maker (AGTK)

**适用**：Agtk 全局对象存在的游戏（cocos2d-x 引擎 + JS）。

**原理**：同 V8 eval（§1.1 的流程），但**对象模型不同**：AGTK 把"开关/变量"暴露成 JS 全局
`Agtk.switches` / `Agtk.variables`（详见 08 篇 §4），eval 一行
`(function(){return {switches: Agtk.switches, variables: Agtk.variables}})()`
即可拿全量快照；写回用 `Agtk.variables.get(id).setValue(v)`。
对象实例的私有变量在 `Agtk.objectInstances.get(objId).variables.get(id).getValue()`。

**存档路径**：`GameManager.getSaveFilePath`（hook 点之一），存档内开关/文件槽在
`Agtk.switches.get(Agtk.switches.SaveFileId)` / `FileExistsId`。

---

## 2. eval 命令的通用协议（所有解释器一致）

被剖析工具在所有引擎上用的是**同一套命令面**，只是执行体不同：

| eval 命令 | 语义 |
|---|---|
| `eval`（字符串） | 送一段脚本进解释器执行，返回文本结果 |
| `evalIBin` | 送**字节码/二进制**执行（长脚本不占 WS 帧文本；各 DLL 均支持） |
| `evalfile` | 让解释器执行**一个磁盘上的脚本文件**（Ren'Py 的 initFuncs.py、Godot 的 .gd 都走这个） |
| `rapidEvalOn/Off` | RGSS 专用：切换单帧多次取 eval 的密集模式 |
| `doEvals` / `doEvalsSleep` | DLL 导出的队列处理入口（游戏主线程周期调用；`Sleep` 版是低频轮询） |

**队列语义（硬规矩级）**：eval 任务**永远在游戏主线程执行**（V8 用 `RequestInterrupt`、RGSS/TJS/Python
用每帧调度点、Godot 用主线程任务队列）。外部线程绝不直接碰解释器——这条与 `01-mono-recon.md` §8.4
"调托管方法必须健康检查 + 一次一个操作"是同一思想在别的引擎上的投影。

---

## 3. 方法 A 的适用引擎汇总

| 引擎/解释器 | eval 形态 | 版本分桶要点 | 主修对象（→08 篇） |
|---|---|---|---|
| RPG Maker MV/MZ、Tyrano、VNMaker | V8 JS eval（`RequestInterrupt`） | V8 0.12.x / 新版两套符号 | `$gameXXX` / `TYRANO.kag.stat.f` |
| RPG Maker XP/VX/VX Ace、mkxp-z | Ruby eval（`rb_eval_string`+`rb_protect`） | Ruby 1.8.7/1.9.3/3.1.3 三桶 | `$game_switches` 等全局 |
| KiriKiri krkr2/krkrz | TJS `evalScript`/`evalExpression`（V2Link 插件加载） | krkr2 与 krkrz、32/64 位 | `f/tf/sf` 字典 |
| Ren'Py | Python eval + 主循环接管 | 7.x / 8.x 桶 | `renpy.store` 变量树 |
| SRPG Studio | 专用 eval 通道 | — | 自家变量表 |
| AGTK | V8 JS eval | — | `Agtk.switches/variables` |
| Godot 4.x | **GDScript 文件执行**（无字符串 eval） | 版本桶（4.2+ Callable 体系） | `SceneTree`/autoload |

---

## 4. 操作骨架（可复用模板）

```powershell
# 以任意一个"脚本架构游戏"为例(此处以 V8 系为例;Ruby/TJS/Python 同构):
# ① 判引擎(总览 §3) → ② 选注入方式(总览 §4) → ③ 起游戏等回连
# ④ eval 一行探测:
#     V8:    typeof $gameVariables !== 'undefined'
#     Ruby:  defined?($game_variables)
#     TJS:   typeof global.f     (实际用 evalExpression)
#     Python: hasattr(renpy.store, 'vars')
# ⑤ 按引擎对象映射(08 篇)枚举变量表 → 修改 → UI 验证
# ⑥ 要固化的值: 重启后按**名字**重读(不记地址!) → 记进修改器配置
```

---

## 5. 坑位表（逆向归纳）

| 坑 | 现象 | 正解 |
|---|---|---|
| 只找了一套 V8 符号 | 老 NW.js 游戏连不上 | V8 0.12.x（MV 早期）与新 V8 是**两套 mangling**，都要试 |
| eval 队列在错误线程跑 | 随机崩溃 | 必须主线程执行：V8 `RequestInterrupt` / 每帧调度点 / Godot 主线程队列 |
| Ruby eval 不加保护 | 脚本异常直接崩游戏 | `rb_protect` 包住，错误串回传 |
| TJS 侧读 xp3 内文件用裸 IO | 读不到（xp3 加密） | 用引擎 API：`TVPCreateTextStreamForRead` / `getFileDataBin`，借引擎解密 |
| Ren'Py 直接 Python 注入不接管主循环 | 一次性执行后无常驻执行权 | 必须接管主循环（bootstrap + `mainLoopTakeover`）再谈周期功能 |
| 回连端口被占/被拦截 | 全引擎 cheat 失效 | 固定端口段自检；被本地过滤软件接管时关掉流量过滤 |
| Godot 想找 eval 字符串接口 | 找不到（没有） | 落 .gd 文件 + 引擎执行（`ExecuteScript`），按版本分桶 |
| RGSS 三代术语字段名不同 | HP/MP 名称取错 | `defined?` 分支：XP=`$data_system.words`、VX=`instance_variable_get("@hp")`、VXAce=`$data_system.terms.basic[2]` |
| 加密发行游戏走文件直读 | 拿到乱码 | 改走 eval 通道（引擎自己能解密） |

---

## 6. 与其它方法的关系

- **A → C**：eval 只是"通道"，读什么改什么由 08 篇的**对象映射**决定——两者合起来才是完整修改能力。
- **A vs B**：改运行时值用 A；改数据库/存档定义用 B（07 篇）。Wolf 没有 A 可用（原生引擎），B 是它主力。
- **A vs E**：有 A 绝不用 E（内存扫描）——A 是官方语义、零漂移；E 只作兜底或锁定挂点补充。
- 固化与打包：`02-stable-address.md` / `03-standalone-trainer.md`。
