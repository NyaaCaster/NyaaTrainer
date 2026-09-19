# CE 稳定地址：把浮动地址固化成"重启后仍然有效"的修改项

> **要解决的问题**：游戏数值的地址是**运行时地址**（如 `1AFE3EABEF8`），重启游戏或读档后就会失效——
> 存在 CE 地址列表里的条目变成野地址。本文档汇总"把它固化成稳定条目"的各种方法。
>
> **相关的两份文档**：通道与工具用法见 `docs/04-ce-bridge.md`；数据结构侦察见 `docs/01-mono-recon.md`。
> **配套 skill**：`skills/ce-stable-address` —— 只放决策表与流程，细节在本文件。

- 环境：Cheat Engine 7.x @ `<CE_DIR>`（路径见 `config.yaml`；经 PowerShell 通道远程驱动，跨会话可用）
- **配套脚本**：`<CE_DIR>\dsh_stable.lua`（源文件在 `lua/dsh_stable.lua`）—— Mono 静态字段稳定条目的**框架 + 反查工具**
  （`resolve` / `installAll` / `installWithRetry` / `enableAuto` / `identify` / `identifyReport`）
- 建立：2026-09-18；**每一条都标注了验证状态**（✅ 实测 / ⚠️ 待验证 / ❌ 实测不可用）

---

## 0. 稳定条目的三种形态

| 形态 | 表达式示例 | 稳定性来源 | 适用 |
|---|---|---|---|
| **模块基址 + 全静态偏移链** | `[[[Pandora.exe+1A2B3C]+14]+8]` | 模块加载基址（ASLR 由 CE 自动重算）+ 编译期常量偏移 | 原生 C/C++、Go、Rust；Mono/IL2CPP 的非托管数据 |
| **引擎字段引用** | Mono：类静态字段 `类.static_data + 字段offset`（运行时解析）；实例字段 `对象 + offset` | 引擎对象模型：**类名与字段偏移恒定**，绝对地址运行时重算 | Unity(Mono)、经引擎管理的状态 —— **本次实测走通的就是这条** |
| **AOB 特征码定位** | `aobscanmodule(...,Game.exe,特征字节)` → 再按结构偏移取字段 | 代码/数据字节特征不随重启变化 | 特征稳定的结构体、被指令直接引用的数据 |

**判断顺序**：先看引擎（能不能用字段引用）→ 不行就追指针链（断点最快）→ 再不行用 AOB 特征。

---

## 1. 总流程（7 步）

```
①通道就绪 → ②定位当前值(两次筛选) → ③判断引擎 → ④选方法追根 → ⑤建立条目 → ⑥重启验证 → ⑦回写本文档
```

| 步 | 动作 | 产出 |
|---|---|---|
| ① | CE 在跑、桥可用、已附加目标进程 | 能远程执行 Lua |
| ② | 两次筛选法定出**当前**的地址 T | T（如 `1AFE3EABEF8`） |
| ③ | 枚举模块判断引擎，决定走哪条路 | 方法 A/B/C/D |
| ④ | 追出"基址+偏移"或"字段引用" | 候选链（可能多条） |
| ⑤ | 写入 CE 地址列表为稳定条目 | MemoryRecord |
| ⑥ | **重启游戏/读档**，重新解析，检查条目是否仍正确 | 唯一链（淘汰错的） |
| ⑦ | 把引擎相关的经验补进第 10 节 | 文档 |

> ⚠️ **第 ⑥ 步不可省**：任何"看起来对"的链都必须经过一次重启/读档验证。这是 CE 指针扫描的标准环节，也是唯一能排除巧合的办法。

---

## 2. 通道（本机，详见 `docs/04-ce-bridge.md`）

```powershell
$ce = '<CE_DIR>'
# 任意 Lua（含多行）——首选
& "$ce\ce-lua.ps1" -Code "return 6*7"
# 从文件执行（脚本较长时更稳）
& "$ce\ce-lua.ps1" -File "$ce\myscript.lua"
# 8 个成品工具，无 Python 依赖
& "$ce\ce-mcp.ps1" -Tool read_memory -Addr 0x1AFE3EABEF8 -Type 4
```

> ⚠️ 用 PowerShell here-string 传 `-Code` 时，**赋值变量名与引用变量名必须一致**
> （踩过一次：`$lua = @'…'@` 却写成 `-Code $arm` → 报"请用 -Code 或 -File 提供 Lua 代码"）。

**跨会话（✅ 实测）**：DSH 跑在 Session 0，CE 在用户桌面会话，`ce-lua.ps1` 直接连上用户的 CE 并执行 Lua；
`openProcess(getProcessIDFromProcessName('Pandora.exe'))` 正常附加。

常用 Lua 片段（本机实测可用）：

