// Offline checks for Plainstride: loads every file in the TOC into fengari (Lua 5.3)
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
const ADDON_FILES = ['Plainstride.lua', 'Display.lua', 'Options.lua', 'Styles.lua', 'Plainstride_Skins.lua'];
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
GameFontHighlight = { font = "GameFontHighlight" }
GameFontNormal = { font = "GameFontNormal" }
GameFontDisable = { font = "GameFontDisable" }

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
    points = {}, level = (parent and rawget(parent, "level") or 0) + 1, events = {}, kids = {} }, Widget)
  T.frames[#T.frames + 1] = w
  if parent then table.insert(rawget(parent, "kids"), w) end
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
function Widget:SetAtlas(a, use) self.atlas = a self.texture = nil return true end
function Widget:SetTexture(t) self.texture = t end
function Widget:SetVertexColor(r, g, b) self.vertex = { r, g, b } end
function Widget:SetStatusBarColor(r, g, b) self.barColor = { r, g, b } end
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
-- what Styles.lua asks of a frame: its regions and children, and a few setters it records
local REGION = { Texture = true, FontString = true, MaskTexture = true }
function Widget:GetRegions() local out = {} for _, k in ipairs(self.kids) do if k.kind == "Texture" or k.kind == "FontString" then out[#out + 1] = k end end return table.unpack(out) end
function Widget:GetChildren() local out = {} for _, k in ipairs(self.kids) do if not REGION[k.kind] and not k.kind:find("^Animation") then out[#out + 1] = k end end return table.unpack(out) end
function Widget:IsObjectType(t) return self.kind == t end
function Widget:HookScript(n, f) local old = self.scripts[n] self.scripts[n] = function(...) if old then old(...) end f(...) end end
function Widget:SetEnabled(v) self.enabled = not not v end
function Widget:IsEnabled() return self.enabled ~= false end
function Widget:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
function Widget:SetTexCoord(...) self.texcoord = { ... } end
function Widget:SetRotation(r) self.rotation = r end
function Widget:GetNumMaskTextures() return 0 end
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
-- In combat the game refuses HideUIPanel from an addon
function HideUIPanel(f) if T.combat then T.hideRefused = (T.hideRefused or 0) + 1 return end f.shown = false end
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
  if template == "ButtonFrameTemplate" then
    -- its X, as UIPanelCloseButton wires it: HideUIPanel on the parent
    f.CloseButton = widget("Button", f)
    f.CloseButton.scripts.OnClick = function() HideUIPanel(f) end
  end
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
function scenario(name, body, pre) {
  HITS = new Map(); SEEN = new Map();
  const S = newState();
  const preErr = pre ? exec(S, pre, '=pre') : null;
  const loadErr = preErr ? 'pre: ' + preErr : loadAddon(S);
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
  check(D.loss.barTexture == "ui-castingbar-filling-standard" and D.loss.alpha > 0, "the loss bar shows, gold while you stand: " .. tostring(D.loss.barTexture))
  check(D.tick.barTexture == "ui-castingbar-filling-channel", "the gain bar stays the gain bar: " .. tostring(D.tick.barTexture))
  check(not D.stack.FillAnim.playing, "the fill rests while standing")
  T.step(0.9)
  check(D.loss.barTexture == "ui-castingbar-interrupted", "red once a check has caught you: " .. tostring(D.loss.barTexture))
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
  check(D.stack.LossSeg.shown and D.stack.LossSeg.atlas == "ui-castingbar-interrupted", "the coming loss: red over the top stack: " .. tostring(D.stack.LossSeg.atlas))
  local w2 = D.stack.LossSeg.width
  check(w2 and w2 > 0 and w2 <= 441 / 30 + 0.01, "it drains within the top stack: " .. tostring(w2))
  check(D.stack.Clip.width >= 441 * 7 / 30 - 0.01, "the stacks themselves stay full until the loss lands")
  check(D.stack.Timer.text:find("-1"), "loss countdown: " .. tostring(D.stack.Timer.text))
  T.slash("layout")
  check(ns.db.layout == "two" and D.tick.shown and not D.stack.Seg.shown and not D.stack.LossSeg.shown, "back to two bars")
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
  local function xs() local o = {} for i, t in ipairs(D.stack.Streaks) do o[i] = t.x end return o end
  local before = xs() T.step(0.05)
  local after, right = xs(), 0
  for i = 1, #after do if after[i] > before[i] then right = right + 1 end end
  check(ns.db.streakDir == "right" and right >= 3, "they move right by default: " .. right)
  T.slash("streaks left")
  T.step(0.05) before = xs() T.step(0.05) after = xs()
  local left = 0
  for i = 1, #after do if after[i] < before[i] then left = left + 1 end end
  check(ns.db.streakDir == "left" and left >= 3, "and left when asked: " .. left)
  T.slash("streaks right")
  T.step(3)
  for _, t in ipairs(D.stack.Streaks) do
    if t.alpha > 0 then check(t.x <= 441 + 0.01, "a rightward streak stays inside the fill") end
  end
  T.slash("streaks")
  T.step(0.05)
  check(ns.db.streaks == false and lit() == 0, "switched off: none at once: " .. lit())
  T.slash("streaks")
  T.step(1)
  check(lit() > 0, "back on")
  T.speed = 0 T.step(3)
  check(lit() == 0, "none while standing: " .. lit())
`);

scenario('options page in Options > AddOns, the window in combat, and the minimap button', NS + `
  T.login()
  check(T.settings.name == "Plainstride" and T.settings.category, "canvas page registered")
  check(not T.settings.page.shown, "the page waits hidden, so the panel showing it runs OnShow on the first visit too")
  local mm = _G.PlainstrideMinimapButton
  check(mm and mm.shown, "minimap button")
  mm:Click("LeftButton")
  check(SettingsPanel.shown and T.settings.page:IsVisible(), "left-click opens Options > AddOns > Plainstride")
  mm:Click("LeftButton")
  check(not SettingsPanel.shown, "a second click closes it")
  T.combat = true
  mm:Click("LeftButton")
  check(_G.PlainstrideOptions and _G.PlainstrideOptions.shown, "in combat the window opens instead")
  _G.PlainstrideOptions.CloseButton:Click()
  check(not _G.PlainstrideOptions.shown and not T.hideRefused, "its X closes it in combat, without HideUIPanel")
  mm:Click("LeftButton")
  check(_G.PlainstrideOptions.shown, "and it opens again")
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
  PlainstrideDB = { point = { "BOTTOM", "UIParent", "BOTTOM", 0, 190 }, portrait = "model", streakDir = "left" }
  T.login()
  check(ns.db.streakDir == "right", "streaks moved to the new default once")
  T.slash("streaks left")
  T.fire("ADDON_LOADED", "Plainstride")
  check(ns.db.streakDir == "left", "a later choice of left is kept")
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
  for _, c in ipairs({ "", "unlock", "lock", "scale 1.2", "scale 9", "idle 0.3", "timer", "timer", "minimap", "minimap", "layout", "layout", "count", "fade", "fade", "fill", "marker", "marker", "tooltip", "tooltip", "dock", "dock", "log", "combat", "combat", "streaks", "streaks", "help", "reset", "debug" }) do
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

// ---------------------------------------------------------------------------------------------
// Window styles (Styles.lua + Plainstride_Skins.lua)
const STYLE = NS + `
  function T.find(pat) for _, w in ipairs(T.frames) do if type(w.text) == "string" and w.text:find(pat) then return w end end end
  function T.opacity() for _, w in ipairs(T.frames) do if w.kind == "Slider" and w.caption and w.caption.text == "Dark background opacity" then return w end end end
  function T.skinErrors() local n = 0 for k in pairs(ns.report) do if k:find("skin error") then n = n + 1 T.errors[#T.errors + 1] = k .. ": " .. tostring(ns.report[k]) end end return n end
  function T.count(w, kind) local n = 0 for _, k in ipairs(w.kids) do if k.kind == kind then n = n + 1 end end return n end
`;

scenario('window styles: Blizzard draws nothing; the Look options; Dark drawn at once from there', STYLE + `
  T.login()
  check(ns.db.style == "auto" and ns.db.darkAlpha == 0.92, "defaults auto and 0.92")
  check(ns.Styles.S == nil, "no drawing calls in use")
  check(ns.report.skin == "Blizzard (EllesmereUI is not loaded)", "status: " .. tostring(ns.report.skin))
  check(D.stack.Border.alpha == 1 and D.stack.Background.atlas == "Professions-skillbar-bg" and D.stack.Background.color == nil, "the profession bar as it was")
  check(D.tick.Border.alpha == 1 and D.stack.psEdge == nil, "the cast bar as it was, no edge")
  _G.PlainstrideMinimapButton:Click("LeftButton")
  local btn, slider = T.find("^Window style"), T.opacity()
  check(btn and btn.text == "Window style: Automatic", "Look: the style button: " .. tostring(btn and btn.text))
  check(T.find("^In use: Blizzard %(EllesmereUI is not loaded%)%.") ~= nil, "Look: the note line")
  check(slider and slider.enabled == false and slider.holder.alpha == 0.5 and slider.caption.font == GameFontDisable, "opacity slider grayed while Automatic")
  btn:Click("LeftButton")
  check(ns.db.style == "blizzard" and btn.text == "Window style: Blizzard", "left-click: Blizzard")
  btn:Click("LeftButton")
  check(ns.db.style == "dark" and ns.Styles.S == ns.Styles.Dark and ns.report.skin == "Dark", "left-click: Dark, drawn at once: " .. tostring(ns.report.skin))
  check(D.stack.Border.alpha == 0 and D.stack.psEdge ~= nil, "the bar flattened at once")
  check(not (_G.PlainstrideReloadPrompt and _G.PlainstrideReloadPrompt.shown), "no reload prompt from Blizzard to Dark")
  check(slider.enabled == true and slider.holder.alpha == 1, "opacity slider live for Dark")
  check(T.count(btn, "Texture") == 0, "page controls untouched")
  btn:Click("RightButton")
  check(ns.db.style == "blizzard" and _G.PlainstrideReloadPrompt and _G.PlainstrideReloadPrompt.shown, "reload prompt leaving Dark")
  check(slider.enabled == false and slider.holder.alpha == 0.5, "opacity slider grayed again")
  check(T.skinErrors() == 0 and #T.errors == 0, "no errors: " .. tostring(T.errors[1]))
`);

scenario('window styles: Dark flattens the bar, keeps what moves, and draws the combat window', STYLE + `
  PlainstrideDB = { style = "dark" }
  T.login()
  check(ns.report.skin == "Dark", "status: " .. tostring(ns.report.skin))
  local s = D.stack
  check(s.Border.alpha == 0, "the profession frame faded")
  check(s.Background.color and s.Background.color[4] == 0.85, "a dark track")
  check(#s.Background.points == 0 and s.Background.calls.SetAllPoints == 1, "the track covers just the band")
  check(s.psEdge and T.count(s.psEdge, "Texture") == 4, "a 1px edge round the band (4 lines)")
  local e = s.psEdge.points[1]
  check(e and e[2] == s.FillArea and e[4] == -1 and e[5] == 1, "the edge sits one unit outside the band")
  check(s.Dividers[5].color and s.Dividers[5].color[4] == 0.9 and s.Dividers[1].color[4] == 0.5, "stack marks: dark lines, darker every fifth")
  check(D.tick.Border.alpha == 0 and D.tick.Background.color ~= nil and D.tick.psEdge ~= nil, "the cast bar: frame faded, track, edge")
  check(D.loss.Border.alpha == 0 and D.loss.Background.color ~= nil and D.loss.psEdge ~= nil, "the loss bar flattened too")
  check(D.tick.psMarks[1].color and D.tick.psMarks[1].color[1] == 0, "the gain bar's part marks: thin dark lines")
  T.slash("background 0.3")
  check(math.abs(s.Background.alpha - 0.3) < 0.001 and math.abs(D.tick.Background.alpha - 0.3) < 0.001, "the Background opacity option still works")
  T.slash("background 1")
  -- what moves is untouched
  check(s.Fill.atlas == "skillbar_fill_flipbook_herbalism" and s.HitMark.alpha == 0.85, "the fill and the hit marker keep their art")
  T.aura = 6 T.speed = 7.42 T.step(1)
  check(s.FillAnim.playing and D.tick.barTexture == "ui-castingbar-filling-channel", "fill flows, cast bar fill as before")
  T.aura = 3 T.step(0.1)
  check(D.Shake.plays == 1 and v.ghost ~= nil, "a hit still shakes and leaves a ghost")
  -- the options window, used in combat
  T.combat = true
  _G.PlainstrideMinimapButton:Click("LeftButton")
  local win = _G.PlainstrideOptions
  check(win and win.shown, "the window opens in combat")
  win.scripts.OnShow(win) -- the stub does not run OnShow by itself
  check(T.count(win, "Texture") >= 11, "window drew backdrop, title strip, rule and edges: " .. T.count(win, "Texture"))
  local close = win.CloseButton or win.psClose
  check(close and T.count(close, "Texture") == 2, "the close X drawn")
  local top = 0
  for _, k in ipairs({ win:GetChildren() }) do if k ~= close then top = math.max(top, k.level) end end
  check(close.level > top, "the close button above everything in the window")
  local btn, slider = T.find("^Window style"), T.opacity()
  check(btn and T.count(btn, "Texture") == 0, "the controls inside stay as they are")
  check(slider.enabled == true and slider.holder.alpha == 1, "opacity slider live")
  local backdrop
  for _, k in ipairs(win.kids) do if k.color and k.color[4] == 0.92 then backdrop = k end end
  check(backdrop ~= nil, "the backdrop at the saved opacity")
  slider.scripts.OnValueChanged(slider, 61)
  check(ns.db.darkAlpha == 0.6 and backdrop.color[4] == 0.6, "the slider sets 60% in steps of 5, live: " .. tostring(ns.db.darkAlpha))
  btn:Click("LeftButton")
  local prompt = _G.PlainstrideReloadPrompt
  check(ns.db.style == "auto" and prompt and prompt.shown, "reload prompt leaving Dark")
  check(ns.report.skin:find("Blizzard after a /reload", 1, true), "status says a reload is due: " .. ns.report.skin)
  check(slider.enabled == false and slider.holder.alpha == 0.5, "opacity slider grayed for Automatic")
  check(T.count(prompt, "Texture") >= 11, "the prompt drawn in Dark too")
  RELOADED = false C_UI = { Reload = function() RELOADED = true end }
  prompt.reload:Click()
  check(RELOADED, "Reload now reloads")
  btn:Click("RightButton")
  check(ns.db.style == "dark" and not prompt.shown and ns.report.skin == "Dark", "back to Dark: prompt gone")
  T.combat = false
  T.prints = {}
  T.slash("style blizzard")
  check(ns.db.style == "blizzard" and T.printed("window style: Blizzard"), "/plainstride style blizzard")
  T.slash("style auto")
  check(ns.db.style == "auto", "/plainstride style auto")
  T.slash("style purple")
  check(ns.db.style == "auto" and T.printed("styles: auto, blizzard, dark"), "a wrong word is refused")
  T.slash("debug")
  check(T.printed("skin: "), "debug shows the skin line")
  check(T.skinErrors() == 0 and #T.errors == 0, "no errors: " .. tostring(T.errors[1]))
`);

scenario('window styles: EllesmereUI (a stand-in that records each call)', STYLE + `
  T.fire("ADDON_LOADED", "Plainstride")
  EUI_FN(EUI_S) -- EllesmereUI calls back at login
  T.fire("PLAYER_ENTERING_WORLD")
  local function did(w, what) return w ~= nil and (EUIDONE[w] or ""):find(what, 1, true) ~= nil end
  check(EUI_REG == "Plainstride", "registered under the folder name: " .. tostring(EUI_REG))
  check(ns.report.skin == "EllesmereUI (eui style)", "status: " .. tostring(ns.report.skin))
  check(D.stack.Fill.vertex and D.stack.Fill.vertex[1] == 0.2 and D.stack.Fill.vertex[3] == 0.9, "saved flat bars take EllesmereUI's accent once it is drawn")
  check(did(D.stack.psEdge, "Panel") and did(D.tick.psEdge, "Panel") and did(D.loss.psEdge, "Panel"), "edges drawn by EllesmereUI, on all three bars")
  check(did(D.stack.Text, "Font") and did(D.stack.Timer, "Font") and did(D.tick.Text, "Font"), "bar text in EllesmereUI's font")
  check(D.stack.Border.alpha == 0 and D.stack.Background.color[1] == 0.1, "track in EllesmereUI's panel color")
  EUI_COLOR = { 0.3, 0.2, 0.1 }
  for _, fn in ipairs(EUI_LOOKS) do fn() end
  check(D.stack.Background.color[1] == 0.3 and D.tick.Background.color[1] == 0.3, "the track follows a live color change")
  T.combat = true
  _G.PlainstrideMinimapButton:Click("LeftButton")
  local win = _G.PlainstrideOptions
  win.scripts.OnShow(win)
  check(did(win, "Shell") and did(win.CloseButton or win.psClose, "CloseButton"), "window shelled, close button")
  local border
  for _, k in ipairs({ win:GetChildren() }) do if k.euiBorder then border = k end end
  check(border and (win.CloseButton or win.psClose).level > border.level, "close button above EllesmereUI's border frame")
  check(T.find("^Window style") and not did(T.find("^Window style"), "Button"), "the controls inside stay as they are")
  check(T.skinErrors() == 0 and #T.errors == 0, "no errors: " .. tostring(T.errors[1]))
`, `
  EUIDONE = {} EUI_LOOKS = {} EUI_COLOR = { 0.1, 0.1, 0.1 }
  PlainstrideDB = { flatBar = true }
  local function rec(n) return function(f) if f then EUIDONE[f] = (EUIDONE[f] or "") .. n .. "," end return true end end
  EUI_S = { GetStyle = function() return "eui" end, GetPanelColor = function() return EUI_COLOR[1], EUI_COLOR[2], EUI_COLOR[3], 0.9 end,
    OnLooksChanged = function(fn) EUI_LOOKS[#EUI_LOOKS + 1] = fn end, GetAccentColor = function() return 0.2, 0.4, 0.9 end }
  for _, n in ipairs({ "Panel", "Inset", "FadeRegions", "Button", "WhiteButtonLabel", "CloseButton", "SquareIcon", "Font" }) do EUI_S[n] = rec(n) end
  EUI_S.Shell = function(f) rec("Shell")(f) local b = CreateFrame("Frame", nil, f) b:SetFrameLevel(f:GetFrameLevel() + 6) b.euiBorder = true end
  EllesmereUI = { RegisterSkin = function(name, fn) EUI_REG = name EUI_FN = fn end, _DispatchSkinRegistration = function() end }
`);


scenario('dock under EllesmereUI\'s player frame while it is shown, the game\'s otherwise', STYLE + `
  T.login()
  local eui = CreateFrame("Button", "EllesmereUIUnitFrames_Player", UIParent)
  eui:SetSize(260, 60)
  T.prints = {}
  T.slash("dock")
  local p = D.frame.points[1]
  check(p and p[2] == eui and p[1] == "TOP", "docked under EllesmereUI's player frame: " .. tostring(p and p[2] == PlayerFrame and "PlayerFrame" or p and p[2]))
  check(T.printed("docked under EllesmereUI's player frame"), "and says so")
  eui:Hide() T.step(0.05)
  p = D.frame.points[1]
  check(p and p[2] == PlayerFrame, "its frame hidden: back under the game's player frame")
  eui:Show() T.step(0.05)
  p = D.frame.points[1]
  check(p and p[2] == eui, "shown again: under it again")
  T.slash("dock")
  p = D.frame.points[1]
  check(p and p[2] == UIParent and p[5] == 260, "undocked: back at its own spot")
  check(#T.errors == 0, "no errors: " .. tostring(T.errors[1]))
`);

scenario('an EllesmereUI player frame made after login is found', STYLE + `
  T.login()
  T.slash("dock")
  check(D.frame.points[1][2] == PlayerFrame, "at first under the game's frame")
  local eui = CreateFrame("Button", "EllesmereUIUnitFrames_Player", UIParent)
  eui:SetSize(260, 60)
  T.step(0.05)
  check(D.frame.points[1][2] == eui, "moved under EllesmereUI's frame once it is there")
`);

scenario('flat bars: plain colors in any style, everything still moves', STYLE + `
  T.login()
  local FLAT = "Interface\\\\Buttons\\\\WHITE8X8"
  check(ns.db.flatBar == false, "off by default")
  check(D.stack.Fill.texture == nil and D.stack.Fill.atlas == "skillbar_fill_flipbook_herbalism", "the profession art by default")
  T.slash("flat")
  local s = D.stack
  check(ns.db.flatBar and s.Fill.texture == FLAT, "a flat fill")
  check(s.Fill.vertex and math.abs(s.Fill.vertex[1] - 0.56) < 0.001, "in the green of Next stack (no window style drawn)")
  T.aura = 5 T.speed = 7.35 T.step(0.5)
  check(D.tick.barTexture == FLAT and D.tick.barColor and D.tick.barColor[2] == 0.78, "the cast bar flat green while gaining")
  check(not s.FillAnim.playing, "the flipbook rests: nothing to turn on a flat fill")
  T.aura = 6 T.step(0.1)
  check(s.FlareFadeOut.plays >= 1 and D.tick.ChannelFinish.plays >= 1, "a gain still flares and finishes the cast bar")
  T.step(0.6)
  check(math.abs(s.Clip.width - 441 * 6 / 30) < 0.01, "the fill eases to 6 stacks: " .. tostring(s.Clip.width))
  T.step(1.5)
  local lit = 0 for _, t in ipairs(s.Streaks) do if t.alpha > 0 then lit = lit + 1 end end
  check(lit >= 1, "wind streaks still race through it: " .. lit)
  -- Standing still: the loss bar comes up gold, turns red, blended frame by frame; the gain bar stays green.
  local seen, gainGreen = {}, true
  T.speed = 0
  for i = 1, 100 do
    T.step(0.02)
    local _, l = ns.gainLoss(T.now, st.stacks)
    local c = D.loss.barColor
    if l and c then seen[#seen + 1] = { c[1], c[2], c[3], left = l.left } end
    local gcol = D.tick.barColor
    if not (gcol and gcol[2] == 0.78) then gainGreen = false end
  end
  local function near(c, r, g) return math.abs(c[1] - r) < 0.05 and math.abs(c[2] - g) < 0.05 end
  local goldAt, redAt, goldToRed
  for i, c in ipairs(seen) do
    if not goldAt and near(c, 1, 0.7) then goldAt = i end
    if goldAt and not redAt and near(c, 0.85, 0.12) then redAt = i end
    -- between gold (1, 0.7) and red (0.85, 0.12): green part strictly between
    if goldAt and not redAt and c[2] > 0.2 and c[2] < 0.6 then goldToRed = true end
  end
  check(goldAt ~= nil, "gold while you stand")
  check(redAt ~= nil, "red in the last moment")
  check(goldToRed, "gold blends into red over the last stretch")
  check(gainGreen, "the gain bar stays flat green meanwhile")
  local mid
  for _, c in ipairs(seen) do if c.left and c.left > 0.4 and c.left < 0.5 then mid = c end end
  local want = mid and (0.7 + (0.12 - 0.7) * (1 - mid.left / 0.7))
  check(mid and math.abs(mid[2] - want) < 0.15, "half way through the last stretch the bar is half way to red: " .. tostring(mid and mid[2]) .. " vs " .. tostring(want))
  local biggest = 0
  for i = 2, #seen do
    local d = math.abs(seen[i][1] - seen[i - 1][1]) + math.abs(seen[i][2] - seen[i - 1][2])
    if d > biggest then biggest = d end
  end
  check(biggest < 0.2, "no jump between two frames: " .. biggest)
  T.aura = 2 T.step(0.1)
  check(s.Ghost.color and s.Ghost.color[1] == 0.85, "a hit leaves a flat red ghost")
  check(D.Shake.plays >= 1, "and still shakes")
  T.slash("layout") T.speed = 7.3 T.step(0.6) T.speed = 0 T.step(0.8)
  check(s.LossSeg.color ~= nil and s.LossSeg.vertex and s.LossSeg.vertex[1] == 0.85, "one bar: the coming loss flat red")
  T.slash("layout")
  T.slash("flat")
  check(not ns.db.flatBar and s.Fill.atlas == "skillbar_fill_flipbook_herbalism" and s.Fill.vertex[1] == 1, "off again: the profession art, untinted")
  T.aura = 4 T.speed = 7.3 T.step(1)
  check(D.tick.barTexture == "ui-castingbar-filling-channel", "and the cast bar art again: " .. tostring(D.tick.barTexture))
  -- the option on the page
  _G.PlainstrideMinimapButton:Click("LeftButton")
  local cb for _, w in ipairs(T.frames) do if w.kind == "CheckButton" and w.label and w.label.text == "Flat bars" then cb = w end end
  check(cb ~= nil, "a Flat bars checkbox on the page")
  cb.checked = true cb:Click()
  check(ns.db.flatBar == true and s.Fill.texture == FLAT, "ticking it turns flat bars on")
  check(#T.errors == 0, "no errors: " .. tostring(T.errors[1]))
`);

scenario('flat bars in Dark take its accent; in EllesmereUI its accent', STYLE + `
  PlainstrideDB = { style = "dark", flatBar = true }
  T.login()
  check(D.stack.Fill.texture == "Interface\\\\Buttons\\\\WHITE8X8" and math.abs(D.stack.Fill.vertex[2] - 0.86) < 0.001, "Dark's accent on the flat fill")
  check(D.stack.Border.alpha == 0, "and the flattened frame")
`);

scenario('minimap button: left where a collector puts it, dragged round the rim on the minimap', NS + `
  T.login()
-- A minimap button collector (EllesmereUI's, for one) takes the button off the minimap. Neither a
-- refresh nor a drag tick may put it back on the rim then; on the minimap a drag still moves it.
do
  local mm = _G.PlainstrideMinimapButton
  local function Script(f, e) return f.scripts[e] end
  local holder = CreateFrame("Frame", nil, UIParent)
  local own, setPoint = rawget(mm, "SetPoint"), mm.SetPoint
  local moves, rel = 0, nil
  rawset(mm, "SetPoint", function(self, ...) moves = moves + 1 rel = select(2, ...) return setPoint(self, ...) end)
  local center, escale, cursor = rawget(Minimap, "GetCenter"), rawget(Minimap, "GetEffectiveScale"), GetCursorPosition
  rawset(Minimap, "GetCenter", function() return 500, 500 end)
  rawset(Minimap, "GetEffectiveScale", function() return 1 end)
  GetCursorPosition = function() return 600, 560 end
  -- The game has both: a degree based global atan2 and the radian based math.atan2.
  local atan2Was, mathAtan2Was = atan2, math.atan2
  atan2 = atan2 or function(y, x) return math.deg(math.atan(y, x)) end
  math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
  local function Drag()
    local start, stop = Script(mm, "OnDragStart"), Script(mm, "OnDragStop")
    if not start then return false end
    start(mm)
    local tick = Script(mm, "OnUpdate")
    if tick then tick(mm, 0.02) end
    if stop then stop(mm) end
    return tick ~= nil
  end
  mm:SetParent(holder)
  Drag()
  ns.Options.UpdateMinimapButton()
  check(moves == 0, "minimap: a button a collector (EllesmereUI's) has taken stays where the collector put it")
  mm:SetParent(Minimap)
  local dragged = Drag()
  check(dragged and moves > 0 and rel == Minimap, "minimap: on the minimap a drag still moves it round the rim")
  rawset(mm, "SetPoint", own)
  rawset(Minimap, "GetCenter", center)
  rawset(Minimap, "GetEffectiveScale", escale)
  GetCursorPosition = cursor
  atan2, math.atan2 = atan2Was, mathAtan2Was
end
`);


scenario('the gain and loss bars: their places, the five parts, the loss bar option', NS + `
  T.login()
  local function y(w) local p = w.points[1] return p and p[5] end
  check(y(D.tick) == -33 and y(D.loss) == -48, "the gain bar under the stack bar, the loss bar under the gain bar: " .. tostring(y(D.tick)) .. " " .. tostring(y(D.loss)))
  check(y(D.tick) - 11 > y(D.loss), "they do not overlap")
  check(D.frame.height == 63 and D.frame.height >= -y(D.loss) + 11, "the frame keeps the loss bar's room: " .. tostring(D.frame.height))
  check(D.loss.shown and D.loss.alpha == 0, "the loss bar waits, faded out")
  check(#D.tick.psMarks == 4, "the gain bar in five parts")
  for i, m in ipairs(D.tick.psMarks) do
    local p = m.points[1]
    check(p and math.abs(p[4] - 441 * i / 5) < 0.01, "part mark " .. i .. " at a fifth: " .. tostring(p and p[4]))
  end
  T.slash("lossbar")
  check(ns.db.lossBar == false and not D.loss.shown and D.frame.height == 48, "/plainstride lossbar: no loss bar, the frame closes up")
  T.slash("lossbar")
  check(ns.db.lossBar ~= false and D.loss.shown and D.frame.height == 63, "and back")
  -- the option on the page, under Flat bars, inside the page
  _G.PlainstrideMinimapButton:Click("LeftButton")
  local flatBox, lossBox
  for _, w in ipairs(T.frames) do
    if w.kind == "CheckButton" and w.label and w.label.text == "Flat bars" then flatBox = w end
    if w.kind == "CheckButton" and w.label and w.label.text == "Show the loss bar" then lossBox = w end
  end
  check(lossBox ~= nil and lossBox.checked, "a Show the loss bar checkbox, ticked")
  local fy, ly = flatBox.points[1][3], lossBox.points[1][3]
  check(ly < fy - 26 - 24 and ly - 26 >= -580, "under Flat bars and its note, inside the page: " .. tostring(ly))
  lossBox.checked = false lossBox:Click()
  check(ns.db.lossBar == false and not D.loss.shown, "unticking it hides the loss bar")
  check(#T.errors == 0, "no errors: " .. tostring(T.errors[1]))
`);



// ---------------------------------------------------------------------------------------------
// Replay of the user's recording (2026-10-09, 151.8 s): Plainstride's own moving / standing
// timeline frame by frame, and every real count change read off the stack bar. The movement is
// fed in, the real count follows the recording, and the tick model's predictions are checked
// against the real changes, within a tick.
const REPLAY = `
  RUNS = {
    {"S",0,0.8}, {"M",0.8,26}, {"S",26,26.1}, {"M",26.1,31}, {"S",31,31.1}, {"M",31.1,35.2}, {"S",35.2,35.7}, {"M",35.7,36},
    {"S",36,36.1}, {"M",36.1,36.5}, {"S",36.5,36.8}, {"M",36.8,37.6}, {"S",37.6,38.1}, {"M",38.1,38.9}, {"S",38.9,39.6}, {"M",39.6,40.1},
    {"S",40.1,40.5}, {"M",40.5,41.5}, {"S",41.5,41.8}, {"M",41.8,42.9}, {"S",42.9,43}, {"M",43,44.2}, {"S",44.2,44.5}, {"M",44.5,45},
    {"S",45,45.1}, {"M",45.1,45.5}, {"S",45.5,45.6}, {"M",45.6,46.7}, {"S",46.7,47}, {"M",47,48}, {"S",48,48.4}, {"M",48.4,49.1},
    {"S",49.1,49.5}, {"M",49.5,51}, {"S",51,51.6}, {"M",51.6,53.9}, {"S",53.9,54.1}, {"M",54.1,57}, {"S",57,57.2}, {"M",57.2,62},
    {"S",62,62.1}, {"M",62.1,65.6}, {"S",65.6,66.5}, {"M",66.5,67.6}, {"S",67.6,68}, {"M",68,69.7}, {"S",69.7,69.8}, {"M",69.8,70.9},
    {"S",70.9,71}, {"M",71,71.9}, {"S",71.9,72.1}, {"M",72.1,74.1}, {"S",74.1,74.6}, {"M",74.6,75.5}, {"S",75.5,75.8}, {"M",75.8,76.7},
    {"S",76.7,76.9}, {"M",76.9,78}, {"S",78,78.3}, {"M",78.3,79.8}, {"S",79.8,79.9}, {"M",79.9,80}, {"S",80,80.1}, {"M",80.1,81.1},
    {"S",81.1,81.3}, {"M",81.3,83.4}, {"S",83.4,83.6}, {"M",83.6,85.5}, {"S",85.5,85.8}, {"M",85.8,87.1}, {"S",87.1,87.4}, {"M",87.4,88.2},
    {"S",88.2,88.3}, {"M",88.3,89}, {"S",89,89.4}, {"M",89.4,90}, {"S",90,90.4}, {"M",90.4,91}, {"S",91,91.4}, {"M",91.4,92.2},
    {"S",92.2,92.4}, {"M",92.4,93.3}, {"S",93.3,93.5}, {"M",93.5,94.2}, {"S",94.2,94.5}, {"M",94.5,95.3}, {"S",95.3,95.4}, {"M",95.4,96.5},
    {"S",96.5,96.6}, {"M",96.6,97.5}, {"S",97.5,97.7}, {"M",97.7,98.3}, {"S",98.3,98.5}, {"M",98.5,99.2}, {"S",99.2,99.9}, {"M",99.9,100.6},
    {"S",100.6,101}, {"M",101,101.6}, {"S",101.6,102.4}, {"M",102.4,103.3}, {"S",103.3,103.8}, {"M",103.8,104.7}, {"S",104.7,105.1}, {"M",105.1,105.9},
    {"S",105.9,106.6}, {"M",106.6,107.4}, {"S",107.4,107.9}, {"M",107.9,108.9}, {"S",108.9,109.3}, {"M",109.3,110.2}, {"S",110.2,110.7}, {"M",110.7,111.5},
    {"S",111.5,112}, {"M",112,112.8}, {"S",112.8,113.3}, {"M",113.3,114.1}, {"S",114.1,115.6}, {"M",115.6,116.2}, {"S",116.2,116.8}, {"M",116.8,117.6},
    {"S",117.6,118.4}, {"M",118.4,119}, {"S",119,119.6}, {"M",119.6,120.3}, {"S",120.3,120.9}, {"M",120.9,121.7}, {"S",121.7,122.3}, {"M",122.3,123},
    {"S",123,123.6}, {"M",123.6,124.4}, {"S",124.4,124.8}, {"M",124.8,125.7}, {"S",125.7,126.1}, {"M",126.1,126.9}, {"S",126.9,127.5}, {"M",127.5,128.2},
    {"S",128.2,128.9}, {"M",128.9,129.9}, {"S",129.9,130.3}, {"M",130.3,131.4}, {"S",131.4,131.8}, {"M",131.8,132.7}, {"S",132.7,133.2}, {"M",133.2,134.8},
    {"S",134.8,135.1}, {"M",135.1,136.3}, {"S",136.3,136.6}, {"M",136.6,137.6}, {"S",137.6,138.7}, {"M",138.7,139.6}, {"S",139.6,140.2}, {"M",140.2,141},
    {"S",141,141.4}, {"M",141.4,142.2}, {"S",142.2,142.6}, {"M",142.6,143.4}, {"S",143.4,144.1}, {"M",144.1,145}, {"S",145,145.6}, {"M",145.6,146.6},
    {"S",146.6,147.2}, {"M",147.2,148}, {"S",148,148.9},
  }
  GAINS = { 6.1, 11.1, 16, 21, 26, 31.1, 36, 45, 57.1, 62.1, 72, 80, 85, 90, 97, 102, 133.1, 138.1 }
  LOSSES = { 40, 50, 52, 66.9, 75, 91.9, 102.9, 107, 111, 115, 116, 120, 123.9, 127.9, 138.9, 142, 146, 148.9 }
`;

scenario('replay of the recording: the tick model predicts the real count changes', NS + REPLAY + `
  local BASE = 1000
  T.now = BASE - 1
  T.login()
  -- a stop as Plainstride showed it began 0.3 s after the speed fell (its stop grace); the
  -- one-sample stops at a gain were the gain animation, not stops
  local gainAt = {}
  for _, g in ipairs(GAINS) do gainAt[string.format("%.1f", g)] = true end
  local stops = {}
  for _, r in ipairs(RUNS) do
    if r[1] == "S" and not (r[3] - r[2] <= 0.11 and gainAt[string.format("%.1f", r[2])]) then
      stops[#stops + 1] = { r[2] - 0.3, r[3] }
    end
  end
  local function standing(t) if t < 0 then return true end -- the recording starts standing
    for _, s in ipairs(stops) do if t >= s[1] and t < s[2] then return true end end return false end
  local function countAt(t)
    local n = 0
    for _, g in ipairs(GAINS) do if g <= t then n = n + 1 end end
    for _, l in ipairs(LOSSES) do if l <= t then n = n - 1 end end
    return n
  end
  local predLoss, predGain = {}, {}
  -- the bars against the model, every step: the loss bar up (red) while a check has caught you,
  -- gone when no loss is coming, and the gain bar showing the checks passed, in fifths
  local pendingFor, noLossFor, lossMissing, lossWrong, gainOff, gainSeen, lastStacks, changedAt = 0, 0, 0, 0, 0, 0, nil, 0
  local lastDone, doneAt = 0, 0
  local t = T.now - BASE
  while t < 151.5 do
    T.speed = standing(t) and 0 or 7.5
    local n = countAt(t)
    T.aura = n > 0 and n or nil
    T.step(0.05, 0.025)
    t = T.now - BASE
    if st.pendingLossAt then predLoss[math.floor(st.pendingLossAt - BASE + 0.5)] = true end
    local mode, _, left = ns.clocks(T.now, st.stacks)
    if mode == "gain" and left and left < 0.15 then predGain[math.floor(T.now + left - BASE + 0.5)] = true end
    if st.stacks ~= lastStacks then lastStacks, changedAt = st.stacks, T.now end
    local g, l = ns.gainLoss(T.now, st.stacks)
    pendingFor = st.pendingLossAt and (pendingFor + 0.05) or 0
    if pendingFor >= 0.15 and not (D.loss.alpha > 0.9 and D.loss.barTexture == "ui-castingbar-interrupted") then lossMissing = lossMissing + 1 end
    noLossFor = l and 0 or (noLossFor + 0.05)
    if noLossFor >= 0.4 and D.loss.alpha > 0.01 then lossWrong = lossWrong + 1 end
    if (st.moveChecks or 0) ~= lastDone then lastDone, doneAt = st.moveChecks or 0, T.now end
    -- (the bar eases over a frame or two after a change of count)
    if g.mode == "gain" and T.now - changedAt > 0.2 and T.now - doneAt > 0.1 then
      gainSeen = gainSeen + 1
      local done = st.moveChecks or 0
      if D.tick.value > done / 5 + 0.06 or D.tick.value < (done - 1) / 5 - 0.06 then gainOff = gainOff + 1 end
    end
  end
  local function match(truth, pred)
    local used, hits, missed = {}, 0, {}
    for _, tc in ipairs(truth) do
      local k = math.floor(tc + 0.5)
      local hit
      for _, d in ipairs({ 0, -1, 1 }) do
        if not hit and pred[k + d] and not used[k + d] then hit = k + d end
      end
      if hit then used[hit] = true hits = hits + 1 else missed[#missed + 1] = k end
    end
    local extra = {}
    for k in pairs(pred) do if not used[k] then extra[#extra + 1] = k end end
    table.sort(extra)
    return hits, missed, extra
  end
  local lh, lm, lx = match(LOSSES, predLoss)
  local gh, gm, gx = match(GAINS, predGain)
  REPLAY_RESULT = string.format("losses %d/%d (missed %s; extra %s), gains %d/%d (missed %s; extra %s)",
    lh, #LOSSES, table.concat(lm, " "), table.concat(lx, " "), gh, #GAINS, table.concat(gm, " "), table.concat(gx, " "))
  DEFAULT_CHAT_FRAME:AddMessage("replay: " .. REPLAY_RESULT)
  check(lh >= 17, "losses predicted within a tick: " .. REPLAY_RESULT)
  check(gh >= 16, "gains predicted within a tick: " .. REPLAY_RESULT)
  check(#lx + #gx <= 8, "few predictions that did not happen: " .. REPLAY_RESULT)
  check(lossMissing == 0, "the loss bar is up, red, whenever a check has caught you: " .. lossMissing .. " steps without it")
  check(lossWrong == 0, "and gone when no loss is coming: " .. lossWrong .. " steps with it")
  check(gainSeen > 500 and gainOff == 0, "the gain bar shows the checks passed, in fifths: " .. gainOff .. " of " .. gainSeen .. " steps off")
  check(#T.errors == 0, "no errors: " .. tostring(T.errors[1]))
`);



scenario('stutter step: a step taken after the check does not save the stack, and the bar keeps saying so', NS + `
  T.now = 2000
  T.login()
  T.aura = 6 T.speed = 7.4
  T.step(1.0)
  T.aura = 7 T.step(0.06) -- a real gain: the tick is at about 2001.0
  T.step(0.9)            -- moving through the next check
  local mode = ns.clocks(T.now, st.stacks)
  check(mode == "gain", "moving: next stack: " .. tostring(mode))
  -- stop just before a tick, stand through its check, then step again
  T.speed = 0 T.step(0.4) -- standing from about 2002.3 (0.3 s to notice): too late for the check of 2002
  check(st.pendingLossAt == nil, "stopped after the check: nothing coming yet")
  -- both bars at once: the gain bar keeps the checks passed, the loss bar warns (gold)
  T.step(0.1)
  check(D.tick.value >= 0.19 and D.tick.Text.text:find("Next stack"), "the gain bar keeps its progress through the stop: " .. tostring(D.tick.value))
  check(D.loss.alpha > 0.5 and D.loss.barTexture == "ui-castingbar-filling-standard" and D.loss.Text.text:find("Losing a stack"),
    "and the loss bar warns, gold, under it: " .. tostring(D.loss.alpha) .. " " .. tostring(D.loss.barTexture))
  T.step(0.9)             -- the check of 2003 decided at about 2003.3
  check(st.pendingLossAt ~= nil, "standing through the check: a loss is coming")
  T.speed = 7.4 T.step(0.1)
  local m2, _, left = ns.clocks(T.now, st.stacks)
  check(m2 == "decay" and left and left > 0 and left < 1, "moving again, the bar still counts down to the loss: " .. tostring(m2) .. " " .. tostring(left))
  check(D.loss.alpha > 0.9 and D.loss.barTexture == "ui-castingbar-interrupted" and D.loss.Text.text:find("Losing a stack"), "the loss bar holds, red, while you move")
  check(D.tick.value < 0.25 and D.tick.Text.text:find("Next stack"), "the gain bar started its count again: " .. tostring(D.tick.value))
  T.step(0.48)
  T.aura = 6 T.step(0.06)
  check(ns.db.log[#ns.db.log].kind == "decay", "the loss lands as a decay, not a hit: " .. tostring(ns.db.log[#ns.db.log].kind))
  check(D.Shake.plays == 0, "no shake for it")
  -- the count of checks starts again from the loss: five moving checks for the next stack
  local _, _, gl = ns.clocks(T.now, st.stacks)
  check(gl and gl > 4 and gl <= 5.1, "the next stack is five ticks away: " .. tostring(gl))
  check(#T.errors == 0, "no errors: " .. tostring(T.errors[1]))
`);


scenario('with no stacks, standing through a check starts the count of moving checks again', NS + `
  T.now = 3000
  T.login()
  T.aura = nil T.speed = 7.4
  T.step(3.0)
  check((st.moveChecks or 0) >= 2, "moving checks counted: " .. tostring(st.moveChecks))
  T.speed = 0 T.step(1.6)
  check((st.moveChecks or 0) == 0, "a standing check starts the count again: " .. tostring(st.moveChecks))
  check(#T.errors == 0, "no errors: " .. tostring(T.errors[1]))
`);

console.log(`\nRESULT pass=${passed} fail=${failed} checks=${checks}`);
process.exitCode = failed ? 1 : 0;
