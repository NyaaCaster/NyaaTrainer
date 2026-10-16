# 从手动搜索地址到稳定指针链：计算固化方法

> **本文解决什么**：用户已经在 CE 里**手动搜索到了数值地址**（通过精确值搜索、未知初始值等常规手段），
> 但这些地址是**裸绝对地址**，游戏重启后就失效。本文给出**利用这些已知地址快速计算出稳定指针链**的方法，
> 无需从零开始侦察，显著节省固化时间。
>
> **适用场景**：
> - ✅ 用户已通过 CE 手动搜索到一个或多个数值地址
> - ✅ 游戏重启后地址变化，需要固化成"重启后仍有效"的指针链
> - ✅ 不想从头跑完整的断点追踪流程（方法 02）
> - ✅ 多个数值地址间距规律（很可能在同一结构体内）
>
> **核心思想**：用户重启游戏并**只重新搜索一个地址**，通过"重启前后地址变化"反推结构体基址偏移，
> 再用断点追踪快速找出指针链。比完整侦察流程快 3-5 倍。
>
> **方法来源**：Yakuzarogue（Unity IL2CPP）实战（2026-10-17），5 个数值从裸地址固化为三级指针链，
> 用户只重搜了一个"钱"的地址，其余 4 个通过计算直接得出。
>
> **配套文档**：`02-stable-address.md`（完整断点追踪方法）、`01-mono-recon.md`（Unity Mono 专用路径）。
>
> 建立：2026-10-17。

---

## 0. 方法概览：三阶段流程

```
用户手动搜索（第一次运行）
  ├─ 搜到 N 个数值地址（裸绝对地址）
  └─ 观察地址间距 → 判断是否在同一结构体
          ↓
重启游戏 + 单点重搜（第二次运行）
  ├─ 只重新搜索 1 个地址（最容易搜的那个）
  ├─ 对比重启前后地址 → 计算结构体基址偏移
  └─ 推算其余 N-1 个地址的新位置
          ↓
断点追踪 + 指针链固化
  ├─ 对新地址设读断点 → 捕获访问指令
  ├─ 反汇编找出指针链（静态地址 + 多级偏移）
  └─ 创建 CE 指针条目 → 重启验证
```

**时间对比**（以 Yakuzarogue 为例）：
- **完整侦察**（从零开始）：每个地址独立追踪，5 个地址约 25-30 分钟
- **本方法**（利用已知地址）：3 个地址共用结构 + 单点重搜，总计约 8-10 分钟

---

## 1. 阶段① 初次搜索：观察地址模式

### 1.1 手动搜索数值

用户通过 CE 常规手段搜到了若干地址（示例：Yakuzarogue 五个数值）：

```
第一次运行（游戏启动后的地址）
─────────────────────────────────
钱     21A155CC4B4
HP     21A155CC4B8  ← 比"钱"高 0x4（4 字节）
体力   21A155CC4BC  ← 比"钱"高 0x8（8 字节）
考核   21A155CC540  ← 比"钱"高 0x8C（140 字节）
治安   21A155CC558  ← 比"钱"高 0xA4（164 字节）
```

### 1.2 判断结构体特征

**关键观察点**：

| 特征 | 判据 | 示例 |
|------|------|------|
| **地址连续且间距规律** | 相邻地址相差 4/8/16 字节（整数/浮点/指针的典型步长） | 钱→HP→体力 依次 +4 |
| **地址在同一内存页** | 高位字节相同（前 3-4 个十六进制位） | `21A155CC***` 全在同一页 |
| **数值类型相似** | 都是整数、都是浮点、都是百分比 | 5 个都是 4 字节整数 |

**结论**：如果满足上述**任意两条**，这些数值**很可能在同一个结构体内**。

> **反例**：地址跨度很大（相差 MB 级）、类型不同（整数 + 字符串）、无规律分布 →
> 可能不在同一结构体，需要分别追踪。

