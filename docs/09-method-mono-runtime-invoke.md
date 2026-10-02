# 方法 D：Mono/托管运行时调用与进程内桥（Unity 系）

> **本文解决什么**：Unity Mono 游戏改数值的完整方法论——本仓库已有 `01-mono-recon.md`（CE Mono API
> 侦察）与 `02-stable-address.md` §7（Mono 字段固化），本文补充**逆向归纳的另一条工业实现路径**：
> **注入 DLL 在游戏进程内架桥**（Harmony 挂钩 + 进程内 WebSocket 服务），并覆盖
> **RPG Developer Bakin（Yukar 框架）**这一 Unity 系特例。
>
> **上位总览**：`05-engine-mod-methods-overview.md`。
> 建立：2026-10-02。

---

## 0. 两条实现路径的对比

Unity Mono 改数据有两条等价路径，**二选一或混用**：

| 路径 | 机制 | 优势 | 局限 |
|---|---|---|---|
| **路径 1：CE Mono API（本仓库主力）** | CE 注入 MonoDataCollector 采集器 → `mono_*` Lua API 摘类结构/读写字段/调方法 | 零开发成本、有 CE 全套扫描兜底 | 每次开机要手动加载 monoscript + LaunchMonoDataCollector；调方法后 Mono 偶发掉线（01 篇 §8.7） |
| **路径 2：进程内桥（本篇新增）** | 注入自研 DLL → 引用 Mono 库 API（`mono_get_root_domain` / `mono_assembly_open` / `mono_class_from_name` / `mono_class_get_method_from_name` / `mono_runtime_invoke`）+ **asmjit JIT** 编译原生胶水 → 进程内起 WebSocket 服务对外暴露 | 常驻、可自由扩展协议、不依赖 CE | 要写 C++ DLL；杀软误报需处理 |

两条路径的**方法论内核相同**（见 `01-mono-recon.md`）：

```
列程序集 → dump 类清单 → 按名字锁候选 → dump 字段偏移 → 沿引用链找实例 → 写字段/调方法
```

---

## 1. 路径 2 的实现要点（进程内桥）

