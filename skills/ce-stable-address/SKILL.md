---
name: ce-stable-address
description: '把 Cheat Engine 里找到的游戏数值地址固化成"重启/读档后仍然有效"的稳定修改项（Unity Mono 静态/实例字段、多级指针链、AOB 特征码）。当用户要求"把这个地址做成永久条目""重启后地址就失效了""指针扫描""找出基址+偏移""追谁写了这个值""用 CE 改游戏数值并固化"，或想知道"这个地址是哪个类的哪个字段"时使用。Use when the user asks to 稳定 CE 地址 / 固化修改项 / 指针扫描 / 找基址偏移 / 重启后地址失效 / make a CE address permanent, or mentions Unity Mono/IL2CPP 字段定位、写断点追址、Mono 静态字段反查。'
---

# CE 稳定地址（ce-stable-address）

把"浮动地址"变成 CE 里**重启/读档后仍然有效**的条目。

> **本 skill 只给决策与流程骨架**；每种方法的完整命令、参数、踩坑、分引擎细节在
> **`docs/02-stable-address.md`**（细节主文档）。通道与工具用法见 `docs/04-ce-bridge.md`。
> 这么分层是因为"引擎 × 方法"≈ 49 种组合，全塞进 skill 会每次白烧上下文。

## 触发条件

- 用户要把 CE 找到的地址做成**永久/稳定**条目
- 抱怨"**重启游戏或读档后地址就失效了**"
- 要求**指针扫描**、找**基址+偏移**、追"谁写了这个值"
- Unity 游戏要求用 **Mono/IL2CPP 字段**定位
- 要求把某个游戏数值改好后**下次还能用**

## 前置条件（缺一不可）

| 条件 | 检查方式 |
|---|---|
| CE 在运行且桥可用 | `& '<CE_DIR>\ce-lua.ps1' -Code "return 6*7"` → `RETURN: 42`（CE 未开可加 `-StartCe`） |
| 已附加目标进程 | `openProcess(getProcessIDFromProcessName('<游戏>.exe'))`，返回 true |
| **已知当前值所在地址 T** | 还不知道就先用「两次筛选法」定位 —— **不要用"值看起来像什么"去猜** |

> 用户自己桌面会话开着 CE 时也适用：`ce-lua.ps1` 可从 DSH 的 Session 0 直接连上（✅ 实测跨会话可用）。
> Mono 游戏还需 **Mono 采集器已附加**（`mono_AttachedProcess` 非空）；用
> `dofile(getCheatEngineDir()..'autorun\\monoscript.lua')` + `LaunchMonoDataCollector()`。

## 7 步流程

| 步 | 动作 | 产出 |
|---|---|---|
| ① | 通道就绪 + 附加进程 | 能远程执行 Lua |
| ② | **两次筛选法**定出当前地址 `T` | 例 `1AFE3EABEF8`（并用写入测试+界面确认） |
| ③ | `enumModules()` 判断引擎 | 选方法 A/B/C/D |
| ④ | 追根：断点 / Mono / 指针搜索 / GUI 指针扫描 | 候选链 |
| ⑤ | 建立条目 | MemoryRecord 或 Mono 解析声明 |
| ⑥ | **重启游戏或读档 → 重新解析 → 检查条目是否仍正确** | 唯一链 ← **不可省** |
| ⑦ | 把该引擎的经验补进细节文档第 10 节 | 文档 |

## 最短路径：Unity Mono 静态字段（✅ 2026-09-18 实测跑通）

碰到 Mono 游戏**先走这条**，比指针扫描快一个数量级：

```
① 两次筛选法定出 T
② 读断点抓访问指令：debug_setBreakpoint(T, 4, bptAccess)    ← 不必等玩家操作，UI 每帧读
③ 反汇编 RIP 处：看到 mov reg, <绝对地址>  → 判定为 Mono 静态字段
   ⚠️ 数据断点的 RIP 是【访问指令的下一条】！真正的访问在 RIP 往前数十字节内
④ 反查：dofile(getCheatEngineDir()..'dsh_stable.lua') ; dsh_stable.identifyReport(T)
   →  类名.字段名 + 0x偏移  以及 static_data 基址
⑤ 建条目：dsh_stable.define(...) → dsh_stable.installAll()
⑥ 重启游戏 → 重跑 installAll()（或事先 enableAuto()）→ 地址自动重算
```

**为什么成立**：Mono 的 JIT 把**静态字段**的绝对地址直接内联成 `mov reg, imm64`
（`static_data` 由运行时分配 → 每次启动变址），但 **`类名 + 字段偏移` 恒定**，
所以"声明 + 运行时解析"就是稳定条目。

**反查结果长这样**（实测）：

```
dsh_stable.identifyReport(0x1AFE3EABEF8)
-- 'VariableF' @ VariableF.currentSAN + 0x58  (base 1AFE3EABEA0)
```