```lua
-- 附加
openProcess(getProcessIDFromProcessName('Pandora.exe'))
-- 枚举模块（返回普通表，元素 {Name, Address, Size, PathToFile, Is64Bit}）
local mods = enumModules()
for k, m in pairs(mods) do if m.Name == 'Pandora.exe' then return m.Address, m.Size end end
-- 读写
readInteger(addr) / writeInteger(addr, 50) / readFloat(addr) / readQword(addr)
-- 扫描器
local ms = createMemScan(); ms.VariableType = vtDword; ms.ScanOption = soExactValue
ms.Scanvalue = '89'; ms.ScanWritable = scanInclude
ms.scan(); ms.waitTillDone(); local n = ms.FoundCount
local fl = createFoundList(ms); fl.initialize(); local a0 = fl.Address[0]   -- 0 基
fl.deinitialize(); ms.destroy()
-- 限制内存类型（追指针时**必须**带 MEM_MAPPED，否则漏指针）
setSpecialScanOptionsOverride({MEM_PRIVATE=true, MEM_IMAGE=false, MEM_MAPPED=true})
-- 反汇编
disassemble(addr) -- 单条；配 getInstructionSize(addr) 逐条前进
```

---

## 3. 定位当前值：两次筛选法（核心方法论，跨引擎通用）

**不要**用"值看起来像什么"的模式去猜（下面踩坑表里第一次翻车就是这么来的）。可靠做法：

1. **初扫**：对若干**假设表示**分别扫描并**保留 memscan 对象**（存进全局表），例如界面值 89%：
   `float 0.89`｜`float 89`｜`double 89`｜`dword 89`｜`dword 890`｜`dword 8900`
2. **让玩家改变该数值**（或让它自然变化），记录界面新值
3. 对每组执行 `ScanOption = soChanged` 的 **next scan**（只保留"值变了"的地址）
4. 再筛一次"当前值 == 满值/新值对应值"（`1.0`/`100`/`1000`/`10000`）→ 通常收敛到个位数
5. **写入测试**（写一个明显不同的值）→ 让玩家看界面确认 → 命中

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

---

## 4. 判断引擎（决定走哪条路）

```lua
local mods = enumModules()
for k, m in pairs(mods) do
  local n = tostring(m.Name)
  if n:find('mono') or n:find('GameAssembly') or n:find('UnityPlayer')
     or n:find('godot') or n:find('Electron') or n:find('python') or n:find('RGSS') then
    print(n, string.format('0x%X', m.Address), m.Size)
  end
end
```

| 模块特征 | 引擎 | 首选方法 |
|---|---|---|
| `mono-2.0-*.dll` | Unity（**Mono** 后端） | **方法 C（Mono 静态字段 + `dsh_stable.identify` 反查）** ← 本机实测跑通的最优路径 |
| `GameAssembly.dll` + `il2cpp` | Unity（**IL2CPP** 后端） | 方法 A（断点）→ 结构体偏移；CE 的 IL2CPP 支持 |
| `godot*.exe` 单文件 / `*.pck` | Godot（原生 GDScript→字节码，无托管层） | 方法 A/B（断点 / 指针链） |
| `electron`/`node`/`.asar` | TyranoScript、NW.js 系 RPGMaker | V8 堆对象→指针链；方法 A/B |
| `python*.dll` / `*.rpa` | Ren'Py | PyObject 布局 → 指针对（`PyLong` 等）；方法 A/B |
| `RGSS*.dll`（Ruby） | RPGMaker XP/VX/VX Ace | Ruby 对象 → 方法 A/B |
| 无上述特征 | 原生 C/C++、自研 | **方法 A（断点）→ 方法 B（指针搜索）** |

---

## 5. 方法 A：写/访问/执行断点（**最直接**，能一次给出基址+偏移）

**原理**：在目标地址设断点，等命中时看"用哪个基址寄存器 + 偏移"访问它 → 直接得到一层指针关系。

### 5.1 关键事实（✅ 实测）

| 事实 | 说明 |
|---|---|
| `debug_setBreakpoint(T, 4, bptWrite)` 会自动启用调试器 | 调用前 `debug_canBreak()=false`，调用后为 **true**，返回 `true` |
| **CE 自己的 `writeInteger` 不触发断点** | 它走 `WriteProcessMemory`，不经过目标的执行流 → **必须让游戏自己写**（玩家操作或数值自然变化） |
| **数据断点报告的 RIP 是「访问指令的下一条」** | x86 数据断点属 **trap 语义**，命中时该指令**已经执行完**，RIP 指向下一条。实测命中 `RIP=1AFE3F115DD`（内容是 `xor eax,eax`），真正的访问指令是 **`RIP-3`** 的 `movsxd rsi,[rsi]`。**别把 XOR/NOP 当成访问指令** |
| 用 `getInstructionSize` 反推访问指令 | 从 `RIP` 往前退，直到某个地址 `A` 满足 `A + getInstructionSize(A) == RIP`，该条就是访问指令 |
| 回调里能拿到寄存器全局变量 | `RAX/RBX/.../RIP`（CE 在命中时填充） |
| 回调必须立即继续，否则游戏卡住 | `debug_continueFromBreakpoint(co_run)` 然后 `return 1` |
| 断点列表 | `debug_getBreakpointList()` 返回 `{地址, …}`；`debug_removeBreakpoint(addr)` 卸 |

