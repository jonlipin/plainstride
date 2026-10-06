// Offline checks for Plainstride: loads Plainstride.lua and Display.lua into fengari (Lua 5.3)
// against a stubbed WoW Forever client and drives logins, movement, aura and run-speed readings,
// combat, hits, the demo and every slash command. Secret values are trapped the way the client
// does it: tainted code may not compare, do arithmetic on, index or truth-test (booleans) them.
//
//   node tests/plainstridetest.js [--verbose]
//
// fengari is looked for in FENGARI=<its folder>, then on the normal require path.
'use strict';
const fs = require('fs');
const path = require('path');
const Module = require('module');

const ROOT = path.join(__dirname, '..');
const VERBOSE = process.argv.includes('--verbose');
const ADDON_FILES = ['Plainstride.lua', 'Display.lua', 'Options.lua'];
const isAddonSource = (src) => ADDON_FILES.some(f => src === '@' + f);
// SHOTWINDOW_LUA=<file> runs the same checks against another copy (a candidate fix, say).
const ADDON_SRC = ADDON_FILES.map(f => [f, fs.readFileSync(path.join(ROOT, f), 'utf8')]);

function findFengari() {
  const tries = [];
  if (process.env.FENGARI) tries.push(process.env.FENGARI);
  try { tries.push(path.dirname(require.resolve('fengari/package.json'))); } catch (e) { /* not on the path */ }
  tries.push('C:/Users/jonli/AppData/Local/Temp/claude/C--Users-jonli-ffxi-ah-analysis/989059d8-08ec-488d-9dd6-df53722920db/scratchpad/node_modules/fengari');
  for (const d of tries) if (fs.existsSync(path.join(d, 'src', 'lvm.js'))) return d;
  throw new Error('fengari not found; set FENGARI to its folder');
}
const FDIR = findFengari();

// Equality: luaV_equalobj is module-local in lvm.js and sees == against nil, which __eq never does,
// so lvm.js is patched as it loads.
const lvmPath = require.resolve(path.join(FDIR, 'src', 'lvm.js'));
let lvmPatched = false;
{
  const origJs = Module._extensions['.js'];
  Module._extensions['.js'] = function (m, filename) {
    if (filename !== lvmPath) return origJs(m, filename);
    const src = fs.readFileSync(filename, 'utf8');
    const hook = 'const luaV_equalobj = function(L, t1, t2) {';
    if (!src.includes(hook)) throw new Error('fengari lvm.js changed shape');
    lvmPatched = true;
    m._compile(src.replace(hook, hook + ' if (L !== null && global.__swEqHook) global.__swEqHook(L, t1, t2);'), filename);
  };
}
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require(FDIR);
if (!lvmPatched) throw new Error('lvm.js was loaded before the equality hook could be installed');
const lobject = require(path.join(FDIR, 'src', 'lobject.js'));
const ltable = require(path.join(FDIR, 'src', 'ltable.js'));
const ldebug = require(path.join(FDIR, 'src', 'ldebug.js'));
const { LUA_TTABLE } = require(path.join(FDIR, 'src', 'defs.js')).constant_types;

// ---------------------------------------------------------------------------------------------
// The secret trap
const BOX = new WeakMap(); // stand-in table -> { type, tv }
let HITS = new Map();      // refused uses by the addon: "Plainstride.lua:N  what" -> count
let SEEN = new Map();      // allowed uses by the addon, for the report
let L = null;              // the state being run
const isSecretTV = (tv) => !!tv && tv.type === LUA_TTABLE && BOX.has(tv.value);

function addonWhere(state) {
  for (let ci = state && state.ci; ci; ci = ci.previous) {
    const f = ci.func && ci.func.value;
    if (f && f.p) {
      const src = to_jsstring(f.p.source.getstr());
      if (!isAddonSource(src)) return null;
      return src.slice(1) + ':' + (f.p.lineinfo[ci.l_savedpc - 1] || '?');
    }
  }
  return null;
}
function tally(map, where, what) { const k = where + '  ' + what; map.set(k, (map.get(k) || 0) + 1); }
function refuse(state, what) {
  state = state || L;
  const where = addonWhere(state);
  if (!where) return false;
  tally(HITS, where, what);
  const ci = state.ci;
  const inLua = ci.func && ci.func.value && ci.func.value.p; // runerror adds file:line itself then
  ldebug.luaG_runerror(state, to_luastring((inLua ? '' : where + ': ') + 'attempt to perform ' + what + ' on a secret value (tainted by Plainstride)'));
  return true;
}
function allowed(state, what) {
  const where = addonWhere(state || L);
  if (where) tally(SEEN, where, what);
}
// Taint, roughly: any Plainstride.lua function on the call stack makes the call the addon's.
function addonOnStack(state) {
  for (let ci = state && state.ci; ci; ci = ci.previous) {
    const f = ci.func && ci.func.value;
    if (f && f.p && isAddonSource(to_jsstring(f.p.source.getstr()))) return true;
  }
  return false;
}

// Truth tests: if/while/not/and/or all go through TValue.l_isfalse.
{
  const orig = lobject.TValue.prototype.l_isfalse;
  lobject.TValue.prototype.l_isfalse = function () {
    if (isSecretTV(this)) {
      const typ = BOX.get(this.value).type;
      if (typ === 'boolean') refuse(L, 'boolean test');
      else allowed(L, 'truth test of a secret ' + typ + ' (allowed)');
    }
    return orig.call(this);
  };
}
global.__swEqHook = (state, a, b) => { if (isSecretTV(a) || isSecretTV(b)) refuse(state, 'comparison (== or ~=)'); };
for (const name of ['luaH_get', 'luaH_setfrom']) {
  const orig = ltable[name];
  ltable[name] = function (state, t, key, ...rest) {
    if (isSecretTV(key)) refuse(state, 'table access with a secret key');
    return orig.call(this, state, t, key, ...rest);
  };
}