### 1.3 选择"锚点地址"

从 N 个地址中选**最容易重新搜索**的那个作为"锚点"（第二次运行时只重搜它）：

**优先级**（从高到低）：
1. **数值变化频繁**：金钱（花钱就变）> HP（受伤就变）> 考核（需完成任务）
2. **初始值唯一**：起始金钱 1000 元（唯一）> HP 100/150/200（多个 NPC 可能同值）
3. **数值范围大**：金钱 0-999999 > 百分比 0-100

**示例**：5 个数值中选"钱"作为锚点（变化最频繁 + 数值唯一）。

---

## 2. 阶段② 重启 + 单点重搜：推算其余地址

### 2.1 重启游戏并重新搜索锚点

**步骤**：
1. 记录旧地址（第一次运行时的"钱" = `21A155CC4B4`）
2. **关闭游戏 + 重新启动**
3. **只搜索"钱"的当前值**（不搜其他 4 个）
4. 得到新地址（第二次运行时的"钱" = `1C8F2EED934`）

### 2.2 计算结构体基址偏移

**核心公式**：

```
结构体基址（旧）= 钱的旧地址 - 钱在结构体内的偏移
结构体基址（新）= 钱的新地址 - 钱在结构体内的偏移

其他字段新地址 = 结构体基址（新）+ 该字段在结构体内的偏移
```

**实例计算**（Yakuzarogue）：

```python
# 已知数据
money_old = 0x21A155CC4B4  # 旧地址
money_new = 0x1C8F2EED934  # 重启后新地址

# 从第一次运行观察到的偏移（地址最低字节）
offset_money = 0x34   # 钱在结构体内的偏移
offset_hp = 0x38
offset_stamina = 0x3C
offset_eval = 0xC0
offset_security = 0xD8

# 计算基址
base_old = money_old - offset_money  # = 0x21A155CC480
base_new = money_new - offset_money  # = 0x1C8F2EED900

# 推算其余 4 个字段的新地址
hp_new = base_new + offset_hp        # = 0x1C8F2EED938
stamina_new = base_new + offset_stamina  # = 0x1C8F2EED93C
eval_new = base_new + offset_eval    # = 0x1C8F2EED9C0
security_new = base_new + offset_security  # = 0x1C8F2EED9D8
```

### 2.3 验证推算结果

在 CE 中直接读取推算出的地址，确认数值正确：

```lua
-- CE Lua 验证脚本
local addrs = {
  {name = "钱",   addr = 0x1C8F2EED934, expect = 17090},
  {name = "HP",   addr = 0x1C8F2EED938, expect = 150},
  {name = "体力", addr = 0x1C8F2EED93C, expect = 240},
  {name = "考核", addr = 0x1C8F2EED9C0, expect = 70},
  {name = "治安", addr = 0x1C8F2EED9D8, expect = 55},
}

for _, a in ipairs(addrs) do
  local val = readInteger(a.addr)
  local status = (val == a.expect) and "✓" or "✗"
  print(string.format("%s %s: %d (期望 %d)", status, a.name, val, a.expect))
end
```

**通过判据**：所有字段读取成功 **且** 数值符合游戏当前状态。

---

## 3. 阶段③ 断点追踪：找出稳定指针链

现在我们有了**当前运行时的正确地址**，可以快速追踪指针链。

### 3.1 设置读断点（自动触发）

**为什么用读断点而不是写断点**：
- ❌ **写断点**：必须等玩家操作让游戏写入该值（花钱/受伤），可能要等很久
- ✅ **读断点**：UI 每帧都在读取显示值（刷新血条/金钱），**几乎立刻触发**