### 5.2 完整代码（✅ 已装载通过）

```lua
local T = getAddressSafe('1AFE3EABEF8')
_G.dsh_bp_hits, _G.dsh_bp_count = {}, 0

function debugger_onBreakpoint()
  _G.dsh_bp_count = _G.dsh_bp_count + 1
  local target = getAddressSafe('1AFE3EABEF8')
  local regs = { RAX=RAX, RBX=RBX, RCX=RCX, RDX=RDX, RSI=RSI, RDI=RDI, RBP=RBP, RSP=RSP,
                 R8=R8, R9=R9, R10=R10, R11=R11, R12=R12, R13=R13, R14=R14, R15=R15 }
  local close = {}
  for name, val in pairs(regs) do                       -- 找"接近目标地址"的寄存器
    if val and val > 0x1000 then
      local d = target - val
      if d >= -0x10000 and d <= 0x10000 then
        close[#close + 1] = string.format('%s=0x%X(off %+d)', name, val, d)
      end
    end
  end
  local rip = 0
  pcall(function() rip = RIP end)
  table.insert(_G.dsh_bp_hits, { rip = rip, close = close, n = _G.dsh_bp_count })
  if _G.dsh_bp_count >= 300 then pcall(function() debug_removeBreakpoint(target) end) end
  pcall(function() debug_continueFromBreakpoint(co_run) end)
  return 1
end

debug_setBreakpoint(T, 4, bptWrite)     -- 装断点
-- …让游戏写一次… 然后读 _G.dsh_bp_hits 看 RIP 与接近的寄存器
```

### 5.3 拿到一层后怎么继续

- 若命中的是 `mov [RCX+0x2C], eax` 这类 → 基址 = `RCX`，偏移 = `0x2C`。
- **继续向上**：
  - 对 `RCX`（对象起始或中间层）**再设一次写/访问断点**，或
  - 对 `RCX` 做**方法 B 的指针搜索**（找"值指向 RCX 附近"的静态指针），或
  - 若引擎是 Unity/IL2CPP → 直接 **方法 C** 拿字段。
- 直到链顶落在**模块静态区**（`模块基址 + 固定偏移`）→ 完成。

### 5.4 读断点与执行断点：不必等玩家操作（✅ 本次关键突破）

写断点要求"游戏写这个值"——玩家不动就没命中。两个更主动的替代：

| 断点 | 装法 | 为什么有用 |
|---|---|---|
| **读断点（bptAccess）** | `debug_setBreakpoint(T, 4, bptAccess)` | UI 每帧都会**读**该值来显示 → 几乎立刻命中，不用等玩家操作。命中后同样能拿到基址寄存器与调用点 |
| **执行断点（bptExecute）** | `debug_setBreakpoint(entryAddr, 1, bptExecute)` | 已知某访问函数的入口时，抓**调用者**：回调里读 `[RSP]` = 返回地址 → 反汇编该返回地址往前几十字节，就能看到调用点如何算出参数 |

```lua
-- 读断点：抓 3 次后自动卸掉，避免游戏卡顿
_G.dsh_bp_hits, _G.dsh_bp_count = {}, 0
_G.dsh_bp_target = T

function debugger_onBreakpoint()
  pcall(function()
    _G.dsh_bp_count = _G.dsh_bp_count + 1
    local rbp, rsp = _G.RBP or 0, _G.RSP or 0
    local ret = '?'
    local ok, v = pcall(function() return readPointer(rbp + 8) end)   -- 调用者返回地址
    if ok and type(v) == 'number' then ret = string.format('%X', v) end
    if #_G.dsh_bp_hits < 8 then
      _G.dsh_bp_hits[#_G.dsh_bp_hits + 1] = string.format('RIP=%X ret=%s RBP=%X RSP=%X RCX=%X RBX=%X',
        _G.RIP, ret, rbp, rsp, _G.RCX or 0, _G.RBX or 0)
    end
    if _G.dsh_bp_count >= 3 then pcall(function() debug_removeBreakpoint(_G.dsh_bp_target) end) end
  end)
  debug_continueFromBreakpoint(co_run)
  return 1
end

debug_setBreakpoint(T, 4, bptAccess)
```

> ⚠️ 命中次数一定要设上限（本例 3 次）并在回调里自动卸断点：读断点会被每帧触发，
> 不设上限会让游戏明显卡顿。
>
> 💡 **断点命中时还能顺便证明"命中的就是真值"**：读断点命中那一刻 `RSI=0x3C`(=60)，
> 正是该地址当时的值 → 反证命中的确实是 SAN 的读取路径。

---

