-- Plainstride: the tauren Plainsrunning racial on WoW Forever, as a bar.
--
-- Plainsrunning (passive 1259918, buff 1299038) gives +1% movement speed for every 5 seconds spent
-- moving, up to 30 stacks. Standing still or taking damage takes stacks away. The passive is a
-- periodic aura with a 1 second period (spell data, EffectAuraPeriod 1000), so every change the
-- server makes lands on one shared 1 second beat; we learn where that beat falls from the changes
-- we see.
--
-- The stack count comes from the buff (C_UnitAuras.GetPlayerAuraBySpellID), which the client only
-- shows an addon out of combat. In a fight nothing readable follows the stacks (the run speed was
-- tried and does not update there), so the bar hides when combat starts and reads the buff afresh
-- when it ends.
--
-- Every value from the client is checked with issecretvalue before it is compared, added or
-- truth-tested: on this client that is the one safe thing to do with an unknown value.
local ADDON, ns = ...

local VERSION = "0.1.0"
local BUFF_ID = 1299038
local PASSIVE_ID = 1259918
local MAX_STACKS = 30
local GAIN_TICK = 5         -- seconds of moving per stack (the tooltip's $s2)
local DECAY_TICK = 1        -- the passive's period: one stack per beat while standing
local DECAY_GRACE = 1       -- the first stack goes no sooner than this after you stop
local DECAY_UNKNOWN = 1.5   -- first loss when the beat has not been seen yet (measured 1.45 to 2.07)
local MOVE_GRACE = 0.3      -- a zero speed shorter than this is a strafe or a turn, not a stop
local OVERDUE_HOLD = 0.6    -- a gain that is due but not in yet: hold the bar full this long
local POLL = 0.05           -- how often the client is asked (the drawing runs every frame)
local LOG_MAX = 60

local issecret = issecretvalue or function() return false end

local defaults = {
    locked = true,
    scale = 0.75,
    idleAlpha = 0.45,
    showTimer = true,
    layout = "two",       -- "two": stack bar + cast bar under it; "one": the countdown inside the stack bar
    minimap = true,
    minimapAngle = 220,
    point = { "BOTTOM", "UIParent", "BOTTOM", 0, 260 },
    gainTicks = {},         -- measured seconds between gains, newest last
    decayTicks = {},
    log = {},
    hinted = false,
}

local db
local state = {
    stacks = nil,           -- what we believe now
    source = "none",        -- aura / demo
    moving = false,
    zeroSince = nil,
    startAt = nil,          -- when you last set off
    stopAt = nil,           -- when you last stopped (the moment the speed dropped)
    lastGainAt = nil,
    lastDecayAt = nil,
    eventMoving = false,    -- PLAYER_STARTED/STOPPED_MOVING, for when the speed cannot be read
    beats = {},             -- (time mod 1) of recent changes: where the server's beat falls
    lastPoll = 0,
    demo = nil,
    lastAura = "not asked", lastSpeed = "not asked",
}
ns.state = state

------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function median(list)
    if not list or #list == 0 then return nil end
    local sorted = {}
    for i, v in ipairs(list) do sorted[i] = v end
    table.sort(sorted)
    return sorted[math.ceil(#sorted / 2)]
end

local function push(list, v, max)
    list[#list + 1] = v
    while #list > max do table.remove(list, 1) end
end

local function print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffd9a441Plainstride|r: " .. msg)
end

-- One plain answer from a client function, or nil when it is missing, raised, or secret.
local function ask(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok or issecret(a) or issecret(b) then return nil end
    return a, b
end

local function gainTick()
    if state.demo and state.demo.gap then return state.demo.gap end
    return median(db and db.gainTicks) or GAIN_TICK
end

local function decayTick()
    if state.demo and state.demo.gap then return state.demo.gap end
    return median(db and db.decayTicks) or DECAY_TICK
end

-- Where the server's 1 second beat falls, as a circular mean of recent change times.
local function beatPhase()
    local n = #state.beats
    if n == 0 then return nil end
    local sx, sy = 0, 0
    for _, p in ipairs(state.beats) do
        sx = sx + math.cos(p * 2 * math.pi)
        sy = sy + math.sin(p * 2 * math.pi)
    end
    local a = math.atan2 and math.atan2(sy, sx) or math.atan(sy, sx)
    return (a / (2 * math.pi)) % 1
end

-- The first beat at or after t.
local function snapToBeat(t)
    local phase = beatPhase()
    if not phase then return nil end
    local tick = decayTick()
    local base = math.floor(t / tick) * tick + phase * tick
    while base < t - 1e-6 do base = base + tick end
    while base - tick >= t - 1e-6 do base = base - tick end
    return base
end

------------------------------------------------------------------------
-- Reading the client
------------------------------------------------------------------------
local function inCombat()
    return ask(InCombatLockdown) and true or false
end

local function isTauren()
    local _, token = ask(UnitRace, "player")
    if token == "Tauren" then return true end
    return ask(IsPlayerSpell, PASSIVE_ID) and true or false
end

-- Exact stacks from the aura, 0 when it is plainly not on you, nil when the client will not say.
local function readAura()
    local api = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
    if type(api) ~= "function" then
        state.lastAura = "no C_UnitAuras.GetPlayerAuraBySpellID"
        return nil
    end
    local ok, aura = pcall(api, BUFF_ID)
    if not ok then
        state.lastAura = "raised"
        return nil
    end
    if issecret(aura) then
        state.lastAura = "secret"
        return nil
    end
    if aura == nil then
        -- In a fight nil may only mean "hidden from you".
        if inCombat() or ask(C_Secrets and C_Secrets.ShouldAurasBeSecret) then
            state.lastAura = "hidden (combat)"
            return nil
        end
        state.lastAura = "not on you"
        return 0
    end
    if type(aura) ~= "table" then
        state.lastAura = "odd answer"
        return nil
    end
    local n = aura.applications
    if issecret(n) then
        state.lastAura = "secret stacks"
        return nil
    end
    if type(n) ~= "number" then
        state.lastAura = "no stack count"
        return nil
    end
    if n < 1 then n = 1 end -- a single application reads 0 on some clients
    n = math.min(n, MAX_STACKS)
    state.lastAura = "on you, " .. n
    return n
end

local function readSpeed()
    if type(GetUnitSpeed) ~= "function" then
        state.lastSpeed = "no GetUnitSpeed"
        return nil, nil
    end
    local ok, current, run = pcall(GetUnitSpeed, "player")
    if not ok then
        state.lastSpeed = "raised"
        return nil, nil
    end
    if issecret(current) or issecret(run) then
        state.lastSpeed = "secret"
        return nil, nil
    end
    if type(current) ~= "number" or type(run) ~= "number" then
        state.lastSpeed = "odd answer"
        return nil, nil
    end
    state.lastSpeed = string.format("%.3f / run %.3f", current, run)
    return current, run
end

------------------------------------------------------------------------
-- Moving or not
------------------------------------------------------------------------
local function updateMoving(now, current)
    local airborne = false
    if type(IsFalling) == "function" then
        local ok, f = pcall(IsFalling)
        if ok and not issecret(f) and f then airborne = true end
    end
    local going
    if current then
        going = current > 0 or airborne
    else
        going = state.eventMoving or airborne
    end
    if going then
        state.zeroSince = nil
        if not state.moving then
            state.moving = true
            state.startAt = now
        end
    else
        state.zeroSince = state.zeroSince or now
        if state.moving and now - state.zeroSince >= MOVE_GRACE then
            state.moving = false
            state.stopAt = state.zeroSince -- you stopped when the speed did
            state.lastDecayAt = nil
        elseif not state.stopAt then
            state.stopAt = now
        end
    end
end

------------------------------------------------------------------------
-- The clocks: where the next stack comes or goes
------------------------------------------------------------------------
-- returns mode ("gain", "decay", "max", "idle", "hold"), bar fill 0..1, seconds left or nil
local function clocks(now, stacks)
    stacks = stacks or 0
    if state.moving or (state.zeroSince and now - state.zeroSince < MOVE_GRACE and state.moving) then
        if stacks >= MAX_STACKS then return "max", 1, nil end
        local tick = gainTick()
        local anchor = state.lastGainAt
        if not anchor or now - anchor > 60 then anchor = state.startAt or now end
        local since = math.max(0, now - anchor)
        local cycles = math.floor(since / tick)
        local into = since - cycles * tick
        -- Due but not in yet: say "any moment" instead of starting the next cycle.
        if cycles >= 1 and into < OVERDUE_HOLD and state.lastGainAt == anchor
            and (state.startAt or 0) <= now - into then
            return "gain", 1, 0
        end
        return "gain", into / tick, tick - into
    end
    if stacks <= 0 then return "idle", 0, nil end
    local due, from
    local stopAt = state.stopAt or now
    if state.lastDecayAt and state.lastDecayAt >= stopAt then
        from = state.lastDecayAt
        due = from + decayTick()
    else
        from = stopAt
        due = (state.demo and (stopAt + decayTick())) or snapToBeat(stopAt + DECAY_GRACE) or (stopAt + DECAY_UNKNOWN)
    end
    local span = math.max(0.05, due - from)
    local left = due - now
    if left <= 0 then return "decay", 0, 0 end
    return "decay", clamp(left / span, 0, 1), left
end
ns.clocks = clocks
ns.clamp, ns.ask, ns.inCombat, ns.print = clamp, ask, inCombat, print
ns.MAX_STACKS, ns.BUFF_ID, ns.VERSION, ns.defaults = MAX_STACKS, BUFF_ID, VERSION, defaults

-- The display lives in Display.lua (ns.Display).

------------------------------------------------------------------------
-- The count changes
------------------------------------------------------------------------
local function logChange(now, from, to, kind)
    local entry = {
        t = math.floor(now * 1000) / 1000, from = from, to = to, kind = kind, src = state.source,
        moving = state.moving,
        sinceStop = (not state.moving and state.stopAt) and (math.floor((now - state.stopAt) * 1000) / 1000) or nil,
        sinceGain = state.lastGainAt and (math.floor((now - state.lastGainAt) * 1000) / 1000) or nil,
        bar = math.floor((ns.view and ns.view.barFrac or 0) * 100) / 100,
        combat = inCombat(),
    }
    push(db.log, entry, LOG_MAX)
end

local function setStacks(now, n, source)
    local before = state.stacks
    state.source = source
    if before == n then return end
    state.stacks = n
    if before == nil then
        ns.Display.Snap(n)
        return
    end
    local step = n - before
    local kind
    if step > 0 then
        kind = "gain"
        -- one stack, gained after a whole cycle of the clock: that gap is a tick length
        if step == 1 and state.lastGainAt and source ~= "demo" then
            local gap = now - state.lastGainAt
            if gap > 3 and gap < 8 then push(db.gainTicks, gap, 7) end
        end
        state.lastGainAt = now
    else
        -- a loss while moving (that is not a stop's last beat landing) or several at once: a hit
        local justSetOff = state.startAt and now - state.startAt < 1.2
        if step <= -2 or (state.moving and not justSetOff) then
            kind = "hit"
        else
            kind = "decay"
            if step == -1 and not state.moving and state.lastDecayAt and source ~= "demo" then
                local gap = now - state.lastDecayAt
                if gap > 0.5 and gap < 3 then push(db.decayTicks, gap, 7) end
            end
            state.lastDecayAt = now
        end
    end
    if source ~= "demo" and kind ~= "hit" then
        push(state.beats, now % 1, 8)
    end
    if source ~= "demo" then logChange(now, before, n, kind) end
    ns.Display.Animate(before, n, kind, now)
end
ns.setStacks = setStacks

------------------------------------------------------------------------
-- Demo: a scripted run so the bar can be seen on any character
------------------------------------------------------------------------
local DEMO = {
    -- { at seconds, moving, stacks }
    { 0, true, 0 },
}
do
    local t = 0.5
    for n = 1, 14 do DEMO[#DEMO + 1] = { t, true, n } t = t + 0.45 end
    DEMO[#DEMO + 1] = { t + 0.2, false, 14 } t = t + 1.5
    for n = 13, 10, -1 do DEMO[#DEMO + 1] = { t, false, n } t = t + 0.9 end
    DEMO[#DEMO + 1] = { t, true, 10 } t = t + 0.5
    for n = 11, 22 do DEMO[#DEMO + 1] = { t, true, n } t = t + 0.4 end
    t = t + 0.8
    DEMO[#DEMO + 1] = { t, true, 15 } t = t + 1.6 -- a hit
    for n = 16, 30 do DEMO[#DEMO + 1] = { t, true, n } t = t + 0.3 end
    t = t + 1.5
    DEMO[#DEMO + 1] = { t, true, 21 } t = t + 1.2 -- a big hit
    DEMO[#DEMO + 1] = { t, true, 12 } t = t + 1.5 -- another
    DEMO[#DEMO + 1] = { t, false, 12 } t = t + 1.4
    for n = 11, 0, -1 do DEMO[#DEMO + 1] = { t, false, n } t = t + 0.6 end
    DEMO[#DEMO + 1] = { t + 1.5, false, 0, true }
end

local function runDemo(now)
    local d = state.demo
    local elapsed = now - d.start
    while d.step <= #DEMO and DEMO[d.step][1] <= elapsed do
        local e = DEMO[d.step]
        if e[4] then
            state.demo = nil
            state.stacks, state.source = nil, "none"
            ns.Display.Snap(0)
            ns.refreshVisibility()
            print("demo finished.")
            return
        end
        if e[2] ~= state.moving then
            state.moving = e[2]
            if e[2] then state.startAt = now else state.stopAt, state.lastDecayAt = now, nil end
        end
        -- the demo runs its clocks fast: make the bar match the scripted gaps
        local nextE = DEMO[d.step + 1]
        d.gap = nextE and (nextE[1] - e[1]) or 1
        setStacks(now, e[3], "demo")
        if e[2] then state.lastGainAt = now end
        d.step = d.step + 1
    end
end

------------------------------------------------------------------------
-- The loop
------------------------------------------------------------------------
local function poll(now)
    local current = readSpeed()
    updateMoving(now, current)
    -- nil: the client is not saying (combat); the last count stands until it does
    local aura = readAura()
    if aura ~= nil then
        setStacks(now, aura, "aura")
    end
end

local function onUpdate(self, elapsed)
    local now = GetTime()
    if state.demo then
        runDemo(now)
    elseif inCombat() then
        return -- hidden in combat; PLAYER_REGEN_DISABLED hides the frame, this is belt and braces
    elseif now - state.lastPoll >= POLL then
        state.lastPoll = now
        poll(now)
    end
    ns.Display.Render(now)
end

local function refreshVisibility()
    local frame = ns.Display.frame
    if not frame then return end
    local show = state.demo ~= nil or (isTauren() and not ask(UnitOnTaxi, "player") and not inCombat())
    frame:SetShown(show)
end
ns.refreshVisibility = refreshVisibility

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_STARTED_MOVING")
events:RegisterEvent("PLAYER_STOPPED_MOVING")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_CONTROL_LOST")
events:RegisterEvent("PLAYER_CONTROL_GAINED")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        PlainstrideDB = PlainstrideDB or {}
        db = PlainstrideDB
        for k, v in pairs(defaults) do
            if db[k] == nil then
                if type(v) == "table" then
                    local copy = {}
                    for kk, vv in pairs(v) do copy[kk] = vv end
                    db[k] = copy
                else
                    db[k] = v
                end
            end
        end
        -- 0.1.0 sat on top of the action bars: move a bar nobody has moved yet
        local p = db.point
        if p and p[1] == "BOTTOM" and p[3] == "BOTTOM" and p[4] == 0 and p[5] == 190 then p[5] = 260 end
        db.portrait = nil
        db.version = VERSION
        ns.db = db
        ns.Display.Build()
        ns.Display.frame:SetScript("OnUpdate", onUpdate)
        ns.Options.RegisterPage()
        ns.Options.UpdateMinimapButton()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_ENTERING_WORLD" then
        refreshVisibility()
        if isTauren() and not db.hinted then
            db.hinted = true
            print("Plainsrunning bar is on. Options: the minimap button, /plainstride, or Options > AddOns > Plainstride.")
        end
    elseif event == "PLAYER_STARTED_MOVING" then
        state.eventMoving = true
    elseif event == "PLAYER_STOPPED_MOVING" then
        state.eventMoving = false
    elseif event == "PLAYER_REGEN_DISABLED" then
        refreshVisibility()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- start over from what the buff says now: no gain, loss or hit animation for the fight
        state.stacks, state.source = nil, "none"
        state.lastGainAt, state.lastDecayAt, state.beats = nil, nil, {}
        state.lastPoll = 0
        if not state.demo then poll(GetTime()) end
        refreshVisibility()
    elseif event == "PLAYER_CONTROL_LOST" or event == "PLAYER_CONTROL_GAINED" then
        refreshVisibility()
    end
end)

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------
local function describe()
    local now = GetTime()
    local mode, frac, left = clocks(now, state.stacks)
    print(string.format("v%s. Stacks %s from %s; %s; bar %s %.2f%s.", VERSION, tostring(state.stacks), state.source,
        state.moving and "moving" or "standing", mode, frac, left and string.format(", %.2fs left", left) or ""))
    print("aura: " .. state.lastAura .. "; speed: " .. state.lastSpeed .. ". The bar hides in combat.")
    local phase = beatPhase()
    print(string.format("gain tick %.2fs (%d seen), loss tick %.2fs (%d seen), beat %s.", gainTick(), #db.gainTicks,
        decayTick(), #db.decayTicks, phase and string.format("%.2f", phase) or "not seen yet"))
    local secretAuras = ask(C_Secrets and C_Secrets.ShouldAurasBeSecret)
    local secretStats = ask(C_Secrets and C_Secrets.ShouldUnitStatsBeSecret)
    local secrecy = ask(C_Secrets and C_Secrets.GetSpellAuraSecrecy, BUFF_ID)
    print(string.format("client: auras secret %s, stats secret %s, buff secrecy %s, combat %s, tauren %s.",
        tostring(secretAuras), tostring(secretStats), tostring(secrecy), tostring(inCombat()), tostring(isTauren())))
    local last = db.log[#db.log]
    if last then
        print(string.format("last change: %s -> %s (%s, %s)%s.", tostring(last.from), tostring(last.to), last.kind, last.src,
            last.sinceStop and string.format(", %.2fs after stopping", last.sinceStop) or ""))
    end
end

local function help()
    print("/plainstride opens the options. Also: lock | unlock | scale <0.4-2> | idle <0-1> | timer | layout | minimap | demo | reset | debug")
end

SLASH_PLAINSTRIDE1 = "/plainstride"
SLASH_PLAINSTRIDE2 = "/pstride"
SlashCmdList.PLAINSTRIDE = function(msg)
    local cmd, rest = string.match(msg or "", "^%s*(%S*)%s*(.-)%s*$")
    cmd = string.lower(cmd or "")
    local n = tonumber(rest)
    local D = ns.Display
    if cmd == "lock" then
        db.locked = true D.ApplyLock() print("locked.")
    elseif cmd == "unlock" then
        db.locked = false D.ApplyLock() print("unlocked: drag the bar, then /plainstride lock.")
    elseif cmd == "scale" and n then
        db.scale = clamp(n, 0.4, 2) D.Layout() print("scale " .. db.scale .. ".")
    elseif cmd == "idle" and n then
        db.idleAlpha = clamp(n, 0, 1) print("opacity at 0 stacks: " .. db.idleAlpha .. ".")
    elseif cmd == "timer" then
        db.showTimer = not db.showTimer print("countdown text " .. (db.showTimer and "on" or "off") .. ".")
    elseif cmd == "demo" then
        state.demo = { start = GetTime(), step = 1 }
        state.stacks = nil
        D.frame:Show()
        print("demo running (about 40 seconds).")
    elseif cmd == "reset" then
        db.scale, db.idleAlpha, db.showTimer = defaults.scale, defaults.idleAlpha, true
        local p = defaults.point
        db.point = { p[1], p[2], p[3], p[4], p[5] }
        D.frame:ClearAllPoints()
        D.frame:SetPoint(p[1], UIParent, p[3], p[4], p[5])
        D.Layout()
        print("position and size reset.")
    elseif cmd == "layout" then
        db.layout = (db.layout == "one") and "two" or "one"
        D.Layout()
        print(db.layout == "one" and "one bar: the countdown runs inside the stack bar." or "two bars: the stack bar with the cast bar under it.")
    elseif cmd == "minimap" then
        db.minimap = not db.minimap
        ns.Options.UpdateMinimapButton()
        print("minimap button " .. (db.minimap and "shown" or "hidden") .. ".")
    elseif cmd == "debug" then
        describe()
    elseif cmd == "" then
        ns.Options.Toggle()
    else
        help()
    end
    ns.Options.Refresh()
end