## 方法决策表

| 引擎特征（`enumModules()`） | 首选方法 | 细节文档 |
|---|---|---|
| `mono-2.0-*.dll`（Unity **Mono**） | **C: Mono 静态字段 + `identify` 反查**（✅ 已跑通）；实例字段用 A | §7 / §10.1 |
| `GameAssembly.dll` + il2cpp（Unity **IL2CPP**） | **A: 写断点** → 结构体偏移 | §5 / §10.2 |
| 无托管层（原生 C/C++、Godot） | **A: 写断点** → **B: 指针搜索** | §5 / §6 |
| Electron / NW.js（TyranoScript、部分 RPGMaker） | A/B（V8 堆对象） | §10.4 |
| Python（Ren'Py） / RGSS（RPGMaker） | A/B（解释器对象） | §10.5 / §10.6 |
| 自动化都不收敛 | **D: CE GUI 指针扫描**（人工，需重启过滤） | §8 |

**方法快览**：

- **A 断点（最直接）**：`debug_setBreakpoint(T, 4, bptWrite)`（会自动启用调试器）→ 让**游戏自己写**该值 →
  回调 `debugger_onBreakpoint()` 读 `RIP` 与"接近 T 的寄存器" → 得到"基址寄存器 + 偏移" → 逐级向上。
  - ⚠️ **CE 自己的 `writeInteger` 不触发断点**（走 WriteProcessMemory），必须让游戏/玩家触发。
  - 💡 **不想等玩家操作就改用读断点 `bptAccess`**（UI 每帧读，几乎立刻命中）；
    已知访问函数入口时可用**执行断点** `bptExecute`，回调里读 `[RSP]`/`[RBP+8]` 拿**调用者返回地址**再反汇编调用点。
  - ⚠️ 读断点必须**设命中上限并在回调里自动卸断点**，否则每帧中断会卡死游戏。
- **B 指针搜索（纯内存）**：`MemScan soExactValue + vtQword`（✅ 与 AOBScan 结果一致）逐级找"存有指向下层地址的指针"的存储位置；
  每级**先只扫模块静态区**（几百 KB，瞬间）；必须带 `MEM_MAPPED`，否则漏指针。
  ⚠️ **Mono 游戏的 PE 静态段里 0 命中**（静态数据在运行时分配的 static_data 区）→ 别白费功夫，直接走 C。
- **C Mono 字段**：`dofile(getCheatEngineDir()..'autorun\\monoscript.lua')` → `LaunchMonoDataCollector()` → `mono_*` API。
  - 静态字段：`mono_class_getStaticFieldAddress(domain, class)` + `mono_class_enumFields` 的 `offset`。
  - ⚠️ `mono_object_getClass(x)` 只接受**对象起始地址**，字段地址会返回 nil。
  - ⚠️ `mono_image_enumClasses(image)` 返回 **table**（元素 `{class=, classname=, namespace=}`），不是裸指针。
- **D GUI 指针扫描**：Lua 侧没有指针扫描 API（`celua.txt` 里 `pointerscan` 零匹配），只能在 CE 界面做 + 重启过滤。

## 两次筛选法（核心方法论，必须掌握）

```lua
-- ① 初扫：多种"假设表示"各扫一遍，**保留 memscan 对象**
_G.scans = {}
for _, s in ipairs({ {n='float 0.89', vt=vtSingle, v='0.89'}, {n='dword 89', vt=vtDword, v='89'},
                     {n='dword 8900', vt=vtDword, v='8900'} }) do
  local ms = createMemScan()
  ms.VariableType, ms.ScanOption, ms.Scanvalue, ms.ScanWritable = s.vt, soExactValue, s.v, scanInclude
  ms.scan(); ms.waitTillDone()
  _G.scans[#_G.scans + 1] = { name = s.n, ms = ms }
end
-- ② 让玩家改变数值（记录界面新值）
-- ③ next scan：只留"值变了"的
for _, s in ipairs(_G.scans) do
  s.ms.ScanOption = soChanged; s.ms.scan(); s.ms.waitTillDone()
  -- s.ms.FoundCount 即剩余候选数
end
-- ④ 再筛"当前值 == 新值"（1.0 / 100 / 1000 / 10000 对应 100%）
-- ⑤ 写入一个明显值 → 让玩家看界面确认 → 命中
```

## 工具入口

```powershell
$ce = '<CE_DIR>'          # 或用户自己的 CE 目录
& "$ce\ce-lua.ps1" -Code "return 6*7"                     # 任意 Lua（多行也行）
& "$ce\ce-lua.ps1" -File "$ce\myscript.lua"               # 长脚本走文件更稳
& "$ce\ce-mcp.ps1" -Tool read_memory -Addr 0x1AFE3EABEF8 -Type 4
```