## 6. 方法 B：自研多级指针搜索（纯内存扫描，跨引擎通用）

**原理**：`T ← [A1] ← [A2] ← … ← [An]`，其中 `An` 是静态地址。逐级向上找"存有指向下层地址的指针"的存储位置。

### 6.1 两种搜索方式（✅ 实测对比）

| 方式 | 命令 | 结论 |
|---|---|---|
| `AOBScan(8 字节模式)` | `AOBScan('F8 BE EA E3 AF 01 00 00')` | ✅ 快速、精确；适合"精确值" |
| `MemScan soExactValue + vtQword` | 见下 | ✅ **与 AOBScan 结果完全一致（14/14，0 差异）**，且支持范围限制 |

```lua
-- 精确找"值 == target"的存储位置
local function scanExact(target, useModuleRange, modBase, modSize)
  local ms = createMemScan()
  ms.VariableType   = vtQword
  ms.ScanOption     = soExactValue
  ms.Scanvalue      = tostring(target)
  ms.ScanWritable   = scanInclude
  if useModuleRange then ms.Startaddress = modBase; ms.Stopaddress = modBase + modSize end
  ms.scan(); ms.waitTillDone()
  local fl = createFoundList(ms); fl.initialize()
  local res = {}
  for i = 0, math.min(fl.Count - 1, 400) do res[#res + 1] = fl.Address[i] end
  fl.deinitialize(); ms.destroy()
  return res
end
```

### 6.2 关键优化：每级先只扫模块静态区

`Pandora.exe` 只有 688 KB → 遍历它的数据段找"指向 T 附近"的 qword **几乎瞬间完成**：

```lua
-- 直接遍历模块静态段（比扫描器更直接、更快）
for off = 0, modSize - 8, 8 do
  local v = readQword(modBase + off)
  if v and v >= 0x1000000000 and v < 0x800000000000 then
    local d = v - T
    if d >= -0x100000 and d <= 0x100000 then  -- 命中：这附近有指针指向 SAN
      -- 记录 模块+off -> v（相对 T 的偏移 d）
    end
  end
end
```

### 6.3 实测结论与局限

- ❌ **`soValueBetween` 的 `Scanvalue1/Scanvalue2` 在本机不生效**：设范围 `[0x1A00000000,0x1C00000000)` 却扫出 174 万个横跨整个 64 位的随机值。**要按范围找指针，请用 AOBScan 的"高字节通配模式 + Lua 过滤"**（`?? ?? ?? ?? AF 01 00 00` 匹配高 4 字节 = `0x000001AF`）。
- ❌ **Mono 游戏在 PE 静态段找不到链顶**：实测 `Pandora.exe` 静态段 86016 个 qword 里**没有一个**指向 SAN 附近。原因见 7.2 —— Mono 静态字段在**运行时分配的 static_data 区**，根本不在 PE 数据段。**这类游戏直接走方法 C，不要浪费时间做指针扫描。**
- ✅ 堆内指针很多（实测一次收集到 17 万~174 万个 qword），逐级 BFS 时务必限制分支数与层数，并优先检查"模块内命中"。

---

## 7. 方法 C：Mono / IL2CPP 字段（Unity 系首选）

CE 自带 Mono 接口（`<CE_DIR>\autorun\monoscript.lua`，204 KB），但 **CE 7.x 不执行 autorun**，所以要手动加载：

```lua
dofile(getCheatEngineDir() .. 'autorun\\monoscript.lua')   -- ✅ 加载成功，mono_* 全部可用
LaunchMonoDataCollector()                                  -- ✅ 注入收集器
-- 之后 mono_AttachedProcess = 目标 pid（实测 21660）
```

### 7.1 先分清：静态字段 vs 实例字段

| 类型 | 访问形态 | 定位方式 |
|---|---|---|
| **静态字段** | JIT 把绝对地址**内联成 `mov reg, imm64`**（见 7.2） | `mono_class_getStaticFieldAddress` + 字段 offset —— **本机实测走通** |
| **实例字段** | `mov reg, [obj + 0xNN]`，`obj` 来自参数/数组/其他字段 | 先拿实例地址，再用 `mono_class_enumFields` 找 offset；实例可用 `mono_class_findInstancesOfClass` 枚举 |

### 7.2 决定性特征：`mov reg, imm64`（✅ 本次实测发现）

Mono 的 JIT 对**静态字段**做**绝对地址内联**，运行时机器码长这样：

```asm
1AFEBE2E53C: 48 B9 F8BEEAE3AF010000  mov rcx,000001AFE3EABEF8   ; ← 静态字段绝对地址，直接内联
1AFEBE2E550: 41 FF D3                 call r11
```

**只要在访问指令附近看到"把某个 `0x1A…` 绝对地址直接搬进寄存器"，基本可判定它是 Mono 静态字段。**
这也解释了"地址为什么会浮动"：`static_data` 由 Mono 运行时分配，每次启动都变；
但 **`类名 + 字段偏移` 恒定** —— 这正是我们要的稳定锚点。