```lua
-- 对"钱"的新地址设读断点
local money_addr = 0x1C8F2EED934
debug_setBreakpoint(money_addr, 4, bptAccess)  -- bptAccess = 读断点

local hit_count = 0
local MAX_HITS = 5  -- 收集 5 次就够了

function debugger_onBreakpoint()
  hit_count = hit_count + 1
  
  -- 记录断点命中时的状态
  print(string.format("断点命中 #%d: RIP=%X", hit_count, RIP))
  
  -- 反汇编 RIP 附近的指令（数据断点的 RIP 是下一条指令）
  local start = RIP - 0x40
  for i = 1, 15 do
    local instr = disassemble(start)
    if instr then
      print(string.format("  %X: %s", start, instr))
      start = start + getInstructionSize(start)
    end
  end
  
  -- 收集够了就移除断点
  if hit_count >= MAX_HITS then
    debug_removeBreakpoint(money_addr)
    return 1  -- 停止调试
  end
  
  return 0  -- 继续执行
end
```

### 3.2 分析反汇编：识别指针链模式

**典型的三级指针访问模式**（Yakuzarogue 实例）：

```asm
7FFE84034FB1: mov rcx,[7FFE86DAB080]      ← ① 从静态地址读取指针
7FFE84034FB8: mov rax,[rcx+000000B8]      ← ② 第一次解引用 (+0xB8 偏移)
7FFE84034FBF: mov rdx,[rax+10]            ← ③ 第二次解引用 (+0x10 偏移)
7FFE84034FD2: cmp [rdx+34],eax            ← ④ 访问字段 (+0x34 偏移)
```

**识别步骤**：

| 步骤 | 指令特征 | 提取信息 |
|------|----------|----------|
| ① | `mov reg, [绝对地址]` | 静态指针地址（通常在 .dll 内） |
| ② | `mov reg, [reg+偏移]` | 第一级偏移 |
| ③ | `mov reg, [reg+偏移]` | 第二级偏移 |
| ④ | `访问 [reg+偏移]` | 字段偏移（已在阶段①观察到） |

### 3.3 计算模块相对偏移

**关键**：指针链必须**相对于模块基址**（`GameAssembly.dll+偏移`），而不是绝对地址，
否则 DLL 加载地址变化时指针链失效。

```lua
-- 获取 GameAssembly.dll 基址
local ga_base = nil
local modules = enumModules()
for i = 1, #modules do
  if modules[i].Name == "GameAssembly.dll" then
    ga_base = modules[i].Address
    break
  end
end

-- 计算相对偏移
local static_addr = 0x7FFE86DAB080  -- 从反汇编得到的绝对地址
local static_offset = static_addr - ga_base  -- = 0x32DB080

print(string.format("指针链: [[GameAssembly.dll+%X]+B8]+10", static_offset))
```

### 3.4 验证指针链

**手动验证**（确保每一级解引用都成功）：

```lua
local ga_base = 0x7FFE83AD0000  -- 当前运行时的基址
local static_offset = 0x32DB080
local offset_lv1 = 0xB8
local offset_lv2 = 0x10

-- 第一级
local ptr1 = readPointer(ga_base + static_offset)
print(string.format("第一级: [%X] = %X", ga_base + static_offset, ptr1))

-- 第二级
local ptr2 = readPointer(ptr1 + offset_lv1)
print(string.format("第二级: [%X+%X] = %X", ptr1, offset_lv1, ptr2))

-- 第三级（结构体基址）
local base = readPointer(ptr2 + offset_lv2)
print(string.format("第三级: [%X+%X] = %X", ptr2, offset_lv2, base))

-- 验证字段
local money = readInteger(base + 0x34)
print(string.format("钱 = [%X+34] = %d", base, money))
```

**通过判据**：所有解引用都返回**非零**地址，最终字段读取到正确数值。

---

## 4. 创建稳定 CE 表

### 4.1 XML 格式（手动编辑）

CE 的 `.CT` 文件是标准 XML，可以直接编辑：