const arg1 = (S, i) => (lua.lua_gettop(S) >= i ? S.stack[S.ci.funcOff + i] : null);
function mint(S) { // replaces the value on top of the stack with a secret stand-in for it
  const src = S.stack[S.top - 1];
  const typ = to_jsstring(lua.lua_typename(S, lua.lua_type(S, -1)));
  const tv = new lobject.TValue(src.type, src.value);
  lua.lua_pop(S, 1);
  lua.lua_newtable(S);
  BOX.set(lua.lua_topointer(S, -1), { type: typ, tv });
  lua.lua_getfield(S, lua.LUA_REGISTRYINDEX, to_luastring('SW_SECRET_META'));
  lua.lua_setmetatable(S, -2);
}
function pushPlain(S, i) { // pushes argument i, unwrapped if it is a secret
  const tv = arg1(S, i);
  if (isSecretTV(tv)) lobject.pushobj2s(S, BOX.get(tv.value).tv); else lua.lua_pushvalue(S, i);
}
function installSecretApi(S) {
  const fn = (name, f) => { lua.lua_pushcfunction(S, f); lua.lua_setglobal(S, to_luastring(name)); };
  fn('secret', (S) => { lua.lua_settop(S, 1); mint(S); return 1; });
  fn('issecretvalue', (S) => { lua.lua_pushboolean(S, isSecretTV(arg1(S, 1))); return 1; });
  fn('unsecret', (S) => { pushPlain(S, 1); return 1; });
  fn('secrettype', (S) => { lua.lua_pushstring(S, to_luastring(BOX.get(arg1(S, 1).value).type)); return 1; });
  fn('fromaddon', (S) => { lua.lua_pushboolean(S, addonOnStack(S)); return 1; });

  // Metamethods are JS functions, so the nearest Lua frame when they run is the code that used
  // the secret (math.max and friends are skipped as C frames).
  lua.lua_newtable(S);
  const set = (name, f) => { lua.lua_pushcfunction(S, f); lua.lua_setfield(S, -2, to_luastring(name)); };
  for (const e of ['add', 'sub', 'mul', 'div', 'mod', 'pow', 'unm', 'idiv', 'band', 'bor', 'bxor', 'shl', 'shr', 'bnot']) {
    set('__' + e, (S) => { refuse(S, 'arithmetic'); return 0; });
  }
  set('__lt', (S) => { refuse(S, 'ordered comparison'); lua.lua_pushboolean(S, false); return 1; });
  set('__le', (S) => { refuse(S, 'ordered comparison'); lua.lua_pushboolean(S, false); return 1; });
  set('__eq', (S) => { refuse(S, 'comparison (== or ~=)'); lua.lua_pushboolean(S, false); return 1; });
  set('__index', (S) => { refuse(S, 'indexing'); return 0; });
  set('__newindex', (S) => { refuse(S, 'indexed assignment'); return 0; });
  set('__call', (S) => { refuse(S, 'call'); return 0; });
  set('__len', (S) => { refuse(S, 'length'); return 0; });
  set('__pairs', (S) => { refuse(S, 'iteration'); return 0; });
  set('__concat', (S) => { // allowed for strings and numbers; the result is secret
    allowed(S, 'concatenation (allowed)');
    pushPlain(S, 1); pushPlain(S, 2); lua.lua_concat(S, 2); mint(S); return 1;
  });
  set('__tostring', (S) => { allowed(S, 'tostring'); lua.lua_pushstring(S, to_luastring('<secret>')); return 1; });
  lua.lua_pushstring(S, to_luastring('secret')); lua.lua_setfield(S, -2, to_luastring('__name'));
  lua.lua_pushboolean(S, false); lua.lua_setfield(S, -2, to_luastring('__metatable'));
  lua.lua_setfield(S, lua.LUA_REGISTRYINDEX, to_luastring('SW_SECRET_META'));
}
// ---------------------------------------------------------------------------------------------
// The client stub
const STUB = String.raw`
T = { prints = {}, frames = {}, errors = {}, fails = {}, checks = 0, unknown = {} }
T.now = 100
T.race = "Tauren"
T.combat = false
T.aura = nil          -- stacks on you (nil = no buff)
T.auraMode = "plain"  -- plain / hidden (combat style nil) / secret / error
T.speed = 0           -- current speed
T.baseRun = 7
T.run = nil           -- run speed override; default baseRun * (1 + aura/100)
T.speedMode = "plain" -- plain / secret / error
T.falling = false
T.fallingSecret = false
T.mounted = false
T.templates = { CastingBarFrameTemplate = true, UICheckButtonTemplate = true, MinimalSliderTemplate = true,
  UIPanelButtonTemplate = true, ButtonFrameTemplate = true }

local realType = type
function type(v) if issecretvalue(v) then return secrettype(v) end return realType(v) end
local realFormat = string.format
string.format = function(fmt, ...)
  local n, args, any = select("#", ...), { ... }, issecretvalue(fmt)
  for i = 1, n do if issecretvalue(args[i]) then any = true args[i] = unsecret(args[i]) end end
  if not any then return realFormat(fmt, ...) end
  return secret(realFormat(unsecret(fmt), table.unpack(args, 1, n)))
end
format = string.format

function GetTime() return T.now end
function UnitRace(u) return T.race, T.race end
function IsPlayerSpell(id) return false end
function InCombatLockdown() return T.combat end
function IsMounted() return T.mounted end
function UnitOnTaxi() return false end
function UnitInVehicle() return false end
function GetShapeshiftForm() return 0 end
function IsFalling()
  if T.fallingSecret then return secret(T.falling) end
  return T.falling
end
function GetUnitSpeed(unit)
  if T.speedMode == "error" then error("GetUnitSpeed: test failure") end
  local run = T.run or T.baseRun * (1 + (T.aura or 0) / 100)
  local cur = T.speed > 0 and run or 0
  if T.speedMode == "secret" then return secret(cur), secret(run), secret(7), secret(4.7) end
  return cur, run, 7, 4.7
end
C_UnitAuras = { GetPlayerAuraBySpellID = function(id)
  if id ~= 1299038 then return nil end
  local m = T.auraMode
  if m == "error" then error("aura: test failure") end
  if m == "hidden" then return nil end
  if T.aura == nil then return nil end
  if m == "secret" then return secret({ applications = T.aura }) end
  if m == "secretStacks" then return { applications = secret(T.aura), spellId = id } end
  return { applications = T.aura, spellId = id, name = "Plainsrunning" }
end }
C_Secrets = {
  ShouldAurasBeSecret = function() return T.combat end,
  ShouldUnitStatsBeSecret = function() return T.speedMode == "secret" end,
  GetSpellAuraSecrecy = function() return 1 end,
}
C_Spell = { GetSpellTexture = function(id) return 136000 + id % 1000 end }
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) T.prints[#T.prints + 1] = m end }
SlashCmdList = {}
CombatTextFont = { font = "CombatTextFont" }
GameFontNormalHuge = { font = "GameFontNormalHuge" }

-- Widgets: every method the addon calls is recorded; the ones whose answer matters are real.
local KNOWN = {}
for m in ([[SetSize SetWidth SetHeight SetPoint ClearAllPoints SetAllPoints SetAtlas SetTexture SetBlendMode
  SetAlpha SetShown Show Hide SetText SetTextColor SetJustifyH SetFontObject SetDrawLayer AddMaskTexture
  SetTextureWrap SetFrameStrata SetClampedToScreen SetMovable RegisterForDrag SetScript EnableMouse SetScale
  SetFrameLevel SetStatusBarTexture SetMinMaxValues SetValue UnregisterAllEvents RegisterEvent SetUnit
  SetPortraitZoom SetFacing SetAnimation StartMoving StopMovingOrSizing SetColorTexture SetTexCoord
  SetVertexColor UnregisterEvent CreateTexture CreateMaskTexture CreateFontString CreateAnimationGroup
  GetPoint GetFrameLevel IsShown GetScript SetToFinalAlpha SetDuration SetOrder SetStartDelay SetFromAlpha
  SetToAlpha SetSmoothing SetLooping SetFlipBookRows SetFlipBookColumns SetFlipBookFrames SetFlipBookFrameWidth
  SetFlipBookFrameHeight SetScaleFrom SetScaleTo SetDegrees SetOffset Play Stop IsPlaying SetClipsChildren SetChecked SetOrientation SetValueStep SetObeyStepOnDrag
  SetHighlightTexture RegisterForClicks SetToplevel SetParent SetTitle SetPortraitToAsset Raise SetJustifyV
  SetOwner AddLine AddDoubleLine ClearLines SetMouseMotionEnabled SetMouseClickEnabled]]):gmatch("%S+") do KNOWN[m] = true end

local Widget = {}
local function widget(kind, parent)
  local w = setmetatable({ kind = kind, parent = parent, shown = true, alpha = 1, scripts = {}, calls = {},
    points = {}, level = (parent and rawget(parent, "level") or 0) + 1, events = {} }, Widget)
  T.frames[#T.frames + 1] = w
  return w
end
Widget.__index = function(self, k)
  local m = rawget(Widget, k)
  if m then return m end
  if realType(k) == "string" and KNOWN[k] then
    return function(s, ...) s.calls[k] = (s.calls[k] or 0) + 1 return nil end
  end
  if realType(k) == "string" and k:match("^[A-Z]") then T.unknown[k] = (T.unknown[k] or 0) + 1 end
  return nil
end
function Widget:SetShown(v) self.shown = not not v end
function Widget:Show() self.shown = true end
function Widget:Hide() self.shown = false end
function Widget:IsShown() return self.shown end
function Widget:SetAlpha(a) self.alpha = a end
function Widget:SetScript(n, f) self.scripts[n] = f end
function Widget:GetScript(n) return self.scripts[n] end
function Widget:RegisterEvent(e) self.events[e] = true end
function Widget:UnregisterEvent(e) self.events[e] = nil end
function Widget:UnregisterAllEvents() self.events = {} end
function Widget:SetText(t) self.text = t end
function Widget:SetAtlas(a, use) self.atlas = a return true end
function Widget:SetStatusBarTexture(t) self.barTexture = t end
function Widget:SetValue(v) self.value = v end
function Widget:SetWidth(w) self.width = w end
function Widget:SetPoint(...) self.points[#self.points + 1] = { ... } end
function Widget:ClearAllPoints() self.points = {} end
function Widget:GetPoint(i) local p = self.points[i or 1] if not p then return nil end
  local rel = p[2]
  if realType(rel) == "table" then return p[1], rel, p[3], p[4], p[5] end
  return p[1], nil, p[2], p[3], p[4] end
function Widget:GetFrameLevel() return self.level end
function Widget:SetFrameLevel(l) self.level = l end
function Widget:CreateTexture(name, layer) return widget("Texture", self) end
function Widget:CreateMaskTexture() return widget("MaskTexture", self) end
function Widget:CreateFontString(name, layer, inherits) local f = widget("FontString", self) f.inherits = inherits return f end
function Widget:SetFontObject(o) if o == nil then error("SetFontObject(nil)") end self.font = o end
function Widget:SetAnimation(id) self.anim = id end
function Widget:SetUnit(u) if self.kind == "PlayerModel" and T.modelFails then error("no model") end self.unit = u end
function Widget:CreateAnimationGroup()
  local g = widget("AnimationGroup", self)
  g.plays, g.anims = 0, {}
  function g:Play() self.plays = self.plays + 1 self.playing = true end
  function g:Stop() self.playing = false end
  function g:IsPlaying() return self.playing end
  function g:CreateAnimation(kind)
    local a = widget("Animation:" .. tostring(kind), self)
    self.anims[#self.anims + 1] = a
    function a:SetOffset(x, y) self.offset = { x, y } end
    return a
  end
  return g
end

UIParent = widget("Frame", nil)
function Widget:GetChecked() return self.checked end
function Widget:SetChecked(v) self.checked = v end
function Widget:SetParent(p) self.parent = p end
function Widget:GetParent() return self.parent end
function Widget:IsVisible()
  local w = self
  while w do if not w.shown then return false end w = w.parent end
  return true
end
function Widget:GetWidth() return self.width or 0 end
function Widget:GetHeight() return self.height or 0 end
function Widget:SetSize(w, h) self.width, self.height = w, h end
function Widget:GetCenter() return 500, 500 end
function Widget:GetEffectiveScale() return 1 end
function Widget:Click(button)
  local f = self.scripts.OnClick
  if f then local ok, err = pcall(f, self, button or "LeftButton") if not ok then T.errors[#T.errors + 1] = "click: " .. tostring(err) end end
end
Minimap = widget("Frame", UIParent) Minimap.width = 140
GameTooltip = widget("Frame", UIParent)
UISpecialFrames = {}
function GetCursorPosition() return 600, 500 end
SettingsPanel = widget("Frame", UIParent) SettingsPanel.shown = false
T.settings = { opens = 0 }
Settings = {
  RegisterCanvasLayoutCategory = function(page, name)
    T.settings.page, T.settings.name = page, name
    return { ID = 77, GetID = function(self) return self.ID end }
  end,
  RegisterAddOnCategory = function(cat) T.settings.category = cat end,
  OpenToCategory = function(id)
    T.settings.opens = T.settings.opens + 1
    if T.combat then return end -- refused for addon code in combat
    SettingsPanel.shown = true
    local page = T.settings.page
    page.parent = SettingsPanel page.shown = true page.width, page.height = 640, 560
    if page.scripts.OnShow then page.scripts.OnShow(page) end
  end,
}
function HideUIPanel(f) f.shown = false end
PlayerFrame = widget("Frame", UIParent) PlayerFrame.width = 232
T.isPlayerMoving = nil
function IsPlayerMoving() return T.isPlayerMoving end
function Widget:AddLine(t) self.lines = self.lines or {} self.lines[#self.lines + 1] = t end
function Widget:AddDoubleLine(a, b) self.lines = self.lines or {} self.lines[#self.lines + 1] = a .. " | " .. b end
function Widget:ClearLines() self.lines = {} end
function Widget:SetOwner(o) self.owner = o end
function Widget:SetMouseMotionEnabled(v) self.motion = v end
function Widget:SetMouseClickEnabled(v) self.clicks = v end
function Widget:EnableMouse(v) self.mouse = v self.motion = v self.clicks = v end
function T.tipHas(pat) for _, l in ipairs(GameTooltip.lines or {}) do if l:find(pat) then return true end end return false end
function CreateFrame(kind, name, parent, template)
  if template and not T.templates[template] then error("unknown template " .. template) end
  local f = widget(kind, parent)
  if name then _G[name] = f end
  if template == "CastingBarFrameTemplate" then
    for _, k in ipairs({ "TextBorder", "Icon", "BorderShield", "DropShadow", "CastTimeText", "Spark", "Flash",
        "StandardGlow", "ChannelShadow", "CraftGlow", "Background", "Border", "BorderMask", "EnergyMask" }) do
      f[k] = widget("Texture", f)
    end
    f.Text = widget("FontString", f)
    for _, k in ipairs({ "ChannelFinish", "StandardFinish", "InterruptGlowAnim", "InterruptShakeAnim" }) do
      f[k] = f:CreateAnimationGroup()
    end
    f.SetUnit = function(self, u) self.unit = u end
    f.events.UNIT_SPELLCAST_START = true
  end
  return f
end

-- driving the client
function T.fire(event, ...)
  for _, f in ipairs(T.frames) do
    if f.events[event] and f.scripts.OnEvent then
      local ok, err = pcall(f.scripts.OnEvent, f, event, ...)
      if not ok then T.errors[#T.errors + 1] = event .. ": " .. tostring(err) end
    end
  end
end
function T.step(seconds, dt)
  dt = dt or 0.02
  local n = math.floor(seconds / dt + 0.5)
  local frame = rawget(_G, "PlainstrideFrame")
  for i = 1, n do
    T.now = T.now + dt
    local f = frame and frame.scripts.OnUpdate
    if f then
      local ok, err = pcall(f, frame, dt)
      if not ok then T.errors[#T.errors + 1] = "OnUpdate: " .. tostring(err) return end
    end
  end
end
-- As the client does it: InCombatLockdown() is still false while PLAYER_REGEN_DISABLED runs,
-- and already false when PLAYER_REGEN_ENABLED runs.
function T.enterCombat()
  T.fire("PLAYER_REGEN_DISABLED")
  T.combat = true
end
function T.leaveCombat()
  T.combat = false
  T.fire("PLAYER_REGEN_ENABLED")
end
function T.login()
  T.fire("ADDON_LOADED", "Plainstride")
  T.fire("PLAYER_ENTERING_WORLD")
end
function T.slash(msg) local ok, err = pcall(SlashCmdList.PLAINSTRIDE, msg) if not ok then T.errors[#T.errors + 1] = "slash " .. msg .. ": " .. tostring(err) end end
function check(cond, label)
  T.checks = T.checks + 1
  if not cond then T.fails[#T.fails + 1] = label end
end
function T.printed(pat) for _, p in ipairs(T.prints) do if p:find(pat) then return true end end return false end
function T.report()
  local out = {}
  for _, e in ipairs(T.errors) do out[#out + 1] = "E\t" .. e end
  for _, f in ipairs(T.fails) do out[#out + 1] = "F\t" .. f end
  for k, n in pairs(T.unknown) do out[#out + 1] = "U\t" .. k .. " x" .. n end
  for _, p in ipairs(T.prints) do out[#out + 1] = "P\t" .. p end
  out[#out + 1] = "C\t" .. T.checks
  return table.concat(out, "\n")
end
`;