### 7.3 反查：给地址 → 类名 + 字段名 + 偏移（✅ 实测 1.6~1.8 s）

`dsh_stable.lua` 的 `identify(addr)` 封装了这个过程（遍历全部约 1.3 万个类）：

```lua
dofile(getCheatEngineDir() .. 'dsh_stable.lua')
dsh_stable.identifyReport(0x1AFE3EABEF8)
-- 'VariableF' @ VariableF.currentSAN + 0x58  (base 1AFE3EABEA0)
--   S.define('currentSAN', 'VariableF', 'currentSAN', vtDword, 'currentSAN', 0x58)
```

手工版（理解原理用）：

```lua
local target = 0x1AFE3EABEF8
local domain = mono_enumDomains()[1]
for _, asm in ipairs(mono_enumAssemblies()) do
  local image = mono_getImageFromAssembly(asm)
  if image and image ~= 0 then
    for _, rec in ipairs(mono_image_enumClasses(image)) do   -- rec = {class=, classname=, namespace=}
      local base = mono_class_getStaticFieldAddress(domain, rec.class)
      if base and base <= target and (target - base) <= 0x2000 then
        local delta = target - base
        for _, f in ipairs(mono_class_enumFields(rec.class) or {}) do
          if f.isStatic and f.offset == delta then
            print(rec.classname .. '.' .. f.name .. string.format(' + 0x%X', delta))
          end
        end
      end
    end
  end
end
```

### 7.4 解析与安装（`dsh_stable.lua`）

```lua
dofile(getCheatEngineDir() .. 'dsh_stable.lua')
dsh_stable.installAll()          -- 把已声明条目写进地址列表；返回 成功数, 失败列表
dsh_stable.report()              -- 打印条目 + 当前解析地址
dsh_stable.installWithRetry()    -- 轮询等 Mono 附加完成后再装（重启后省心）
dsh_stable.enableAuto()          -- 包装 MainForm.OnProcessOpened，开进程后自动装
```

### 7.5 API 与踩坑（全部实测）

| 事实 | 说明 |
|---|---|
| `mono_image_enumClasses(image)` 返回 **table** | 元素 `{class=<指针>, classname=…, namespace=…}`；直接把元素丢给 `mono_class_getName` 只会拿到空串 |
| `mono_class_getStaticFieldAddress(domain, class)` | 返回该类的 **static_data 基址**；`0`/`nil` = 该类无静态数据 |
| `mono_class_enumFields(class)` | 字段表，元素含 `name` / `offset` / `isStatic` / `isConst` / `monotype` / `altname` |
| 静态字段布局 | **引用类型字段占 8 字节槽，值类型字段按 4 字节紧排** —— 所以"名字像计数器"的字段也可能落在 0x00/0x08/0x10…，别按名字猜类型 |
| `mono_object_getClass(T)` | 只接受**对象起始地址**；对字段地址返回 `nil` |
| `mono_findClass('', 'ClassName')` | 按类名找类；有命名空间时用 `mono_findClass('Ns', 'Class')` |
| `MainForm.OnProcessOpened` | **已被 `monoscript.lua` 占用**（line 7253-7254 保存旧值后替换）用于自动附加 Mono → 只能**包装**、不能覆盖 |
| 全类扫描成本 | 约 1.3 万个类遍历一遍 ≈ **1.8 s** → 反查完全实用 |
| CE 的 Timer | `createTimer(owner, enabled)` 返回持久 timer，有 `Interval` / `Enabled` / `OnTimer`；`createTimer(delay, fn)` 是一次性（执行后自毁） |

> ⚠️ 注入 `MonoDataCollector64.dll`（CE 目录内 738 KB）会让 CE 出现 Mono 菜单项；单机游戏通常无碍，
> 但对有反作弊/反调试的游戏要谨慎。

---

## 8. 方法 D：CE GUI 指针扫描（人工兜底，最通用的"笨办法"）

当自动化方法都不收敛时，用 CE 自带指针扫描（在**用户的 CE 界面**操作）：

1. 在地址列表里右键该地址 → **Pointer scan for this address**
2. 参数：`Max level = 4~6`、`Max offset = 4096`、勾选 "Only find paths with a static address"
3. 扫描完成后**保存结果**（`.PTR`）
4. **重启游戏/读档**，重新定位该数值（回到第 3 节两次筛选法）
5. 在 Pointer scanner 窗口里用 `Pointer scanner → Rescan memory`，把新地址填进去 → **过滤**
6. 剩下的通常就是唯一链 → 双击加入地址列表 → 再重启一次确认

> 我在 Lua 侧**找不到**指针扫描 API（`celua.txt` 里 `pointerscan` 零匹配），所以这一步必须在 GUI 里做。

---

## 9. 建立条目与验证