```xml
<?xml version="1.0" encoding="utf-8"?>
<CheatTable CheatEngineTableVersion="52">
  <CheatEntries>
    <CheatEntry>
      <ID>0</ID>
      <Description>"钱"</Description>
      <VariableType>4 Bytes</VariableType>
      <Address>"GameAssembly.dll"+32DB080</Address>
      <Offsets>
        <Offset>34</Offset>   <!-- 字段偏移（最内层） -->
        <Offset>10</Offset>   <!-- 第三级偏移 -->
        <Offset>B8</Offset>   <!-- 第二级偏移 -->
      </Offsets>
    </CheatEntry>
    <!-- 其余 4 个字段同理，只改 Description 和第一个 Offset -->
  </CheatEntries>
</CheatTable>
```

**偏移顺序**：从**最内层到最外层**（字段 → 第三级 → 第二级），CE 会自动反向解析。

### 4.2 Lua 脚本生成（自动化）

```lua
function create_stable_table()
  local ga_base = getModuleBase("GameAssembly.dll")
  local static_offset = 0x32DB080
  
  local fields = {
    {name = "钱",   offset = 0x34},
    {name = "HP",   offset = 0x38},
    {name = "体力", offset = 0x3C},
    {name = "考核", offset = 0xC0},
    {name = "治安", offset = 0xD8},
  }
  
  local al = getAddressList()
  al.clear()
  
  for _, field in ipairs(fields) do
    local mr = al.createMemoryRecord()
    mr.Description = field.name
    mr.Type = vtDword
    mr.IsPointer = true
    mr.Address = string.format("GameAssembly.dll+%X", static_offset)
    
    -- 添加偏移链（从内到外）
    local offsets = mr.Offsets
    offsets.add(field.offset)  -- 字段偏移
    offsets.add(0x10)          -- 第三级
    offsets.add(0xB8)          -- 第二级
    
    mr.Active = true
  end
  
  getMainForm().saveTable("稳定表.CT")
end
```

---

## 5. 重启验证：最终确认

**流程**：
1. 加载新创建的 `.CT` 文件
2. **关闭游戏 + 重新启动**
3. 在 CE 中观察条目是否自动解析到新地址
4. 确认所有字段的**值都正确显示**

**成功判据**：
- ✅ 所有指针条目都显示绿色勾（表示地址解析成功）
- ✅ 显示的数值与游戏内一致
- ✅ 可以直接修改数值并立即生效

**失败排查**：

| 症状 | 可能原因 | 解决方法 |
|------|----------|----------|
| 指针显示 `???` | 某一级偏移错误 | 用 `02-stable-address.md` §9 验证每一级 |
| 数值错误 | 字段偏移错误 | 重新观察阶段①的地址间距 |
| 重启后仍失效 | 静态地址是绝对地址而非模块相对 | 确保用 `"模块名"+偏移` 而非裸地址 |

---

## 6. 方法优势与局限

### 6.1 优势

| 优势 | 说明 | 对比完整侦察 |
|------|------|--------------|
| **速度快** | 只需重搜 1 个地址，其余通过计算得出 | 快 3-5 倍 |
| **简单** | 不需要理解引擎内部结构 | 用户友好 |
| **适用广** | 只要是结构体存储的数据都适用 | 通用性强 |
| **可复用** | 找到指针链后可固化到 CE 表 | 永久有效 |

### 6.2 局限与注意事项

| 局限 | 应对方法 |
|------|----------|
| **要求地址在同一结构体** | 阶段①观察地址间距，不规律时分别追踪 |
| **重启后偏移可能变** | 极少见（除非游戏更新）；若遇到需重跑阶段② |
| **动态分配的结构体** | 可能有多个实例（玩家 vs NPC），需额外判断 |
| **IL2CPP / 原生引擎** | 无法用 Mono API（`01-mono-recon.md`），必须走本方法 |

---

## 7. 与其他方法的关系