// ---------------------------------------------------------------------------------------------
function exec(S, code, name) {
  if (lauxlib.luaL_loadbuffer(S, to_luastring(code), null, to_luastring(name)) !== 0) return lua.lua_tojsstring(S, -1);
  if (lua.lua_pcall(S, 0, 0, 0) !== 0) return lua.lua_tojsstring(S, -1);
  return null;
}
function newState() {
  const S = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(S);
  L = S;
  installSecretApi(S);
  const err = exec(S, STUB, '=stub');
  if (err) throw new Error('stub: ' + err);
  return S;
}
function loadAddon(S) {
  lua.lua_newtable(S);
  lua.lua_setglobal(S, to_luastring('NS'));
  for (const [file, src] of ADDON_SRC) {
    if (lauxlib.luaL_loadbuffer(S, to_luastring(src), null, to_luastring('@' + file)) !== 0) return lua.lua_tojsstring(S, -1);
    lua.lua_pushstring(S, to_luastring('Plainstride'));
    lua.lua_getglobal(S, to_luastring('NS'));
    if (lua.lua_pcall(S, 2, 0, 0) !== 0) return file + ': ' + lua.lua_tojsstring(S, -1);
  }
  return null;
}

let failed = 0, passed = 0, checks = 0;
function scenario(name, body) {
  HITS = new Map(); SEEN = new Map();
  const S = newState();
  const loadErr = loadAddon(S);
  let lines = [];
  if (loadErr) lines.push('E\tloading: ' + loadErr);
  else {
    const bodyErr = exec(S, body, '=test');
    if (bodyErr) lines.push('F\ttest body stopped: ' + bodyErr);
  }
  const repErr = exec(S, 'REPORT = T.report()', '=test');
  if (repErr) lines.push('F\treport: ' + repErr);
  lua.lua_getglobal(S, to_luastring('REPORT'));
  const rep = lua.lua_isstring(S, -1) ? lua.lua_tojsstring(S, -1) : '';
  lines = lines.concat(rep.split('\n').filter(Boolean));
  const fails = lines.filter(l => l[0] === 'F').map(l => 'check failed: ' + l.slice(2));
  const errs = lines.filter(l => l[0] === 'E').map(l => 'Lua error:    ' + l.slice(2));
  const unknown = lines.filter(l => l[0] === 'U').map(l => 'unstubbed widget method: ' + l.slice(2));
  const c = lines.find(l => l[0] === 'C');
  checks += c ? Number(c.slice(2)) : 0;
  const bad = fails.length + errs.length + HITS.size;
  if (bad) failed++; else passed++;
  console.log((bad ? 'FAIL ' : 'ok   ') + name);
  for (const l of errs.concat(fails)) console.log('       ' + l);
  for (const [k, n] of HITS) console.log('       refused secret use: ' + k + '  x' + n);
  for (const l of unknown) console.log('       ' + l);
  if (VERBOSE) {
    for (const [k, n] of SEEN) console.log('       allowed secret use: ' + k + '  x' + n);
    for (const l of lines.filter(l => l[0] === 'P')) console.log('       | ' + l.slice(2));
  }
}