### 9.1 MemoryRecord 属性

```lua
local al = getAddressList()
local mr = al.createMemoryRecord()
mr.Address     = '[[[Pandora.exe+1A2B3C]+14]+8]'   -- 指针表达式
mr.Type        = vtDword
mr.Description = 'SAN'                             -- ⚠️ 用 ASCII：中文描述会让 string.find 匹配不上
```

- **删除**记录只能用 **`memoryrecord:delete()`**（对象自删）——`AddressList` 上**没有** `removeRecord`/`deleteRecord`/`delete`（调 nil 会被 `pcall` 静默吞掉，看起来"成功"实则没删）。
- 清空列表：`for i = al.Count - 1, 0, -1 do local mr = al.getMemoryRecord(i); mr:delete() end`

> **Mono 静态字段无法写成指针表达式**（运行时才知道地址），所以它的"条目"是
> **声明（类名+字段名）+ 一段解析脚本**，见 7.3/7.4 与第 12 节。

### 9.2 验证清单（照着做，别跳）

| 检查 | 方法 |
|---|---|
| 条目能否解析出当前值 | 读 `mr.Value`，与界面数值对得上 |
| 数值改变后条目跟随 | 让游戏改数值 → 条目值同步变化 |
| **重启/读档后仍正确** | 重启游戏 → 重新解析 → 条目值仍等于界面值 ← **决定性** |
| 写入生效且可回读 | 写一个明显值 → 回读 → 让玩家看界面 |

---

## 10. 分引擎章节

> 原则：**只写真实做过的**。没有实测的引擎先留占位，等真实项目遇到时补（不做纸上推演）。

### 10.1 Unity（Mono 后端）— ✅ 已跑通（静态字段路径）

- **识别**：模块里有 `mono-2.0-bdwgc.dll`（+ `UnityPlayer.dll`）；CE 里 `mono_isil2cpp` 不存在 = 不是 IL2CPP
- **案例**：`<GAMES_DIR>\2026-6\パンドラメイズ260427\Pandora.exe` → `VariableF` 类的 8 个静态字段

**已跑通的方法（推荐顺序）**

1. 两次筛选法定出当前地址 T（`1AFE3EABEF8`，dword 百分比）
2. **读断点**抓访问指令（比写断点省事：UI 每帧读，不必等玩家操作）
3. 反汇编命中处，看到 `mov rcx, <绝对地址>` → **判定为 Mono 静态字段**
4. `dsh_stable.identify(T)` 反查 → `VariableF.currentSAN + 0x58`
5. `dsh_stable.define` + `installAll` → 地址列表出现稳定条目，写入生效
6. 重启后重跑 `installAll()`（或 `enableAuto` 自动重建）——
   ⚠️ 游戏重启会让 **Mono 采集器掉线**（`mono_AttachedProcess = nil`），必须先 `LaunchMonoDataCollector()` 并等约 5 秒

**实测数据（✅）**

| 项 | 值 |
|---|---|
| static_data 基址 | `1AFE3EABEA0` |
| `currentSAN` offset | `0x58` |
| 解析结果 | `1AFE3EABEF8` == CE 中找到的 SAN 地址 ✅ |
| `identify` 命中 | 1 个类（共扫 13495 个），耗时 1.61~1.83 s |
| `installAll` | 8/8 成功 |
| 写入回读 | 60 → 写 50 → 读回 50 → 恢复 60 ✅ |
| **重启验证** | ✅ static_data `1AFE3EABEA0` → `2DB5D13BEA0`（变址），offset `+0x58`（不变），读到 84 与界面一致 |

**不要走的弯路（均实测失败）**

- ❌ 在 PE 静态段找指针（Mono 静态数据不在 PE 数据段）
- ❌ 对字段地址调 `mono_object_getClass`（返回 nil）
- ❌ 二级指针链（托管对象在 GC 堆，逐级 BFS 到不了根）

**待补**：实例字段路径（`mono_class_findInstancesOfClass` 枚举实例 → 字段 offset）。

### 10.2 Unity（IL2CPP）— ⏳ 待实测
### 10.3 Godot — ⏳ 待实测
### 10.4 TyranoScript / Electron(V8) — ⏳ 待实测
### 10.5 Ren'Py（Python）— ⏳ 待实测
### 10.6 RPGMaker（RGSS / NW.js）— ⏳ 待实测
### 10.7 原生 C/C++ — ⏳ 待实测

---

## 11. 踩坑速查（全部为实测）

