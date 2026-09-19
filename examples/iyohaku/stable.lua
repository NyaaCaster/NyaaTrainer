--[[
  iyohaku_stable.lua — 淫白の御供 稳定地址解析（Unity Mono 实例字段版）

  与上个项目（パンドラメイズ / VariableF 静态字段）的差别：
    那个游戏的数据挂在【静态字段】上，绝对地址被 JIT 内联，所以走
    mono_class_getStaticFieldAddress + 字段 offset。
    这个游戏的数据挂在【实例】上：
        GameManager.Instance (静态单例) → +0x20 → GameData → 各字段
    所以链条是「静态根 → 实例偏移 → 字段偏移」，两段都要在运行时算。

  解析链：
    mono_findClass('', 'GameManager')
      → mono_class_getStaticFieldAddress(domain, class)   = GameManager 静态数据区
      → readPointer(staticData + 0x00)                     = GameManager.Instance
      → readPointer(instance  + 0x20)                      = GameData
      → data + 字段偏移                                     = 各数值

  字段偏移来自 mono_class_enumFields（不是硬编码，游戏更新后能自动跟上）：
    GameData.currentHp  maxHp  currentMp  maxMp  day  remainingDays
    reachedStage  deathCount  unlockedSkills

  用法：
    dofile(getCheatEngineDir()..'iyohaku_stable.lua')
    iyohaku.resolve('hp')     -- 解析单个地址
    iyohaku.report()          -- 打印全部数值
    iyohaku.installAll()      -- 写入 CE 地址列表
]]

iyohaku = iyohaku or {}

local I = iyohaku

I.LOG_PATH = 'C:\\Windows\\Temp\\iyohaku_log.txt'

function I.say(s)
  print('[iyohaku] ' .. tostring(s))
  pcall(function()
    local f = io.open(I.LOG_PATH, 'a')
    if f then
      f:write(os.date('%H:%M:%S ') .. tostring(s) .. '\n')
      f:close()
    end
  end)
end

-- 显示名 -> GameData 的字段名
I.FIELDS = {
  { key = 'HP',       field = 'currentHp',      vtype = vtDword },
  { key = 'MaxHP',    field = 'maxHp',          vtype = vtDword },
  { key = 'MP',       field = 'currentMp',      vtype = vtDword },
  { key = 'MaxMP',    field = 'maxMp',          vtype = vtDword },
  { key = 'Day',      field = 'day',            vtype = vtDword },
  { key = 'DaysLeft', field = 'remainingDays',  vtype = vtDword },
  { key = 'Stage',    field = 'reachedStage',   vtype = vtDword },
  { key = 'Deaths',   field = 'deathCount',     vtype = vtDword },
}

-- GameManager 实例里指向 GameData 的字段名（不硬编码 0x20）
local INSTANCE_FIELD = 'Data'
local MANAGER_CLASS  = 'GameManager'
local DATA_CLASS     = 'GameData'

-- 解析出 GameData 对象地址；失败返回 nil, 原因
function I.gameData()
  if not mono_AttachedProcess then return nil, 'mono collector not attached' end
  local dms = mono_enumDomains()
  local domain = dms and dms[1]
  if not domain then return nil, 'no mono domain' end

  local mgr = mono_findClass('', MANAGER_CLASS)
  if not mgr or mgr == 0 then return nil, 'class not found: ' .. MANAGER_CLASS end
  local sbase = mono_class_getStaticFieldAddress(domain, mgr)
  if not sbase or sbase == 0 then return nil, 'no static data for ' .. MANAGER_CLASS end

  -- 从静态区找 Instance（字段名 <Instance>k__BackingField，用枚举拿偏移）
  local inst = nil
  local fds = mono_class_enumFields(mgr)
  if fds then
    for i = 1, #fds do
      local f = fds[i]
      if f.isStatic and (f.name == 'Instance' or f.name:find('Instance')) then
        inst = readPointer(sbase + f.offset)
        break
      end
    end
  end
  if not inst or inst == 0 then return nil, 'GameManager.Instance is null (游戏还没进主场景?)' end

  -- 从实例里找 Data
  --   注意：编译器给 property 生成的名字是 "<Data>k__BackingField"，
  --   所以要模糊匹配，不能写 f.name == 'Data'
  local data = nil
  local ifs = mono_class_enumFields(mgr)
  if ifs then
    for i = 1, #ifs do
      local f = ifs[i]
      if (not f.isStatic) and f.name:find(INSTANCE_FIELD, 1, true) then
        local p = readPointer(inst + f.offset)
        if p and p ~= 0 then
          data = p
          break
        end
      end
    end
  end
  if not data or data == 0 then return nil, 'GameManager.Data is null' end
  return data
end

-- 解析单个字段的绝对地址
function I.resolve(key)
  local data, err = I.gameData()
  if not data then return nil, err end
  local cls = mono_findClass('', DATA_CLASS)
  if not cls or cls == 0 then return nil, 'class not found: ' .. DATA_CLASS end
  local fds = mono_class_enumFields(cls)
  if not fds then return nil, 'field enumeration failed' end
  for i = 1, #I.FIELDS do
    if I.FIELDS[i].key == key then
      local want = I.FIELDS[i].field
      for j = 1, #fds do
        local f = fds[j]
        if (not f.isStatic) and f.name == want then
          return data + f.offset
        end
      end
      return nil, 'field not found: ' .. want
    end
  end
  return nil, 'unknown key: ' .. tostring(key)
end

-- 读全部数值（返回 table: key -> value）
function I.readAll()
  local res = {}
  for i = 1, #I.FIELDS do
    local k = I.FIELDS[i].key
    local a = I.resolve(k)
    if a then
      local v = readInteger(a)
      if v ~= nil then res[k] = v end
    end
  end
  return res
end

-- 写入并回读验证
function I.write(key, value)
  local a, err = I.resolve(key)
  if not a then return nil, err end
  writeInteger(a, value)
  return readInteger(a)
end

-- 写入 CE 地址列表
function I.installAll()
  local n, fail = 0, {}
  local al = getAddressList()
  for i = 1, #I.FIELDS do
    local e = I.FIELDS[i]
    local a, err = I.resolve(e.key)
    if a then
      local mr = nil
      for j = 0, al.Count - 1 do
        local m = al.getMemoryRecord(j)
        if m.Description == e.key then mr = m; break end
      end
      if mr == nil then mr = al.createMemoryRecord() end
      mr.Description = e.key
      mr.Type = e.vtype or vtDword
      mr.Address = string.format('%X', a)
      n = n + 1
    else
      fail[#fail + 1] = e.key .. ': ' .. tostring(err)
    end
  end
  return n, fail
end

function I.report()
  local out = {}
  local data, err = I.gameData()
  if not data then
    out[#out + 1] = '解析失败: ' .. tostring(err)
    return table.concat(out, '\n')
  end
  out[#out + 1] = string.format('GameData = %X', data)
  local v = I.readAll()
  for i = 1, #I.FIELDS do
    local k = I.FIELDS[i].key
    local a = I.resolve(k)
    out[#out + 1] = string.format('  %-9s @ %s = %s',
      k, a and string.format('%X', a) or '?', tostring(v[k]))
  end
  if v.HP and v.MaxHP and v.MaxHP > 0 then
    out[#out + 1] = string.format('  HP 比例 = %.1f%%', v.HP / v.MaxHP * 100)
  end
  return table.concat(out, '\n')
end