// ---------------------------------------------------------------------------------------------
// Scenarios
const NS = 'local ns = NS local D = ns.Display local st = ns.state local v = ns.view ';

scenario('loads, builds the Blizzard-art display and shows for a tauren', NS + `
  T.login()
  check(D.frame ~= nil, "frame built")
  check(D.frame.shown, "shown for a tauren")
  check(D.tick.templated, "the cast bar template was used")
  check(D.tick.unit == nil and next(D.tick.events) == nil, "the cast bar listens to nothing")
  check(D.tick.scripts.OnUpdate == nil and D.tick.scripts.OnEvent == nil, "Blizzard's cast bar loop is off")
  check(D.stack.Fill.atlas == "skillbar_fill_flipbook_herbalism", "herbalism fill: " .. tostring(D.stack.Fill.atlas))
  check(D.stack.Border.atlas == "Professions-skillbar-frame", "profession frame")
  T.step(1)
  check(#T.errors == 0, "no errors")
  check(T.printed("Options"), "first-login hint")
`);

scenario('hidden for other races', NS + `
  T.race = "Orc"
  T.login()
  check(not D.frame.shown, "hidden")
`);

scenario('out of combat: the aura gives the count; moving fills toward the next stack', NS + `
  T.login()
  T.aura = 3 T.speed = 7.21
  T.step(0.2)
  check(st.stacks == 3 and st.source == "aura", "3 from the aura: " .. tostring(st.stacks) .. " " .. st.source)
  check(st.moving, "moving")
  T.step(1.0)
  local mode, frac, left = ns.clocks(T.now, st.stacks)
  check(mode == "gain", "gain mode: " .. tostring(mode))
  check(D.tick.barTexture == "ui-castingbar-filling-channel", "channel fill while gaining: " .. tostring(D.tick.barTexture))
  check(D.tick.Text.text:find("Next stack"), "next stack text: " .. tostring(D.tick.Text.text))
  check(D.stack.FillAnim.playing, "the herbalism fill flows while running")
  T.aura = 4
  T.step(0.1)
  check(st.stacks == 4, "4 now")
  check(D.stack.FlareFadeOut.plays >= 1, "flare on a gain")
  check(D.tick.ChannelFinish.plays >= 1, "cast bar channel finish on a gain")
  T.step(0.6)
  check(math.abs(v.shown - 4) < 0.01, "segments eased to 4: " .. v.shown)
  check(math.abs(D.stack.Clip.width - 441 * 4 / 30) < 0.01, "only 4 stacks of the fill show: " .. tostring(D.stack.Clip.width))
  check(D.stack.Text.text:find("4 / 30"), "text: " .. tostring(D.stack.Text.text))
`);

