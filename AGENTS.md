# AGENTS.md — Agent 作业规程（热 rule）

> **本文件是 Agent 的入口**。人类阅读请看 [`README.md`](README.md)。
>
> 目标：把游戏里的数值 **找出来 → 固定下来 → 做成能用的程序**。
> 四条主张：**先 dump 结构再谈扫描** / **记偏移不记地址** / **交付物是程序** / **全程可脚本化**。

---

## 0. 前置：确认运行时就绪（不依赖用户预装 CE）

**开工第一件事**：确认本仓库 runtime 已装配：

```powershell
Test-Path "<仓库根>\runtime\ce\Cheat Engine\cheatengine-x86_64.exe"
```

- **True（已装配）** → 直接进入 §1 开工。
- **False（clone 后首次）** → 引导用户运行 `runtime\bootstrap.ps1`（唯一装配入口）：
  1. **提前告知用户：CE 官网站点在国内网络通常需要代理，请先开翻墙软件**（bootstrap 会先做连通性探测，失败 3 次会停在同一条提示上）；
  2. 无网络可用 `-CePackage <本地安装包路径>` 离线装配；
  3. bootstrap 动作：下载 CE 7.7 → **7z 免安装解压**到 `runtime\ce\`（免装、免注册表、免驱动）→ 部署引导 → **用后即删安装包** → 文件级自检（`-TestChannels` 还可拉 CE 实试通道 1）。
- **不要**把用户自装的 CE 接进来（版本/组件不可控，无法保证满足项目需求）；本仓库只认 `runtime\ce\Cheat Engine` 这一部署。
- **内嵌 Python**：`<repo>\runtime\tools\python\python.exe` 已随仓库分发（3.12 embeddable，纯标准库，无 pip 需求），三个 Python 脚本优先用它跑；机器上的系统 Python 是备用。
- `config.yaml`（由 `config.example.yaml` 复制）**不再**登记 CE / games_root 路径；`games[].dir` 降为可选——会话现场确定后可填可不填。

**下文所有 `$CE_DIR` 统指 `<repo>\runtime\ce\Cheat Engine`（bootstrap 装配处），不要硬编码其它绝对路径。**

---

## 1. 文档索引（`docs/`）

两组方法论文档：**01~04 是本仓库工具链的作业法**（按"从零到成品"顺序）；**05~11 是多引擎通用修改方法论**（按方法分类，遇到对应引擎时查阅）。

### 工具链作业法（①→④）

| # | 文档 | 解决什么 | 何时看 |
|---|---|---|---|
| ① | [`docs/01-mono-recon.md`](docs/01-mono-recon.md) | 拿到一个没碰过的 **Unity Mono** 游戏，怎么摸清"哪个类的哪个字段是 HP" | **起点**。不知道数据在哪时 |
| ② | [`docs/02-stable-address.md`](docs/02-stable-address.md) | 把找到的地址**固化成重启后仍有效**的条目（4 种方法 + 分引擎） | 地址重启就失效时 |
| ③ | [`docs/03-standalone-trainer.md`](docs/03-standalone-trainer.md) | 打包成**双击即用的独立 exe**（含小面板 UI） | 要交付给用户时 |
| ④ | [`docs/04-ce-bridge.md`](docs/04-ce-bridge.md) | CE 与本仓库的**通道**（Agent 怎么驱动 CE） | 查命令、配通道时 |

```
① 摸清数据结构  →  ② 固定成稳定条目  →  ③ 打包成独立程序
                         ↑
                    ④ 全程靠它驱动（通道）