| 方法 | 何时用 | 本方法的位置 |
|------|--------|--------------|
| **01 Mono 侦察** | Unity Mono 游戏 | 可选；Mono 能反射出类名/字段名，但本方法更快 |
| **02 完整断点追踪** | 从零开始 / 地址分散 | 本方法是其**快速变种**（利用已知地址） |
| **09 Mono 运行时调用** | Unity Mono 需要调方法 | 正交；找到字段后可能还需调 `SetXXX` |
| **10 内存扫描+锁定** | 原生引擎 / 无指针链 | 兜底；本方法优先 |

**决策树**：

```
用户已手动搜到地址
  ├─ 地址在同一结构体内？
  │    ├─ 是 → 用本方法（12）
  │    └─ 否 → 完整断点追踪（02）
  │
  └─ 是 Unity Mono？
       ├─ 是 → 可选用 Mono 反射（01）或本方法
       └─ 否（IL2CPP/原生）→ 必须用本方法
```

---

## 8. 实战案例：Yakuzarogue（Unity IL2CPP）

**背景**：
- 游戏：Yakuzarogue v1.0.7
- 引擎：Unity 2022（IL2CPP 后端）
- 用户已搜到 5 个地址（钱/HP/体力/考核/治安）

**执行记录**：

| 步骤 | 耗时 | 产物 |
|------|------|------|
| ① 观察地址模式 | 1 分钟 | 确认同一结构体 + 选"钱"为锚点 |
| ② 重启 + 重搜 + 计算 | 3 分钟 | 推算出其余 4 个新地址 + 验证通过 |
| ③ 断点追踪 + 反汇编 | 4 分钟 | 找到三级指针链：`[[GameAssembly.dll+32DB080]+B8]+10` |
| ④ 创建 CE 表 + 重启验证 | 2 分钟 | 稳定表通过重启测试 |
| **总计** | **10 分钟** | 5 个稳定指针条目（重启后仍有效） |

**对比**：若从零开始完整侦察（方法 02），每个地址独立追踪约需 25-30 分钟。

**文件清单**（已收录为样例）：
```
D:\Hgame\NyaaTrainer\examples\Yakuzarogue\
├── Yakuzarogue.CT                      (稳定指针版本)
└── Yakuzarogue_old_raw_addresses.CT    (原始裸地址备份)
```

---

## 9. 脚本工具箱

### 9.1 阶段② 地址推算脚本

```lua
-- calculate_addresses.lua
-- 根据锚点地址推算其余字段地址
-- Nyaa be with you.

function calculate_from_anchor(anchor_new, anchor_offset, field_offsets)
  local base_new = anchor_new - anchor_offset
  
  print(string.format("锚点新地址: %X", anchor_new))
  print(string.format("结构体基址: %X", base_new))
  print("\n推算其余字段:")
  
  local results = {}
  for name, offset in pairs(field_offsets) do
    local addr = base_new + offset
    local value = readInteger(addr)
    print(string.format("  %s = %X (值: %d)", name, addr, value or 0))
    results[name] = addr
  end
  
  return results
end

-- 使用示例
local anchor_new = 0x1C8F2EED934  -- 重启后"钱"的新地址
local anchor_offset = 0x34        -- "钱"在结构体内的偏移

local field_offsets = {
  ["钱"]   = 0x34,
  ["HP"]   = 0x38,
  ["体力"] = 0x3C,
  ["考核"] = 0xC0,
  ["治安"] = 0xD8,
}

calculate_from_anchor(anchor_new, anchor_offset, field_offsets)
```

### 9.2 阶段③ 读断点追踪脚本