scenario('the gain cycle runs on the clock from the last stack', NS + `
  T.login()
  T.aura = 5 T.speed = 7.3
  T.step(0.2)
  T.aura = 6
  T.step(0.1)
  T.step(2.5)
  local _, frac, left = ns.clocks(T.now, st.stacks)
  check(math.abs(frac - 0.5) < 0.05, "half way after 2.5 s: " .. frac)
  check(math.abs(left - 2.5) < 0.1, "2.5 s left: " .. left)
`);

scenario('standing still: the tick bar drains toward the next loss and a loss is a decay', NS + `
  T.login()
  T.aura = 10 T.speed = 7.7
  T.step(0.5)
  T.speed = 0
  T.step(0.5)
  check(not st.moving, "stopped after the grace")
  local mode, frac, left = ns.clocks(T.now, st.stacks)
  check(mode == "decay", "decay mode")
  check(D.tick.barTexture == "ui-castingbar-filling-standard", "standard fill while draining: " .. tostring(D.tick.barTexture))
  check(not D.stack.FillAnim.playing, "the fill rests while standing")
  T.step(0.9)
  check(D.tick.barTexture == "ui-castingbar-interrupted", "red in the last moment: " .. tostring(D.tick.barTexture))
  T.aura = 9
  T.step(0.1)
  check(st.stacks == 9, "9")
  check(v.ghost and v.ghost.atlas == "ui-castingbar-filling-standard", "a gold ghost for a decay")
  check(D.Shake.plays == 0, "no shake for a decay")
  T.step(0.6)
  check(v.ghost == nil, "ghost drained")
  check(ns.db.log[#ns.db.log].kind == "decay", "logged as decay")
`);