```

### 多引擎通用修改方法论（05~11）

> 来源：对一类成熟的多引擎通用修改器（对十几个引擎建立稳定变量修改的公开工具）的机制
> 逆向归纳（2026-10-02 完成，实证载体在 `tools\` 下；**文档已去工具名化**）。
> **遇到非 Unity Mono 引擎的游戏要改数据时，先读 ⑤ 总览选方法，再进对应分篇。**

| # | 文档 | 方法 | 适用引擎 |
|---|---|---|---|
| ⑤ | [`docs/05-engine-mod-methods-overview.md`](docs/05-engine-mod-methods-overview.md) | **总览**：六条方法论 + 引擎适用矩阵 + 选择决策树 + 引擎判定特征表 + 注入承载通道 | 全引擎 |
| ⑥ | [`docs/06-method-runtime-script-eval.md`](docs/06-method-runtime-script-eval.md) | A 运行时脚本求值（eval 通道：JS/Ruby/TJS/Python/GDScript） | MV/MZ、Tyrano、VNMaker、XP/VX/VXAce（RGSS）、krkr2/z、Ren'Py、SRPG Studio、AGTK、Godot |
| ⑦ | [`docs/07-method-data-file-parsing.md`](docs/07-method-data-file-parsing.md) | B 数据文件与存档解析重写（不碰内存） | **Wolf（主力）**、MV/MZ、RGSS 系、Ren'Py、Tyrano、krkr |
| ⑧ | [`docs/08-method-object-model-mapping.md`](docs/08-method-object-model-mapping.md) | C 引擎对象模型映射（`$gameXXX`/`Agtk.*` 变量表协议） | MV/MZ、RGSS、Tyrano、AGTK、krkr、Ren'Py、RM2k（兼容运行时 API） |
| ⑨ | [`docs/09-method-mono-runtime-invoke.md`](docs/09-method-mono-runtime-invoke.md) | D Mono/托管运行时调用 + 进程内桥（与 ①② 互补） | Unity Mono 通用、**RPG Developer Bakin**（Yukar 框架） |
| ⑩ | [`docs/10-method-memory-scan-lock.md`](docs/10-method-memory-scan-lock.md) | E 内存扫描+锁定（兜底法 + 锁定工程学 + 环回被拦排障） | 全引擎兜底；RM2k 锁定主力；原生引擎唯一通道 |
| ⑪ | [`docs/11-method-interpreter-command-injection.md`](docs/11-method-interpreter-command-injection.md) | F 解释器指令注入（兼容运行时扩展命令） | **RM2k/2k3（主力）**；Wolf 事件指令部分适用 |

**要点速览**

- **① Mono 侦察**：为什么别一上来扫内存（4 理由 + 两项目效率对比）／核心 5 步（列程序集 → dump 类清单 → 按名字锁候选 → dump 字段偏移 → 沿引用链找实例）／**三种数据形态**（静态字段型 / 实例字段型有单例 / **实例字段型无单例 → UI 管理器兜底**）／验证四步／坑位表（25+ 条）／`淫白の御供` 与 `Nurtale Nesche` 实战记录／**§8 调用托管方法 `mono_invoke_method`**（含管道安全与"按需建立管道"两条硬规矩）
- **② 稳定地址**：稳定条目三形态／7 步总流程／**方法 A** 写·读·执行断点（含数据断点 trap 语义）／**方法 B** 多级指针／**方法 C** Mono 静态字段 + `identify` 反查（**§7.6 调托管方法**、**§10.1.1 无静态单例的实例字段路径**）／**方法 D** GUI 指针扫描／两次筛选法／踩坑表
- **③ 独立修改器**：格式逆向（`stub + PE 资源 ARCHIVE/DECOMPRESSOR`、`.cepack`）／**无 GUI 全自动生成**／11 个必打包文件／小面板 UI（含**四个"看着能用其实不能用"的 API**、**任务栏显示**、`getControl(i)` 枚举控件）／**§4.4.1 界面结构规范：四模块分区 + 数值行控件排布 + 定值选项命名**／**§4.5.1 锁定功能只能有一个入口**／退出行为与残留进程／**DPI 陷阱与尺寸 API 不可靠的实测数据**／28 条坑位／**§7.1 生成侧自检**（含 Lua 作用域自查）
- **④ CE 通道**：三条通道（`ce-lua.ps1` 任意 Lua ／ `ce-mcp.ps1` 8 个成品工具 ／ `ce_mcp_server.py` 标准 MCP 服务端）／跨会话原理／各 Agent 客户端接入法／安全开关
- **⑤ 总览**：六法分类（A eval／B 文件解析／C 对象映射／D Mono 调用／E 内存兜底／F 指令注入）／**引擎适用矩阵**／选择决策树／**引擎判定特征表**（文件特征 + PE 版本资源）／四种注入承载（代理 DLL / OEP / 运行中 / 等待式）与回连通道
- **⑥ eval 通道**：各解释器注入原理（V8 `RequestInterrupt`／Ruby `rb_eval_string`+`rb_protect`+版本分桶／TJS V2Link 插件／Ren'Py **主循环接管**／Godot **脚本文件执行**无字符串 eval）／通用 eval 命令协议／**eval 永远在游戏主线程执行**铁律
- **⑦ 文件解析**：Wolf `Game.dat` 三库解析（SYS/User/Conf + Shift_JIS 码页 + 版本分桶）／MV/MZ JSON+VFS writeback／Marshal/pickle 存档**优先运行时改**／**工具写存档必须考虑原版引擎读取兼容**
- **⑧ 对象映射**：快照导出器模板（sparse/dict/bag）／各引擎对象表（MV/RGSS/Tyrano/AGTK/krkr/Ren'Py 路径寻址）／**定义($dataXXX) 与当前值($gameXXX) 分清**／**容器只读、写回必须走官方 setter**
- **⑨ Mono 调用**：CE Mono API vs 进程内桥两路径对比／进程内桥五 Mono 导出 + asmjit JIT／**Bakin 数据在引擎框架程序集（Yukar/SharpKmy）不在 Assembly-CSharp**／IL2CPP 未探索边界
- **⑩ 内存兜底**：什么时候才扫内存／**锁的三层实现**（hook setter 首选 → CE 断点 → 周期重写限流+停摆）／锁持久化按类型分文件／**环回被流量过滤软件接管的排障**（加白名单没用，测 RPC 延迟基线）
- **⑪ 指令注入**：RM2k 无脚本语言的通道＝兼容运行时 + 指令语义表／解释器级 API 清单／Maniac 扩展指令／**不要字节猜指令码，用开源运行时的规范**

---

## 2. 代码索引

| 文件 | 作用 |
|---|---|
| `src/ce_mcp_server.py` | **标准 MCP 服务端**（Agent 首选接入方式） |
| `src/ce-lua.ps1` | **主通道**：任意 Lua（多行/任意字符）→ 执行 → 取回文本 |
| `src/ce-mcp.ps1` | 8 个成品工具（读/写内存、AOB 扫描、反汇编…），无 Python 依赖 |
| `src/make_trainer.py` | **通用 trainer 生成器**：解 `.cepack` → 收文件 → 建归档 → 写 PE 资源 + **图标** |
| `src/NyaaTrainer_icon.ico` | ★ **统一图标**（7 尺寸）——`make_trainer.py` 默认用它写 exe 图标，并打进归档供窗口图标用 |
| `src/NyaaTrainer_icon.svg` | 图标的**矢量源文件**（改尺寸/换色时从它重新导出 ico，不直接参与打包） |
| `src/check_lua_scope.py` | **Lua 作用域自查**：查「使用早于 local 声明」（这类 bug 不报错，极难排查） |
| `src/CheatEngine-Manage.ps1` | CE 安装管理：Status / Sync / Migrate / Uninstall（**legacy 工具**——独立工作区后 runtime 目录即装即用，本脚本保留用于排查与卸载） |
| `bootstrap/ceMCP.lua` | CE 侧 MCP 文件通道轮询内核（社区扩展部署版，含 2 处补丁；`bootstrap.ps1` 负责复制到 `<CE_DIR>\extras\`） |
| `bootstrap/dsh_lib.lua` | CE 侧 Lua 往返桥（`dsh_out` / `dsh_eval` / `dsh_run_file`） |
| `bootstrap/dsh_stable.lua` | Mono **静态字段**稳定条目框架（`resolve` / `installAll` / `identify`） |
| `bootstrap/main_boot.lua` | 追加进 `<CE_DIR>\main.lua` 的三段引导正文（bootstrap.ps1 幂等部署） |
| `runtime/bootstrap.ps1` | ★ **装配器**：下载 CE 7.7 → 7z 解压 → 部署引导 → 删安装包 → 自检 |
| `runtime/tools/python/` | ★ 内嵌 Python 3.12 embeddable（三个 Python 脚本的运行时，无安装无 pip） |

**CE 侧需要加载的引导**（bootstrap.ps1 自动部署到 `<CE_DIR>\main.lua` 末尾，详见 `docs/04-ce-bridge.md`）：

```lua
pcall(function() openLuaServer('<pipe_name>') end)
pcall(function() dofile(getCheatEngineDir() .. 'dsh_lib.lua') end)
```

> `bootstrap/dsh_lib.lua` 需复制到 `$CE_DIR\` 下（CE 从自己的目录加载）——bootstrap.ps1 已自动化，手工部署时才需要照做。

---

## 3. 样板索引（`examples/`）

| 项目 | 表 | 数据形态 | 定位链 |
|---|---|---|---|
| `パンドラメイズ260427` | `examples/pandora/stable.CT` | **静态字段型** | `VariableF.currentSAN + 0x58`（JIT 内联静态地址） |
| `淫白の御供` | `examples/iyohaku/stable.CT`<br>`examples/iyohaku/stable.lua` | **实例字段型**（有静态单例） | `GameManager.Instance → +0x20 → GameData → +字段偏移` |
| `Nurtale Nesche` | `examples/nurtale/stable.CT`<br>`examples/nurtale/stable.lua` | **实例字段型 + 无静态单例**<br>+ **调托管方法改状态** | `GUIHUDManager.instance → healthGUI → health`<br>状态走 `TrySetLevel` / `SexualHeatManager.Set` |

**三个样例覆盖三种形态**：

- **静态字段型**：数据挂 `static_data`，绝对地址被 JIT 内联 → 最省事
- **实例字段型（有单例）**：从静态 `Instance` 沿引用链走
- **实例字段型（无单例）+ 需调方法**：★ 最难的一类，`Nurtale Nesche` 是范例
  —— 全程序集**没有任何静态字段**持有数据，只能从 **UI 管理器单例**兜底绕进去；
  且有些数值**光写字段无效**（界面不刷新 / 被覆盖），必须**调用游戏自己的方法**。

> `.CT` 与 `.CETRAINER` **是同一套 XML**，可直接喂给 `make_trainer.py`。

---

## 4. 标准作业流程（SOP）

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

### 每步验收判据（不可跳）

| 步 | 判据 |
|---|---|
| ② | 读出的数值**自洽**（比例与界面吻合 + 旁证字段说得通） |
| ③ | **写入测试**：改值 → 界面变化 → **用户确认** |
| ⑤ | **重启游戏**后脚本仍能解析出**新地址**且数值正确 |
| ⑥ | 修改器能在**干净环境**（其它 CE 全关、游戏重启过）下弹出面板并解析成功 |

---

## 5. 硬规矩

1. **改动前先备份**：`<CE_DIR>\main.lua` 等有 `.orig-backup` 的，改前确认备份在。
2. **不硬编码路径**：一切路径从 `config.yaml` 拼接；仓库内文件用相对路径。
3. **不要动用户的其它程序**：只操作明确指定的游戏/进程（曾有擅自改无关安装的教训）。
4. **写入必回读**：任何 `writeInteger` 后都要 `readInteger` 确认，且**验证完要还原**。
5. **表脚本里禁止裸 `<` 和 `&`**：`.CT` 是 XML，会**静默**导致脚本不执行（见 `docs/03-standalone-trainer.md` §5 坑①）。
6. **一个游戏一个表**：命名 `<code>_stable.CT`，与游戏目录同级管理。
7. **验证不跳步**：特别是"重启后仍有效"和"干净环境下能跑" —— 这是排除巧合的唯一手段。
8. **两个 CE 不能同时附加同一游戏**：Mono 采集器 DLL 注入后不随 CE 退出而卸载。
9. **自己启动的进程必须自己关**（§6）。
10. **不要替用户关他在用的程序**（§7）。
11. **面板尺寸必须在用户会话验证**：不同会话的字体度量可能差一倍（实测 `Font.Height` 16 vs 32），在非用户会话里看着正常的面板，用户那边可能大出一倍。**`getScreenWidth()` 与 `MainForm.Width` 都不能当屏幕宽度用**（跨会话不一致），宽度由内容决定 + 固定上限 + 名字列保底。
12. **⭐ 调托管方法前必须检查管道健康**：`mono_invoke_method` 走**每线程命名管道**，管道失效时继续调用会**让目标进程崩溃**（实测崩过两次）。调用前 `pipeOK()` 自检；**一次只做一个操作**；循环时每步复查；周期调用间隔 ≥200ms 并限流。详见 `docs/01-mono-recon.md` §8.4。
13. **⭐ 绝不手工改托管容器的内部结构**：`Dictionary` / `List` 的 entries/buckets/count 一律**只读**。实测手工插条目并修好哈希链，数据层验证全对但**游戏崩溃**。要改就调游戏自己的方法，见 `docs/01-mono-recon.md` §8.5。
14. **⭐ 共享变量声明在脚本最前面**：Lua 的 `local` 是**词法作用域** —— 函数定义时不可见的 local，在函数体里会退化成**读全局**（一边写 local、一边读 global，永远读不到，且**不报错**）。症状是"日志显示解析成功，运行却报未解析"。用 `src/check_lua_scope.py` 自查。
15. **写字段没反应就去调方法**：回读值变了但**界面不刷新**（或被游戏覆盖回来）= 那个字段是**显示副本**。真源常在**父类**（`enumFields`/`enumMethods` **只列本类声明**，看不到继承的）。见 `docs/01-mono-recon.md` §8.6。
16. **⭐ 锁定功能只能有一个入口**（用户明确要求的模板约定）：每个数值的锁定**只由该行自己的 `□` 按钮**负责；底部快捷按钮区**只放一次性动作**，不要「全部锁定/全部解锁」，也不要「<某项>锁定N%/解锁」这类与条目锁定重复的按钮。多入口 = 多处状态要同步 = bug 温床（实测因此出过"锁定中却没重设"）。见 `docs/03-standalone-trainer.md` §4.5.1。
17. **⭐ 面板宽度上限要用"实际可用宽度"**：内容无限展开会被 CE 的窗体上限裁掉（实测 `getScreenWidth()=1024` → 面板最多 1038，而布局按 1758 算 → 右侧控件全看不见）。`FW = max(每个横向区的宽度需求)`，**别漏区**；压缩分支里**所有**参与横向排布的宽度都要乘系数。
18. **锁定中的显示要读真值**：显示目标值会把"锁定失效"掩盖掉。真值 ≠ 目标时**标红**，让失败立刻可见。
19. **周期任务必须留痕**：`pcall(fn)` 会吞掉返回值 → 故障变成"日志一片空白"。周期重设要记录成功/失败（含心跳）；限流时间戳**只在成功后**更新。
20. **⭐ 修改器界面按四模块分区**（用户定稿的规范）：① **工具条**（修改器本体功能：刷新等，与游戏无关的放这里）② **数值修改**（用户可填任意值）③ **状态开关**（无数值的通断状态）④ **定值选项**（取值被游戏硬约束、互斥、不允许填任意值 —— **叫「定值选项」不是「定制选项」**）。状态开关类项目**不得**同时出现在数值区；底部只放一次性动作。见 `docs/03-standalone-trainer.md` §4.4.1。
21. **数值行控件排布**（用户定稿）：`[属性][当前] | [0][-][+] [MAX] | [输入框][应用] | [锁定]`。`0/-/+/MAX` 一组（直接改值，不需应用）；`输入框+应用` 一组（需提交）。`-/+` 与 `0`、`锁定` 用**正方形**控件，`MAX` 略宽（≤高度 1.5 倍，保证三字符不截断）。**上限性质的项隐藏 `0`**（=0 可能让游戏出错）；**无运行时上限的项隐藏 `MAX`**；隐藏时**保留占位**以维持按钮矩阵对齐。
22. **⭐ 图标统一用 `src/NyaaTrainer_icon.ico`**（`src/NyaaTrainer_icon.svg` 是矢量源，不参与打包）：`make_trainer.py` 会现场派生两种形态 —— 写进 exe 的 **DIB 格式**（PE 资源用）与打进归档的 **PNG**（窗口图标用），换图标只需替换那个 ico。表脚本用 `createPicture().loadFromFile()` + `f.Icon = pic.Icon` 设窗口图标。见 `docs/03-standalone-trainer.md` §4.1.2。
23. **模块标题不要用 `Font.Style` 设粗体**：LCL 的 `Style` 是集合类型，CE 的 Lua 里设不了（不报错但回读恒为 `[]`）。用 **`Font.Size`**（可写）+ 颜色 + 分隔线来区分层级。

---

## 6. 清理规范（强制）

> **教训**：曾为验证"删掉外部脚本后修改器还能不能跑"而启动修改器，检查完**忘了关**，
> 留下 3 个进程。用户此时已关掉自己的游戏和修改器，看到进程后以为是残留 bug。
> **悬空进程会污染用户判断，还会占着 Mono 采集器通道影响下次测试。**

### 铁律一：谁启动，谁关闭

验证必须**"启动 + 检查 + 关闭"三步一体**，不要跨消息留悬空进程。

```powershell
# 反例：启动了，检查完没下文
Start-Process $trainer; Start-Sleep 50; Get-Content $log