**Mono 稳定条目框架**（本机已就位）：`<CE_DIR>\dsh_stable.lua`

```lua
dofile(getCheatEngineDir() .. 'dsh_stable.lua')
dsh_stable.installAll()                              -- 解析并写入地址列表
dsh_stable.report()                                  -- 打印条目 + 当前地址
dsh_stable.identifyReport(0x1AFE3EABEF8)             -- 反查：地址属于哪个类/字段
dsh_stable.installWithRetry()                        -- 等 Mono 附加完成再装
dsh_stable.enableAuto()                              -- 开进程后自动装（包装 OnProcessOpened）
```

## 硬规矩（违反会翻车）

1. **写入后必须回读**，并让玩家在界面上确认。
2. **任何链都要经过一次"重启/读档"验证**才算完成——这是排除巧合的唯一手段。
   （Mono 静态字段的"验证"= 重启后重新解析，地址变了但**值仍与界面一致**。）
3. **不要用"值看起来像什么"的模式猜地址**。实测教训：`0~1 浮点紧跟 1.0` 这种"特征"命中的全是
   **颜色分量**（`214/255 = 0.839216`，NVIDIA 驱动 DLL 里同样命中）和 UI 近似值。
4. **真值的多份副本必须完全一致**；值彼此不一致的一批候选不是同一个逻辑值。
5. **数据断点报告的 RIP 是「访问指令的下一条」**（trap 语义）。看到命中处是 `xor eax,eax` 别困惑，
   真正的访问指令在 `RIP` 前面（用 `getInstructionSize` 反推）。
6. 删除 CE 记录只能用 **`memoryrecord:delete()`**（`AddressList` 上没有删除方法，`pcall` 会静默失败）。
7. CE 记录的 `Description`、以及 `string.find` 的匹配关键字**一律用 ASCII**（中文描述匹配不上）。
8. Lua `string.format` 里的字面百分号要写 `%%`。
9. **不要覆盖 `MainForm.OnProcessOpened`**（`monoscript.lua` 已用它自动附加 Mono）——先存旧值再包装。
10. 报告前先验证；发现自己的判断被推翻时**主动纠正**（如实说明哪一步错了）。

## 坑位速查

| 坑 | 正解 |
|---|---|
| 只扫 `MEM_PRIVATE` → 指针全漏 | `setSpecialScanOptionsOverride({MEM_PRIVATE=true, MEM_IMAGE=false, MEM_MAPPED=true})` |
| `soValueBetween` 的 `Scanvalue1/2` 不生效（实测扫出 174 万全范围值） | 用 `soExactValue`，或 AOBScan 高字节通配 + Lua 过滤 |
| `getNameFromAddress()` 判断"是否在模块内" | 对堆地址返回地址本身 → 用 `enumModules()` 的 `Address/Size` 自己比区间 |
| `enumModules()` 当对象用（`mods.Count`） | 它是普通表，`pairs` 遍历，元素 `{Name,Address,Size,PathToFile,Is64Bit}` |
| Mono 游戏在 PE 静态段找不到指针 | 静态数据在运行时分配的 static_data 区 → 走方法 C |
| `mono_image_enumClasses` 的元素当裸指针用 → 名字为空 | 元素是 table：取 `rec.class` / `rec.classname` / `rec.namespace` |
| 断点命中 0 次 | CE 自己写不触发；必须让游戏自己写（或改用读断点） |
| 读断点不设上限 → 游戏卡顿 | 回调计数，抓够 N 次就 `debug_removeBreakpoint` |
| PowerShell here-string 传 Lua 报"请用 -Code 提供代码" | 赋值与引用的**变量名要一致**（`$lua = @'…'@` 配 `-Code $lua`） |
| 重启游戏后 resolve 报 "mono collector not attached" | 游戏重启会让 Mono 采集器掉线（`mono_AttachedProcess=nil`）：先 `LaunchMonoDataCollector()` 等约 5 秒，再 `installAll()` |

## 索引（细节主文档 `docs/02-stable-address.md`）

| 需要什么 | 看哪节 |
|---|---|
| 稳定条目的三种形态 / 总流程 | §0 / §1 |
| 通道与常用 Lua 片段 | §2 |
| 两次筛选法详解 | §3 |
| 引擎判断 | §4 |
| 方法 A 写/读/执行断点（含完整回调代码、trap 语义） | §5（§5.4 读断点） |
| 方法 B 多级指针搜索（含模块静态段直扫） | §6 |
| 方法 C Mono 静态字段 + 反查 + `dsh_stable.lua` | §7 |
| 方法 D GUI 指针扫描步骤 | §8 |
| 建立条目与验证清单 | §9 |
| 分引擎章节（Unity Mono 已跑通） | §10 |
| 踩坑速查（实测） | §11 |
| 真实案例复盘（VariableF.currentSAN） | §12 |