scenario('the beat: the second loss lands one beat after the first, and the bar knows it', NS + `
  T.login()
  T.aura = 10 T.speed = 7.7
  T.step(0.5)
  T.speed = 0
  T.step(1.6)
  T.aura = 9 T.step(0.04)
  local _, _, left = ns.clocks(T.now, st.stacks)
  check(math.abs(left - 0.96) < 0.08, "next loss about 1 s after the first: " .. left)
  T.step(0.96) T.aura = 8 T.step(0.04)
  check(#ns.db.decayTicks == 1, "a decay tick measured")
`);

scenario('a hit while moving: red ghost, shake, floating loss, glow', NS + `
  T.login()
  T.aura = 20 T.speed = 8.4
  T.step(2)
  T.aura = 13
  T.step(0.05)
  check(st.stacks == 13, "13")
  check(ns.db.log[#ns.db.log].kind == "hit", "logged as a hit")
  check(v.ghost and v.ghost.atlas == "ui-castingbar-interrupted", "red cracked ghost")
  check(D.Shake.plays == 1, "shake")
  check(D.Float.text == "-7", "floating -7: " .. tostring(D.Float.text))
  check(D.stack.HitGlowAnim.plays == 1 and D.tick.InterruptGlowAnim.plays == 1, "interrupt glows")
`);





scenario('secret aura table, secret stacks, secret IsFalling, raising APIs: no secret is touched', NS + `
  T.login()
  T.auraMode = "secret" T.aura = 4 T.speed = 7.28
  T.step(0.3)
  T.auraMode = "secretStacks"
  T.step(0.3)
  T.fallingSecret = true T.falling = true T.speed = 0
  T.step(0.5)
  T.auraMode = "error" T.speedMode = "error"
  T.step(0.5)
  check(#T.errors == 0, "no errors: " .. tostring(T.errors[1]))
`);


scenario('hidden in combat, back after it with a fresh count and no animation for the fight', NS + `
  T.login()
  T.aura = 12 T.speed = 7.84
  T.step(0.5)
  check(st.stacks == 12, "12 before the fight")
  T.auraMode = "hidden"
  T.enterCombat()
  check(not D.frame.shown, "hidden in combat")
  T.aura = 5
  T.step(2)
  check(st.stacks == 12, "nothing read in combat: " .. tostring(st.stacks))
  local logged = #ns.db.log
  T.auraMode = "plain"
  T.leaveCombat()
  check(D.frame.shown, "shown again")
  check(st.stacks == 5 and st.source == "aura", "re-read 5 from the buff: " .. tostring(st.stacks))
  check(D.Shake.plays == 0 and v.ghost == nil and D.FloatAnim.plays == 0, "no hit animation for the fight")
  check(#ns.db.log == logged, "the fight is not logged as a change")
  check(math.abs(v.shown - 5) < 0.01, "segments snapped to 5")
  T.step(1)
  check(#T.errors == 0, "no errors: " .. tostring(T.errors[1]))
`);