# 正例：同一段里收尾
$p = Start-Process $trainer -PassThru
Start-Sleep -Seconds 50
Get-Content $log                                                                    # 检查
Get-Process -Name '<修改器名>' -ErrorAction SilentlyContinue | Stop-Process -Force   # 关闭
```

若确实需要分离（要等用户操作），**必须在回复里写明"我启动了 X，稍后会关"**，并在下一步立即关闭。

### 铁律二：涉进程的操作，收尾查四样

```powershell
# 1) 遗留进程（修改器 / CE / 游戏）
Get-CimInstance Win32_Process |
  Where-Object { $_.Name -match '修改器|Trainer|cheatengine|<游戏名>' } |
  Select-Object ProcessId,Name,ExecutablePath | Format-Table -AutoSize -Wrap

# 2) 临时解压目录（每个约 30 MB）
foreach ($t in @("$env:TEMP\cetrainers", 'C:\Windows\Temp\cetrainers')) {
  if (Test-Path $t) { Get-ChildItem $t -Directory | Select-Object FullName }
}

# 3) 自己起的调试用 CE
Get-Process -Name 'cheatengine-x86_64*' -ErrorAction SilentlyContinue

# 4) 写在临时目录的探针脚本/测试文件
Get-ChildItem $env:TEMP -Filter '*test*' -ErrorAction SilentlyContinue
```

### 铁律三：清理要清到底

| 对象 | 清理方式 |
|---|---|
| 修改器进程链（3 个） | `Get-Process -Name '<修改器名>' \| Stop-Process -Force` |
| `%TEMP%\cetrainers\CETxxxx.tmp` | `Remove-Item ... -Recurse -Force`（先确认无进程占用） |
| 调试用 CE | `Get-Process -Name 'cheatengine-x86_64*' \| Stop-Process -Force` |
| 临时探针脚本 | 清掉自己在临时目录建的那些 |

### 交付物 vs 临时物

| 类别 | 例子 | 处置 |
|---|---|---|
| **交付物** | 修改器 exe、表 `.CT`、样板 | **保留**（游戏目录 / `examples/`） |
| **临时物** | 进程、`cetrainers` 目录、探针脚本 | **用完即清** |
| **证据物** | 运行日志（`*_trainer_log.txt`） | 排障期保留，结论落文档后可清 |

---

## 7. 不要替用户关他在用的程序（强制）

> **教训**：曾为"清出干净测试基线"，一条命令里把**用户正在玩的游戏**也强杀了。
> 用户看到的是**游戏闪退**，并一度怀疑是修改器把游戏搞崩的。

- **只清自己启动的东西**；用户的游戏 / CE / 修改器 —— **先问再动**
- 要动就说清楚：*"为了做隔离测试，需要关掉你正在运行的游戏，可以吗？"*
- 拿不准就只做**只读检查**（`Get-CimInstance` 查状态）
- **万一误关**：立刻承认是我做的、说明原因，不要让用户以为是他自己的软件出了问题

---

## 8. 签名约定

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

## 9. 外部依赖来源（bootstrap 自动获取；此表供排查与提示词参考）

| 依赖 | 用途 | 来源 | 协议 | 获取方式 |
|---|---|---|---|---|
| **Cheat Engine 7.7** | 内存修改引擎 | <https://cheatengine.org/> · <https://github.com/cheat-engine/cheat-engine> | GPL-2.0 | **bootstrap.ps1 自动**：官网包下载 → 7z 免安装解压到 `runtime\ce\` → 安装包用后即删。**⚠ 国内网络通常需翻墙（已写进 §0 agent 提示）** |
| **Python 3.12 embeddable** | 生成器 / MCP 服务端 / 作用域自查 | <https://www.python.org/downloads/windows/> | PSF-2.0 | **已内嵌** `runtime\tools\python\`（纯标准库用法，无 pip 需求） |
| **PowerShell 5.1+** | 通道脚本 | 系统自带 | — | Windows x64 自带，无需处理 |
| **7-Zip** | 解 CE 安装包（Inno Setup） | <https://www.7-zip.org/> | LGPL-2.1 | bootstrap 探测系统已有 7z；无则明确提示用户安装（站点访问不畅需翻墙）。本体不自动安装 |
| **ceMCP.lua（社区扩展部署版）** | 文件通道轮询内核 | CE 论坛 topic 623995（部署版在维护者服务器分发） | 见文件头 | 已随仓库入库 `bootstrap\ceMCP.lua`（SHA256 校验），无需联网 |

> 翻墙提示原则（用户拍板）：bootstrap 对每个外网下载做前置连通性探测（HEAD 3 次 × 5s），失败统一提示「该站点在国内网络环境下可能需要翻墙，请开启后重新运行」。GitHub clone 本仓库本身同理，由上层 agent 负责提示。

---

## 10. 边界与免责

| 事项 | 说明 |
|---|---|
| **仅限 Unity Mono** | 目前只跑通 Mono；IL2CPP 后端（`GameAssembly.dll`）未探索 |
| **非 Unity 引擎** | Godot / Ren'Py / RPGMaker 等无此数据层——**先读 `docs/05-engine-mod-methods-overview.md` 选方法**（eval 通道 / 文件解析 / 指令注入），CE 断点+指针链只作兜底（见 `docs/02-stable-address.md` §4） |
| **反作弊** | 联网游戏或有反调试的游戏慎用；采集器注入会被检测 |
| **安全** | `openLuaServer` 是**无认证的本地管道**（等于任意 Lua 执行），仅在本机自用环境开启 |
| **用途** | 仅限**单机游戏**的个人学习与娱乐性修改；不得用于联机/竞技/商业场景 |