> **本篇涉及的注入 DLL 依赖**（`MonoJunkie` 形态 x86/x64 两版、`0Harmony.dll`、Bakin 侧
> `kmyHookUnity.dll` + 启动替换组件）已由 `runtime\bootstrap.ps1` 装配到 `runtime\tools\GameHooks\`
> （见 05 篇 §4.1）；注入动作走 CE，无需独立注入器。

### 1.1 DLL 侧：Mono 运行时访问

样本工具的注入 DLL（x86/x64 两版，`MonoJunkie` 形态）只引用**五个 Mono 导出**就够用：

| Mono API | 用途 |
|---|---|
| `mono_get_root_domain` | 拿根域（一切遍历的起点） |
| `mono_assembly_open` → `mono_assembly_get_image` | 打开程序集拿镜像 |
| `mono_class_from_name` | 类名 → 类指针 |
| `mono_class_get_method_from_name` | 类+方法名 → MethodInfo |
| `mono_runtime_invoke` | **调用托管方法**（改状态的正宗入口，同 01 篇 §8） |

**JIT 能力**：DLL 静态链接 **asmjit**（x86/x64 汇编器）——在目标进程内**现场编译原生胶水代码**
（例如把"调用托管方法 + 数值转换"编译成一段机器码 stub，绕过托管/原生调用约定差异）。
这是"运行时调用托管方法"的高性能形态。

### 1.2 通信：进程内 WebSocket 服务（与回连相反的方向）

- Unity 系的注入 DLL **自己当 WebSocket 服务端**（工具是客户端）；
- 协议消息自带 schema（`FullyQualifiedDataSetSchema` / `WebsocketRequestPackage` /
  `WebsocketResponsePackage` / `socket_OnMessage`）——请求/响应成对，支持长连;
- 服务自连重试（`serverSocketAutoConnect`）。

> **方向对比**：非 Unity 引擎（RGSS/TJS/V8/Python）的 hook DLL 是 **客户端**（连回工具）；
> Unity Mono 桥是 **服务端**（等工具来连）。原因：Unity 游戏进程生命周期长、环境复杂，
> 服务端模式让工具侧的重连/多开更可控。

### 1.3 Harmony 挂钩（0Harmony.dll）

样本工具的 Unity 系加载器**自带 0Harmony**：在托管层**运行时挂钩 .NET 方法**
（替换/前置/后置），比原生 hook 更贴合托管对象模型——适合"改方法参数/返回值"类修改
（比如把"扣血"方法改成不动血）。

---

## 2. RPG Developer Bakin（Yukar 框架）——Unity 系特例

Bakin 是**用 Unity 做的 RPG 引擎**，游戏状态在 `Yukar.Common.GameData` 等框架类里，
不在游戏自带的 `Assembly-CSharp` 里。

### 2.1 识别

- 文件：`bakinplayer.exe`（Unity 构建的播放器）、`data/bakinplayer.exe`；
- 程序集：`SharpKmyBase` / `SharpKmyGfx`（Bakin 的 Unity 桥接库）、`Yukar.Common.GameData`
  （框架数据层：`SystemData` / `MapData` / `BattlePlayerData` / `battleStatusData` / `LogData`…）；
- 变量语义从框架类走：数值变量/字符串变量/开关在 `GameData` 的容器里（`IFVARIABLE` /
  `HLVARIABLE` / `IFSWITCH` / `CHANGE_STRING_VARIABLE` / `BTL_VARIABLE` / `SW_SAVE` 等
  指令名常量直接暴露了框架的变量操作语义）。

### 2.2 修改通道

- 注入 `kmyHookUnity.dll`（x86/x64 桶 `kmyU86`/`kmyU64`）→ **进程内 WebSocket 服务** →
  工具侧 `KmyImpl`/`BakinImpl` 通过它读写 `Yukar.Common.GameData`；
- 启动方式：`BakinLauncher.exe`（游戏启动器替换）+ `BakinPlayerWrapper.exe`（播放器包装），
  保证注入发生在 Unity 引擎初始化之前；
- 地图/事件位置读取走框架（`KmyMapEx: Failed to update event positions` 等错误串说明
  事件位置是框架维护的）。

### 2.3 通用教训

> **"引擎框架类"往往才是数据真源**：Bakin 游戏的数值不在 `Assembly-CSharp`（那是模板代码），
> 而在引擎框架程序集（`Yukar.*`/`SharpKmy*`）里。**dump 类清单时必须枚举全部程序集**，
> 不能只看游戏自己的——与 01 篇"字段真源常在父类"是同一教训的两个方向（父类 vs 框架程序集）。

---

## 3. 操作骨架（进程内桥路径）

```
① 判引擎: UnityPlayer.dll + mono-2.0-*.dll (Mono) / GameAssembly.dll (IL2CPP→本仓库未探索)
② 注入: OEP 注入/被动 DLL/运行中注入(总览 §4)
③ 桥就绪: WebSocket 端口握手 → 发 dump 类清单请求
④ 侦察: 按名字锁候选类/字段(01 篇 §2 的 5 步) → dump 字段偏移
⑤ 读值验证: 界面值与字段值对照(01 篇 §3)
⑥ 写入: 字段写入 OR mono_runtime_invoke 调 setter(优先) → 界面验证
⑦ 固化: 类名+字段偏移记入修改器配置(02 篇方法 C) → 重启验证 → 打包(03 篇)
```

---

## 4. 坑位表（本篇新增部分；01/02 篇的坑同样适用）

| 坑 | 现象 | 正解 |
|---|---|---|
| 只枚举 `Assembly-CSharp` | Bakin 类游戏找不到数据 | 枚举**全部程序集**；引擎框架程序集（Yukar/SharpKmy）常是真源 |
| 直接戳 Mono 导出表按地址调 | 版本差异崩 | 只用稳定导出（§1.1 五个）+ JIT 胶水（asmjit）补调用约定 |
| 进程内服务无重试 | 网络抖动后失联 | 服务端模式 + 客户端自动重连 |
| 托管方法调用不带参数 schema | invoke 失败/类型错 | 请求/响应带 schema 成对（请求包/响应包） |
| 32 位 Unity 游戏用 64 位 DLL | 加载失败 | x86/x64 两套（含 asmjit 两版） |
| IL2CPP 游戏按 Mono 处理 | 找不到 mono 导出 | 先判 `GameAssembly.dll`；IL2CPP 走元数据/IDA 路线（本仓库 ⏳） |

---

## 5. 与其它文档的关系

| 想做什么 | 看哪 |
|---|---|
| 用 CE 直接侦察 Mono 数据结构（不写 DLL） | `01-mono-recon.md`（**首选**，零开发成本） |
| 把字段固化成稳定条目 | `02-stable-address.md` §7 方法 C |
| Bakin/Yukar 框架游戏 | 本文 §2 |
| 需要常驻桥/扩展协议时 | 本文路径 2（注入 DLL + 进程内 WS） |