scenario('one-bar layout: the next segment fills while running, the top one drains red when standing', NS + `
  T.login()
  check(ns.db.layout == "two" and D.tick.shown, "two bars by default")
  T.slash("layout")
  check(ns.db.layout == "one" and not D.tick.shown, "one bar: the cast bar is hidden")
  T.aura = 6 T.speed = 7.42
  T.step(0.3)
  T.aura = 7 T.step(0.1)
  check(math.abs(v.shown - 7) < 0.01, "a single gain snaps (the segment had filled): " .. v.shown)
  T.step(2.5)
  check(D.stack.Seg.shown and D.stack.Seg.atlas == "Cast_Channel_WispGlow", "green segment while earning")
  check(D.stack.Spark.shown, "spark at its edge")
  local w = D.stack.Clip.width
  check(w > 441 * 7 / 30 + 1 and w < 441 * 8 / 30, "the fill runs into the 8th segment: " .. w)
  check(D.stack.Timer.text:find("+1"), "countdown in the bar: " .. tostring(D.stack.Timer.text))
  T.speed = 0
  T.step(0.8)
  check(D.stack.Seg.atlas == "ui-castingbar-interrupted", "red segment while standing: " .. tostring(D.stack.Seg.atlas))
  local w2 = D.stack.Clip.width
  check(w2 < 441 * 7 / 30 and w2 > 441 * 6 / 30, "the 7th segment is draining: " .. w2)
  check(D.stack.Timer.text:find("-1"), "loss countdown: " .. tostring(D.stack.Timer.text))
  T.slash("layout")
  check(ns.db.layout == "two" and D.tick.shown and not D.stack.Seg.shown, "back to two bars")
  check(#T.errors == 0, "no errors: " .. tostring(T.errors[1]))
`);

scenario('fade out at 0 stacks: gone while standing empty, back when moving', NS + `
  T.login()
  T.aura = nil T.speed = 0
  T.step(1.5)
  check(math.abs(D.frame.alpha - 0.45) < 0.01, "dimmed by default: " .. D.frame.alpha)
  T.slash("fade")
  T.step(0.15)
  check(D.frame.alpha > 0.01 and D.frame.alpha < 0.45, "fading: " .. D.frame.alpha)
  T.step(1)
  check(D.frame.alpha == 0, "faded right out: " .. D.frame.alpha)
  T.speed = 7
  T.step(0.2)
  check(D.frame.alpha == 1, "back when moving: " .. D.frame.alpha)
  T.speed = 0 T.step(1.5)
  T.slash("unlock") T.step(0.5)
  check(D.frame.alpha == 0.5, "never hidden while unlocked: " .. D.frame.alpha)
`);

scenario('bar texture choice: every profession fill, flare and flipbook rows', NS + `
  T.login()
  check(D.stack.Fill.atlas == "skillbar_fill_flipbook_herbalism", "herbalism by default")
  T.slash("fill leather")
  check(ns.db.fill == "leatherworking" and D.stack.Fill.atlas == "skillbar_fill_flipbook_leatherworking", "leatherworking: " .. tostring(D.stack.Fill.atlas))
  check(D.stack.Flare.atlas == "skillbar_flare_leatherworking", "its flare")
  T.slash("fill jewel")
  local rows
  for _, a in ipairs(D.stack.FillAnim.anims) do rows = a.calls.SetFlipBookRows end
  check(ns.db.fill == "jewelcrafting", "jewelcrafting")
  T.slash("fill")
  check(ns.db.fill == "cooking", "fill with no name steps to the next: " .. ns.db.fill)
  T.aura = 5 T.speed = 7.35 T.step(0.5)
  check(D.stack.FillAnim.playing, "the new fill flows while running")
  check(#T.errors == 0, "no errors: " .. tostring(T.errors[1]))
`);

scenario('hit marker at half the stacks, tooltip on hover, clicks pass through when locked', NS + `
  T.login()
  T.aura = 13 T.speed = 7.91 T.step(0.5)
  check(D.stack.HitMark.shown, "hit marker shown")
  local p = D.stack.HitMark.points[1]
  check(p and math.abs(p[4] - 441 * 6 / 30) < 0.01, "at 6 (half of 13, rounded down): " .. tostring(p and p[4]))
  T.slash("marker") T.step(0.1)
  check(not D.stack.HitMark.shown, "marker off")
  check(D.frame.motion == true and D.frame.clicks == false, "locked: hover works, clicks pass through")
  D.frame.scripts.OnEnter(D.frame)
  check(T.tipHas("13 / 30 stacks") and T.tipHas("Next stack"), "tooltip: stacks and countdown")
  check(T.tipHas("would leave you about 6"), "tooltip: what a hit leaves")
  D.frame.scripts.OnLeave(D.frame)
  T.slash("tooltip")
  check(D.frame.motion == false, "tooltip off: no hover either")
`);

scenario('dock under the player frame, then back where it was', NS + `
  T.login()
  T.slash("dock")
  local p = D.frame.points[1]
  check(p and p[2] == PlayerFrame and p[1] == "TOP", "anchored under the player frame")
  check(math.abs(D.frame.calls.SetScale and 0 or 0) == 0, "scaled")
  check(D.frame.mouse == false, "not draggable while docked")
  T.slash("dock")
  p = D.frame.points[1]
  check(p and p[2] == UIParent and p[5] == 260, "back at its own spot")
`);

scenario('the log: recent stack changes, each hit compared with half', NS + `
  T.login()
  T.aura = 10 T.speed = 7.7 T.step(0.3)
  T.aura = 11 T.step(0.1)
  T.aura = 5 T.step(0.1)
  T.prints = {}
  T.slash("log")
  check(T.printed("last 2 stack changes"), "header")
  check(T.printed("10 %-> 11 gain"), "the gain")
  check(T.printed("11 %-> 5 hit %(moving%), exactly half"), "the hit, halved")
`);

scenario('moving from IsPlayerMoving when the speed cannot be read', NS + `
  T.login()
  T.aura = 4 T.speedMode = "secret"
  T.isPlayerMoving = true
  T.step(0.3)
  check(st.moving, "moving from IsPlayerMoving")
  T.isPlayerMoving = false
  T.step(0.6)
  check(not st.moving, "stopped")
`);

scenario('hide in combat can be turned off: the bar stays, frozen and marked', NS + `
  T.login()
  T.aura = 9 T.speed = 7.6 T.step(0.3)
  T.slash("combat")
  check(ns.db.hideInCombat == false, "option off")
  T.auraMode = "hidden"
  T.enterCombat()
  check(D.frame.shown, "still shown in combat")
  T.step(1)
  check(st.stacks == 9, "frozen at 9")
  check(D.tick.Text.text == "In combat", "cast bar says In combat: " .. tostring(D.tick.Text.text))
  T.auraMode = "plain" T.aura = 4
  T.leaveCombat()
  check(st.stacks == 4, "re-read after the fight")
  T.slash("combat")
  T.enterCombat()
  check(not D.frame.shown, "hidden again with the option on")
`);