```lua
-- trace_pointer_chain.lua
-- 对已知地址设读断点，自动收集指针链信息
-- Nyaa be with you.

local target_addr = 0x1C8F2EED934  -- 替换成你的地址
local hit_limit = 5
local hit_count = 0

_G.trace_results = {}

function debugger_onBreakpoint()
  hit_count = hit_count + 1
  
  local result = {
    hit = hit_count,
    rip = RIP,
    disasm = {}
  }
  
  -- 反汇编 RIP 附近（数据断点的 RIP 是下一条指令）
  local addr = RIP - 0x40
  for i = 1, 15 do
    local instr = disassemble(addr)
    if instr then
      table.insert(result.disasm, {addr = addr, instr = instr})
      addr = addr + getInstructionSize(addr)
    else
      break
    end
  end
  
  table.insert(_G.trace_results, result)
  
  -- 打印当前命中
  print(string.format("\n=== 断点命中 #%d ===", hit_count))
  print(string.format("RIP = %X\n", RIP))
  for _, d in ipairs(result.disasm) do
    local marker = (d.addr <= RIP and d.addr + getInstructionSize(d.addr) > RIP) 
                   and " <-- 触发" or ""
    print(string.format("  %X: %s%s", d.addr, d.instr, marker))
  end
  
  if hit_count >= hit_limit then
    print("\n已收集足够数据，移除断点")
    debug_removeBreakpoint(target_addr)
    return 1
  end
  
  return 0
end

-- 主流程
function start_trace()
  local pid = getProcessIDFromProcessName("游戏.exe")  -- 替换成实际游戏名
  if not pid or pid == 0 then
    print("错误: 游戏未运行")
    return false
  end
  
  if getOpenedProcessID() ~= pid then
    openProcess(pid)
  end
  
  print(string.format("对地址 %X 设置读断点...", target_addr))
  debug_setBreakpoint(target_addr, 4, bptAccess)
  
  print("等待 UI 刷新触发断点...")
  return true
end

start_trace()
```

### 9.3 验证指针链脚本

```lua
-- verify_pointer_chain.lua
-- 验证三级指针链是否正确解析
-- Nyaa be with you.

function verify_chain(module_name, static_offset, offsets, field_offset, expected_value)
  print(string.format("验证指针链: [[%s+%X]", module_name, static_offset))
  for i, off in ipairs(offsets) do
    print(string.format("  +%X", off))
  end
  print(string.format("  +%X]", field_offset))
  
  -- 获取模块基址
  local base = nil
  local modules = enumModules()
  for i = 1, #modules do
    if modules[i].Name == module_name then
      base = modules[i].Address
      break
    end
  end
  
  if not base then
    print("错误: 找不到模块 " .. module_name)
    return false
  end
  
  print(string.format("\n%s 基址: %X", module_name, base))
  
  -- 逐级解引用
  local ptr = base + static_offset
  print(string.format("静态地址: %X", ptr))
  
  for i, off in ipairs(offsets) do
    ptr = readPointer(ptr)
    if not ptr or ptr == 0 then
      print(string.format("✗ 第 %d 级指针为空", i))
      return false
    end
    print(string.format("  → [+%X] = %X", off, ptr))
    ptr = ptr + off
  end
  
  -- 读取最终字段
  ptr = readPointer(ptr)
  if not ptr or ptr == 0 then
    print("✗ 最终基址为空")
    return false
  end
  print(string.format("  → 结构体基址 = %X", ptr))
  
  local final_addr = ptr + field_offset
  local value = readInteger(final_addr)
  print(string.format("\n字段值: [%X+%X] = %d", ptr, field_offset, value or 0))
  
  if expected_value and value ~= expected_value then
    print(string.format("✗ 期望 %d，实际 %d", expected_value, value))
    return false
  end
  
  print("✓ 指针链验证通过")
  return true
end

-- 使用示例（Yakuzarogue）
verify_chain(
  "GameAssembly.dll",  -- 模块名
  0x32DB080,           -- 静态偏移
  {0xB8, 0x10},        -- 中间级偏移（从外到内）
  0x34,                -- 字段偏移
  17090                -- 期望值（可选）
)
```

---

## 10. 常见问题

### Q1: 推算的地址读不到值怎么办？

**可能原因**：
1. **结构体偏移判断错误**：重新观察阶段①的地址间距（可能不是简单的 +4/+8）
2. **不在同一结构体**：地址虽然接近但属于不同对象，需分别追踪
3. **游戏版本不同**：重启前后游戏打了补丁，结构体布局变了