| 坑 | 现象 | 正解 |
|---|---|---|
| **把数据断点命中处的 RIP 当成访问指令** | 命中 `RIP=1AFE3F115DD`，反汇编出来是 `xor eax,eax` —— 看起来"没访问任何东西" | 数据断点是 **trap 语义**：RIP 已指向**下一条**。真正的访问指令是 **`RIP-3`** 的 `movsxd rsi,[rsi]`；用 `getInstructionSize` 往前反推 |
| **把 `mono_image_enumClasses` 的元素当裸类指针** | `mono_class_getName(元素)` / `getStaticFieldAddress` 返回空或 nil | 元素是 table：取 `rec.class` / `rec.classname` / `rec.namespace` |
| **覆盖 `MainForm.OnProcessOpened`** | CE 的"自动附加 Mono"失效 | 先保存旧值再包装（`monoscript.lua` 自己就是这么做的） |
| **对 Mono 游戏做 PE 静态段指针搜索** | 86016 个 qword 里 0 命中，白费功夫 | Mono 静态字段在运行时分配的 static_data 区 → 直接走方法 C |
| 用"0~1 浮点紧跟 1.0"当 SAN 特征 | 筛出的"副本"值全是 `0.839216` = **214/255 颜色分量**；`nvwgf2umx.dll`（NVIDIA 驱动）里同样模式命中 5 次 | 不要模式猜测；用两次筛选法 |
| 忽略"副本必须一致" | 第二轮 6 个候选值各异（0.887~0.893，UI/渲染近似值） | 真值的多份副本应**完全一致**，不一致即排除 |
| 只扫 `MEM_PRIVATE` | 指向目标的指针**全部漏掉**（它们在 `MEM_MAPPED`） | 追指针时用 `{MEM_PRIVATE=true, MEM_IMAGE=false, MEM_MAPPED=true}` |
| 用 `soValueBetween` 限定范围 | 参数不生效，扫出 174 万全范围随机值 | 改用 `soExactValue`，或 AOBScan 高字节通配 + Lua 过滤 |
| 用 `getNameFromAddress()` 判断"是否在模块内" | 对堆地址返回地址字符串本身 → 判定全错 | 用 `enumModules()` 拿模块 `Address/Size`，自己比较区间 |
| 删除地址列表记录 | `AddressList` 上无删除方法，`pcall` 静默失败 | `memoryrecord:delete()` |
| CE 记录描述用中文 | `string.find(desc,'SAN候选')` 匹配不上 | 记录名/匹配关键字**一律 ASCII** |
| Lua `string.format` 里裸写 `%` | `invalid option '%~'` / `bad argument #6 to 'format'` | 字面百分号写 `%%`，或不用 format |
| 想让 CE 自己写触发断点 | 命中 0 次 | CE 用 `WriteProcessMemory`，不经过目标执行流；**必须让游戏自己写** |
| 读断点不设命中上限 | 游戏每帧读 → 频繁中断 → 卡顿 | 回调里计数，抓够 N 次就 `debug_removeBreakpoint` |
| PowerShell here-string 传 Lua | `-Code $arm` 报"请用 -Code 或 -File 提供 Lua 代码" | 赋值与引用**变量名要一致**（`$lua = @'…'@` 配 `-Code $lua`） |
| 非对齐命中 | `dword 8900` 剩余候选值很怪（`4213047228`/`0`），地址尾数非 4 的倍数 | 按类型对齐扫描/过滤 |
| `enumModules()` 当对象用 | `mods.Count` 报 `attempt to perform arithmetic on a nil value` | 它是**普通表**（`pairs` 遍历，元素 `{Name,Address,Size,...}`） |

---

## 12. 案例复盘：`パンドラメイズ260427` 的 SAN（✅ 已跑通）

- 目标：`<GAMES_DIR>\2026-6\パンドラメイズ260427\Pandora.exe`（Unity **Mono**，pid 21660，用户桌面会话）
- 通道：DSH(Session 0) → `ce-lua.ps1` → 用户会话 CE（✅ 跨会话成功）

### ① 定位当前值

- 界面 SAN 84% → 两次筛选（84% → 89% → 100%）→ 命中 `1AFE3EABEF8`（**dword 百分比**，不是 0~1 浮点）
- 写入 50 → 玩家确认界面变 50% ✅
- 周围结构：`100, 100, 100, [SAN], 30, 0, 23, 1, 54, 5512`

### ② 常规追根全部失败

- ❌ 二级指针链就断（托管对象在 GC 堆，上层没有静态指针）
- ❌ PE 静态段 86016 个 qword 里没有一个指向 SAN 附近
- ❌ `mono_object_getClass(SAN)` 返回 nil（不是对象起始）

### ③ 断点突破（关键）

- 数据断点命中后 **RIP 指向访问指令的下一条**（trap 语义）
  - 读断点命中 `RIP=1AFE3F115DD` → 真正的访问指令是 `RIP-3`：`movsxd rsi,dword ptr [rsi]`
  - 命中那一刻 `RSI=0x3C`(=60) = SAN 的值 → 反证命中正确
- 从 `[RBP+8]` 取到调用者返回地址 `1AFEBE2E553` → 反汇编调用点：