scenario('reaching 30: starburst and sheen, the cast bar shows full', NS + `
  T.login()
  T.aura = 29 T.speed = 9
  T.step(0.3)
  T.aura = 30 T.step(0.1)
  check(D.stack.MaxAnim.plays == 1 and D.stack.SheenAnim.plays == 1, "max effects")
  T.step(0.2)
  check(D.tick.barTexture == "ui-castingbar-full-channel", "full art: " .. tostring(D.tick.barTexture))
  check(D.tick.Text.text == "Full speed", "full text")
`);

scenario('without the cast bar template a look-alike is built', NS + `
  T.templates.CastingBarFrameTemplate = nil
  T.login()
  check(D.tick.fallback, "fallback bar")
  T.aura = 5 T.speed = 7.35
  T.step(0.5)
  T.aura = 2 T.step(0.1)
  T.step(1)
  check(#T.errors == 0, "no errors: " .. tostring(T.errors[1]))
`);

scenario('wind streaks race through the fill while running, more with more stacks', NS + `
  T.login()
  T.aura = 3 T.speed = 7.2
  T.step(2)
  local function lit() local n = 0 for _, t in ipairs(D.stack.Streaks) do if t.alpha > 0 then n = n + 1 end end return n end
  local few = lit()
  check(few >= 1, "some streaks at 3 stacks: " .. few)
  T.aura = 30 T.step(3)
  check(lit() > few, "more streaks at 30: " .. lit())
  for _, t in ipairs(D.stack.Streaks) do
    if t.alpha > 0 then check(t.x <= 441 + 0.01, "a streak stays inside the fill") end
  end
  T.speed = 0 T.step(3)
  check(lit() == 0, "none while standing: " .. lit())
`);

scenario('options page in Options > AddOns, the window in combat, and the minimap button', NS + `
  T.login()
  check(T.settings.name == "Plainstride" and T.settings.category, "canvas page registered")
  local mm = _G.PlainstrideMinimapButton
  check(mm and mm.shown, "minimap button")
  mm:Click("LeftButton")
  check(SettingsPanel.shown and T.settings.page:IsVisible(), "left-click opens Options > AddOns > Plainstride")
  mm:Click("LeftButton")
  check(not SettingsPanel.shown, "a second click closes it")
  T.combat = true
  mm:Click("LeftButton")
  check(_G.PlainstrideOptions and _G.PlainstrideOptions.shown, "in combat the window opens instead")
  mm:Click("LeftButton")
  check(not _G.PlainstrideOptions.shown, "and closes")
  T.combat = false
  mm:Click("LeftButton")
  check(SettingsPanel.shown, "out of combat the page is used again")
  local locked = ns.db.locked
  mm:Click("RightButton")
  check(ns.db.locked ~= locked, "right-click toggles the lock")
  T.slash("minimap")
  check(not mm.shown and not ns.db.minimap, "/plainstride minimap hides it")
  check(#T.errors == 0, "no errors: " .. tostring(T.errors[1]))
`);

scenario('an unmoved 0.1.0 bar moves up off the action bars', NS + `
  PlainstrideDB = { point = { "BOTTOM", "UIParent", "BOTTOM", 0, 190 }, portrait = "model" }
  T.login()
  check(ns.db.point[5] == 260, "moved up: " .. tostring(ns.db.point[5]))
  check(ns.db.portrait == nil, "old portrait setting dropped")
`);

scenario('the demo plays through and ends', NS + `
  T.race = "Orc"
  T.login()
  T.slash("demo")
  check(D.frame.shown, "shown for the demo")
  T.step(20)
  check(st.source == "demo", "demo source")
  T.step(30)
  check(st.demo == nil, "demo ended")
  check(not D.frame.shown, "hidden again for a non-tauren")
  check(D.Shake.plays >= 2, "the demo hits shook the bar")
  check(D.stack.MaxAnim.plays >= 1, "the demo reached 30")
  check(#T.errors == 0, "no errors: " .. tostring(T.errors[1]))
`);

scenario('slash commands', NS + `
  T.login()
  for _, c in ipairs({ "", "unlock", "lock", "scale 1.2", "scale 9", "idle 0.3", "timer", "timer", "minimap", "minimap", "layout", "layout", "count", "fade", "fade", "fill", "marker", "marker", "tooltip", "tooltip", "dock", "dock", "log", "combat", "combat", "help", "reset", "debug" }) do
    T.slash(c)
  end
  T.slash("background 0.3")
  check(math.abs(D.stack.Background.alpha - 0.3) < 0.001 and math.abs(D.tick.Background.alpha - 0.3) < 0.001, "background opacity on both bars: " .. tostring(D.stack.Background.alpha))
  T.slash("reset")
  check(D.stack.Background.alpha == 1, "reset brings the background back")
  check(ns.db.scale == 0.75, "reset scale")
  check(ns.db.showCount == true, "reset brings the count back")
  T.slash("count")
  T.step(0.1)
  check(ns.db.showCount == false and D.stack.Text.text == "", "count text off: " .. tostring(D.stack.Text.text))
  T.slash("count")
  T.step(0.1)
  check(D.stack.Text.text:find("Plainsrunning"), "count text on")
  check(ns.db.locked, "locked")
  check(T.printed("aura:"), "debug printed")
  check(#T.errors == 0, "no errors: " .. tostring(T.errors[1]))
`);

console.log(`\nRESULT pass=${passed} fail=${failed} checks=${checks}`);
process.exitCode = failed ? 1 : 0;