**排查方法**：
```lua
-- 在旧地址附近扫描，找出真正的偏移
local base_old = 0x21A155CC480  -- 旧基址
for offset = 0x30, 0x100, 4 do
  local addr = base_old + offset
  local val = readInteger(addr)
  print(string.format("+%02X: %d", offset, val or 0))
end
```

### Q2: 断点不触发怎么办？

**检查清单**：
1. ✅ 游戏进程已附加（`getOpenedProcessID()` 非零）
2. ✅ 地址确实是当前运行时的（不是旧地址）
3. ✅ 用的是读断点 `bptAccess` 而不是写断点 `bptWrite`
4. ✅ 游戏界面能看到该数值（UI 没刷新就不会读）

**强制触发**：
```lua
-- 在 CE 里手动读一次该地址，应该会触发
readInteger(target_addr)
```

### Q3: 重启后指针链失效怎么办？

**检查项**：
1. **静态地址是模块相对还是绝对**：必须是 `"模块名"+偏移`，不能是裸数字
2. **游戏更新了**：DLL 内部结构变化，需要重跑完整流程
3. **ASLR 变化**：极少见；现代 Windows 的 DLL 重定位通常稳定

**CE 表文件检查**：
```xml
<!-- 错误：绝对地址 -->
<Address>7FFE86DAB080</Address>

<!-- 正确：模块相对 -->
<Address>"GameAssembly.dll"+32DB080</Address>
```

---

## 11. 总结：方法适用矩阵

| 场景 | 本方法适用性 | 替代方案 |
|------|--------------|----------|
| Unity Mono 游戏 | ✅ 可用（但 `01-mono-recon.md` 更直接） | Mono 反射 |
| Unity IL2CPP 游戏 | ✅ **首选**（Mono 方法不可用） | — |
| 原生 C/C++ 游戏 | ✅ 可用 | 完整断点追踪（02） |
| 脚本引擎游戏（MV/RGSS/Ren'Py） | ⚠️ 可用但多余（有 eval 通道） | 方法 A（06） |
| 多个地址分散 | ❌ 不适用（不在同一结构体） | 逐个完整追踪（02） |
| 用户只找到 1 个地址 | ⚠️ 可用但优势不明显 | 完整断点追踪（02） |
| 地址间距无规律 | ❌ 不适用 | 完整断点追踪（02） |

**最佳实践**：
1. **有 3+ 个地址在同一结构体** → 本方法（12）
2. **Unity Mono** → 优先 `01-mono-recon.md`（更简单）
3. **Unity IL2CPP / 原生引擎 + 结构体数据** → 本方法（12）
4. **地址分散 / 只有 1 个** → 完整断点追踪（02）

---

## 附录：Yakuzarogue 完整追踪日志（存档）

**指针链最终结论**：
```
[[GameAssembly.dll+32DB080]+B8]+10+字段偏移

├─ +0x34 → 钱   (当前值: 17090)
├─ +0x38 → HP   (当前值: 150)
├─ +0x3C → 体力 (当前值: 240)
├─ +0xC0 → 考核 (当前值: 70)
└─ +0xD8 → 治安 (当前值: 55)
```

**反汇编关键序列**：
```asm
7FFE84034FB1: mov rcx,[7FFE86DAB080]      ; 静态指针
7FFE84034FB8: mov rax,[rcx+B8]            ; 第一级 +B8
7FFE84034FBF: mov rdx,[rax+10]            ; 第二级 +10
7FFE84034FD2: cmp [rdx+34],eax            ; 访问"钱"字段 +34
```

**产物文件**：
- `Yakuzarogue.CT` — 稳定指针版本（主文件）
- `Yakuzarogue_old_raw_addresses.CT` — 原始裸地址备份

**验证结果**：重启游戏 3 次，所有条目均自动解析成功 ✓

---

**Nyaa be with you.**