```asm
1AFEBE2E53C: 48 B9 F8BEEAE3AF010000  mov rcx,000001AFE3EABEF8   ; ← SAN 绝对地址被内联！静态字段的铁证
1AFEBE2E550: 41 FF D3                 call r11
1AFEBE2E553: 48 8B C8                 mov rcx,rax
```

- 同一方法里前面还有一串同样形态：`mov rax,000001AFE3EABEA8` / `…EB8` / `…EC0` / `…EB0`
  → `1AFE3EABEA0~EF8` 是**同一个类的 static_data 块**

### ④ 反查类与字段

- 遍历 13495 个类，`mono_class_getStaticFieldAddress` 落在 SAN 附近的**只有 1 个**：
  `staticData=1AFE3EABEA0  delta=58  .VariableF`（耗时 1.83 s）
- `mono_class_enumFields('VariableF')` → 51 个静态字段，`currentSAN` 的 offset = **88 = 0x58** ✅ 与 delta 精确吻合
- 相邻字段一并解释清楚了那片内存：

| offset | 字段 | 实测值 |
|---|---|---|
| 0x48 | currentEquipNum | 0 |
| 0x4C | **currentHP** | 100 |
| 0x50 | **maxHP** | 100 |
| 0x54 | **currentMP** | 100 |
| **0x58** | **currentSAN** | **60** |
| 0x5C | currentINRAN | 30 |
| 0x60 | heroinInran | 0 |
| 0x64 | tutorialPhase | 23 |
| 0x68 | isDiffEasy | 1 |
| 0x6C | battleTime | 54 |
| 0x70 | currentStep | 5512 |

> 字段名前 9 个（`bukkakeNum` … `equipID`）占 **8 字节槽**（引用类型），
> 所以真正是 int 的字段从 0x48 才开始 —— 这正是"SAN 为什么在 0x58 而不是 0x0C"的原因。

### ⑤ 建立稳定条目（✅ 已验证）

- `dsh_stable.lua` 声明 8 个条目：SAN / HP / MaxHP / MP / INRAN / Heroin / EroPower / RestNum
- `installAll()` → 8/8 成功，地址列表出现 8 条，值全部与内存 dump 吻合
- 写入测试：SAN 60 → 写 50 → 读回 50 → 恢复 60 ✅
- 解析链：`mono_findClass('','VariableF')` → `mono_class_getStaticFieldAddress` → `+0x58`
- 反查链：`dsh_stable.identifyReport(0x1AFE3EABEF8)` → 自动生成 `S.define` 行 ✅

### ⑥ 重启验证（✅ 已通过，2026-09-18）

关掉 `Pandora.exe` 重新启动（新 pid `12644`），CE 重新附加 + `LaunchMonoDataCollector()`，再跑 `installAll()`：

| | 重启前 | 重启后 |
|---|---|---|
| static_data 基址 | `1AFE3EABEA0` | `2DB5D13BEA0` ← **变了** |
| SAN 绝对地址 | `1AFE3EABEF8` | `2DB5D13BEF8` ← **变了** |
| `currentSAN` 偏移 | `+0x58` | `+0x58` ← **一字节不差** |
| 读到的值 | 60 | **84**（与界面 84% 一致 ✅） |

**结论**：地址整体搬迁、偏移恒定 → `类名 + 字段偏移` 确实是稳定锚点。
`installAll()` 8/8 成功刷新，地址列表条目全部指向新地址（SAN=84、HP=MP=maxHP=100、INRAN=30、Heroin=0、RestNum=12）。

**重启后再次写入验证（✅ 端到端闭环，2026-09-18）**：对**重新解析出来的新地址**写 `92`
→ 回读 `92` → **用户确认游戏界面 SAN 变成 92%**。
说明该稳定条目在重启后依然可直接读写 —— 本方法的完整目标（找到 → 固化 → 重启后仍可改）达成。

---

## 13. 打包成独立修改器

把地址列表里的修改项做成**双击即用、不依赖已安装 CE** 的程序（可带小面板 UI）。
完整方案已独立成文 —— **`docs/03-standalone-trainer.md`**（格式逆向、`make_trainer.py` 用法、
面板 API 与 DPI 实测坑、验证与交付清单）。

一句话要点：

- ❌ `saveTable('x.exe')` **不产出文件**（只把 GUI 向导叫起来，返回 `false`）→ 自动化必须自己合成
- trainer exe = `standalonephase1.dat`(解压 stub) + PE 资源 `ARCHIVE` + `DECOMPRESSOR`；
  模板 `.cepack` = `"CEPACK" + [大小:4] + raw-deflate`
- **Mono 支持要额外打包** `win64\dbghelp.dll` / `symsrv.dll` / `dbgshim.dll`
  以及 `autorun\` 下的 4 个 Mono 文件（否则报 `Library Injection failed or invalid module`）
- 表脚本（`<LuaScript>`）里**不能有裸 `<` 或 `&`** —— `.CT` 是 XML，否则脚本静默不执行
- 本机生成器：`<CE_DIR>\make_trainer.py`
