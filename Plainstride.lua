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
local MOVE_GRACE = 0.3      -- a zero speed shorter than this is a strafe or a turn, not a stop
local POLL = 0.05           -- how often the client is asked (the drawing runs every frame)
local LOG_MAX = 60

local issecret = issecretvalue or function() return false end

local defaults = {
    locked = true,
    scale = 0.75,
    idleAlpha = 0.45,
    showTimer = true,
    showCount = true,     -- "Plainsrunning 12 / 30" in the middle of the bar
    fadeEmpty = false,    -- fade the bar right out at 0 stacks while standing
    fill = "herbalism",   -- which profession bar's animated fill (Display FILLS)
    flatBar = false,      -- plain one-color fills instead of the profession and cast bar art
    hitMarker = true,     -- mark where one hit would leave you (half your stacks)
    tooltip = true,       -- stacks, countdown and the rules on hover
    dock = false,         -- sit under the player frame, as wide as it
    hideInCombat = true,  -- off: the bar stays in a fight, frozen at the last count
    bgAlpha = 1,          -- opacity of the empty part of the bars
    streaks = true,       -- wind streaks through the fill while running
    streakDir = "right",  -- wind streaks: "right" (toward the next stack) or "left" (rushing past you)
    layout = "two",       -- "two": stack bar + cast bar under it; "one": the countdown inside the stack bar
    lossBar = true,       -- two bars: a loss bar under the gain bar while a loss is coming
    style = "auto",       -- window style: "auto" (EllesmereUI when it runs), "blizzard" or "dark" (Styles.lua)
    darkAlpha = 0.92,     -- the Dark style's window background opacity
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

------------------------------------------------------------------------
-- Reading the client
------------------------------------------------------------------------
-- In a fight, from the combat events themselves: InCombatLockdown() still answers false while
-- PLAYER_REGEN_DISABLED is being handled (the lockdown starts after it), which left the bar up.
-- UnitAffectingCombat covers a /reload in the middle of a fight.
local function inCombat()
    if state.fighting ~= nil then return state.fighting end
    if ask(InCombatLockdown) then return true end
    return ask(UnitAffectingCombat, "player") and true or false
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
        -- the speed is not readable: the client's own moving flag, then its movement events
        going = (ask(IsPlayerMoving) == true) or state.eventMoving or airborne
    end
    if going then
        state.zeroSince = nil
        state.standAt = nil
        if not state.moving then
            state.moving = true
            state.startAt = now
        end
    else
        state.zeroSince = state.zeroSince or now
        if state.moving and now - state.zeroSince >= MOVE_GRACE then
            state.moving = false
            state.standAt = now -- from here the bar shows you standing (the tick model's input)
            state.stopAt = state.zeroSince -- you stopped when the speed did
            state.lastDecayAt = nil
        elseif not state.stopAt then
            state.stopAt = now
        end
        if not state.moving and not state.standAt then state.standAt = now end
    end
end

------------------------------------------------------------------------
-- The clocks: where the next stack comes or goes
------------------------------------------------------------------------
-- The demo's scripted clocks (it sets its own gaps).
local function demoClocks(now, stacks)
    stacks = stacks or 0
    if state.moving then
        if stacks >= MAX_STACKS then return "max", 1, nil end
        local tick = gainTick()
        local anchor = state.lastGainAt or state.startAt or now
        local since = math.max(0, now - anchor)
        local into = since - math.floor(since / tick) * tick
        return "gain", into / tick, tick - into
    end
    if stacks <= 0 then return "idle", 0, nil end
    local from = (state.lastDecayAt and state.lastDecayAt >= (state.stopAt or now)) and state.lastDecayAt or (state.stopAt or now)
    local due = from + decayTick()
    local left = due - now
    if left <= 0 then return "decay", 0, 0 end
    return "decay", clamp(left / math.max(0.05, due - from), 0, 1), left
end

------------------------------------------------------------------------
-- The tick model, fitted to a frame-by-frame recording of the real count (2026-10-09, 36
-- changes, while the player ran, stopped and stutter-stepped):
--   * the game changes the count only on its 1 second tick;
--   * just after each tick the game checks you once. Standing at the check (and still 0.2 s
--     later) costs a stack on the NEXT tick, and the count below starts again; a step taken
--     after the check does not save it. Stand through every check and you lose one a second;
--     the first comes 1 to 2 seconds after you stop;
--   * every other check counts toward a stack (the tooltip's "every 5 sec spent moving"): the
--     fifth since the last change gives one on the next tick. Short stops between checks
--     neither pause nor reset it;
--   * the check made on the tick of a loss only counts if you also stood through the check
--     before it (a stop that began after a loss does not cost again at once).
-- Replayed through the addon (tests/plainstridetest.js), it predicts 17 of the 18 losses and 16 of
-- the 18 gains within a tick, with 7 early or false loss warnings.
-- The misses are stops within a tenth of a second of a check. Every real change re-anchors it.
-- SAMPLE_AT is measured from the tick as the addon learns it (from the changes it sees).
------------------------------------------------------------------------
local TM = { SAMPLE_AT = 0.05, SAMPLE_HOLD = 0.2, SLACK = POLL, GAIN_TICKS = 5, LATE = 0.6 }
ns.TM = TM

-- The tick phase (seconds past the whole second) and whether it is known from real changes.
function TM.phase()
    local p = beatPhase()
    if p then return p, true end
    return 0, false
end
-- The last tick at or before t, the next at or after it, and the nearest.
function TM.prev(t)
    local p = TM.phase()
    return math.floor(t - p + 1e-6) + p
end
function TM.next(t)
    local k = TM.prev(t)
    if k < t - 1e-6 then k = k + 1 end
    return k
end
function TM.nearest(t)
    local k = TM.prev(t)
    if t - k > 0.5 then k = k + 1 end
    return k
end

-- A real count change at `now`: the checks count again from its tick.
function TM.realChange(now, step)
    local k = TM.nearest(now)
    -- the phase may just have moved with this change: line the decided ticks up with it
    if state.sampledTick then state.sampledTick = TM.nearest(state.sampledTick) end
    -- the check of this tick (just after it) is the first of the new count
    if not state.sampledTick or state.sampledTick > k - 1 + 0.5 then state.sampledTick = k - 1 end
    state.moveChecks = 0
    state.pendingGainAt = nil
    if step < 0 then state.lossTick = k end
    if state.pendingLossAt and (step < 0 or math.abs(state.pendingLossAt - k) < 0.5) then state.pendingLossAt = nil end
    state.missedGain, state.missedLoss = nil, nil
end

-- Each poll: decide the checks whose hold has passed, and notice predictions that did not come
-- true. A check finds you standing (you stood at it and for its hold) or moving.
function TM.update(now, stacks)
    stacks = stacks or 0
    local c = TM.prev(now - TM.SAMPLE_AT - TM.SAMPLE_HOLD)
    if not state.sampledTick or c > state.sampledTick + 0.5 then
        -- only the latest one if several went by (a hitch, a loading screen)
        state.sampledTick = c
        local t = c + TM.SAMPLE_AT
        -- one poll of slack: the bar notices a stop up to a poll late
        local standing = not state.moving and state.standAt ~= nil and state.standAt <= t + TM.SLACK + 1e-6
        if standing and state.lossTick and math.abs(state.lossTick - c) < 0.5 and state.standAt > t - 1 + TM.SLACK + 1e-6 then
            standing = false
        end
        if standing then
            if stacks > 0 then state.pendingLossAt = c + 1 end
            state.moveChecks, state.pendingGainAt = 0, nil
        else
            state.moveChecks = (state.moveChecks or 0) + 1
            if state.moveChecks >= TM.GAIN_TICKS and stacks < MAX_STACKS then state.pendingGainAt = c + 1 end
        end
    end
    -- Predicted, but the count did not move: the real count wins, the estimate is marked.
    if state.pendingLossAt and now > state.pendingLossAt + TM.LATE then
        state.pendingLossAt, state.missedLoss = nil, true
    end
    if state.pendingGainAt and now > state.pendingGainAt + TM.LATE then
        state.pendingGainAt, state.moveChecks, state.missedGain = nil, 0, true
    end
end

-- Standing now: the next check you stand through costs a stack on the tick after it. Returns the
-- seconds to that loss and how much of the wait from your stop is left (0..1).
function TM.standingLoss(now)
    local nextCheck = (state.sampledTick or TM.prev(now)) + 1
    local cTick = math.max(TM.prev(now - TM.SAMPLE_AT), nextCheck)
    if not (state.standAt and state.standAt <= cTick + TM.SAMPLE_AT + TM.SLACK + 1e-6) then cTick = cTick + 1 end
    if state.lossTick and math.abs(state.lossTick - cTick) < 0.5 and state.standAt
        and state.standAt > cTick + TM.SAMPLE_AT - 1 + TM.SLACK + 1e-6 then cTick = cTick + 1 end
    local lossAt = cTick + 1
    local from = math.min(state.standAt or now, now)
    local left = math.max(0, lossAt - now)
    return left, clamp(left / math.max(0.05, lossAt - from), 0, 1)
end

-- returns mode ("gain", "decay", "max", "idle"), bar fill 0..1, seconds left (or nil), estimated
local function clocks(now, stacks)
    if state.demo then return demoClocks(now, stacks) end
    stacks = stacks or 0
    local _, known = TM.phase()
    local estimated = not known or state.missedGain == true or state.missedLoss == true
    local done = state.moveChecks or 0
    -- the next check not decided yet, and the tick a stack comes if every check from there finds you moving
    local nextCheck = (state.sampledTick or TM.prev(now)) + 1
    local gainAt = state.pendingGainAt or (nextCheck + math.max(0, TM.GAIN_TICKS - done))
    if state.pendingLossAt and stacks > 0 then
        -- checked standing: the stack goes on this tick, whatever you do now
        local left = math.max(0, state.pendingLossAt - now)
        return "decay", clamp(left / (1 - TM.SAMPLE_AT - TM.SAMPLE_HOLD), 0, 1), left, estimated
    end
    if not state.moving and stacks > 0 and not state.pendingGainAt then
        local left, frac = TM.standingLoss(now)
        return "decay", frac, left, estimated
    end
    if stacks >= MAX_STACKS then return "max", 1, nil, estimated end
    if stacks <= 0 and not state.moving then return "idle", clamp(done / TM.GAIN_TICKS, 0, 1), nil, estimated end
    local left = math.max(0, gainAt - now)
    return "gain", clamp(1 - left / TM.GAIN_TICKS, 0, 1), left, estimated
end
ns.clocks = clocks

-- The two clocks apart, for the two bars: the gain clock always, the loss clock only while a loss
-- is coming. gain = { mode = "gain" | "max" | "idle", frac, left, est, done }; loss = nil or
-- { frac, left, certain (a check caught you), est }.
local gainOut, lossOut = {}, {}
function ns.gainLoss(now, stacks)
    stacks = stacks or 0
    if state.demo then
        local mode, frac, left = demoClocks(now, stacks)
        gainOut.mode, gainOut.frac, gainOut.left, gainOut.est, gainOut.done = (mode == "decay") and "idle" or mode,
            (mode == "gain" or mode == "max") and frac or 0, (mode == "gain") and left or nil, false, 0
        if mode == "decay" then
            lossOut.frac, lossOut.left, lossOut.certain, lossOut.est = frac, left, (left or 1) < 0.35, false
            return gainOut, lossOut
        end
        return gainOut, nil
    end
    local _, known = TM.phase()
    local done = state.moveChecks or 0
    local nextCheck = (state.sampledTick or TM.prev(now)) + 1
    local gainAt = state.pendingGainAt or (nextCheck + math.max(0, TM.GAIN_TICKS - done))
    gainOut.est, gainOut.done = (not known) or state.missedGain == true, done
    if stacks >= MAX_STACKS then
        gainOut.mode, gainOut.frac, gainOut.left = "max", 1, nil
    elseif stacks <= 0 and not state.moving then
        gainOut.mode, gainOut.frac, gainOut.left = "idle", clamp(done / TM.GAIN_TICKS, 0, 1), nil
    else
        local left = math.max(0, gainAt - now)
        gainOut.mode, gainOut.frac, gainOut.left = "gain", clamp(1 - left / TM.GAIN_TICKS, 0, 1), left
    end
    if stacks <= 0 then return gainOut, nil end
    lossOut.est = (not known) or state.missedLoss == true
    if state.pendingLossAt then
        local left = math.max(0, state.pendingLossAt - now)
        lossOut.frac, lossOut.left, lossOut.certain = clamp(left / (1 - TM.SAMPLE_AT - TM.SAMPLE_HOLD), 0, 1), left, true
        return gainOut, lossOut
    end
    if not state.moving then
        lossOut.left, lossOut.frac = TM.standingLoss(now)
        lossOut.certain = false
        return gainOut, lossOut
    end
    return gainOut, nil
end
ns.clamp, ns.ask, ns.inCombat, ns.print = clamp, ask, inCombat, print
ns.MAX_STACKS, ns.BUFF_ID, ns.VERSION, ns.defaults = MAX_STACKS, BUFF_ID, VERSION, defaults
-- for Plainstride_Skins.lua: the settings, and where its status lines go
function ns.DB() return db end
ns.report = {}

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
    if source ~= "demo" then TM.realChange(now, step) end
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
    TM.update(now, state.stacks)
end

local function onUpdate(self, elapsed)
    local now = GetTime()
    if state.demo then
        runDemo(now)
    elseif inCombat() then
        -- the buff cannot be read in a fight: keep only the movement up to date (the bar shows
        -- "In combat" and the last count, when it is shown at all)
        if db.hideInCombat ~= false then return end
        if now - state.lastPoll >= POLL then
            state.lastPoll = now
            updateMoving(now, (readSpeed()))
        end
    elseif now - state.lastPoll >= POLL then
        state.lastPoll = now
        poll(now)
    end
    ns.Display.Render(now)
end

local function refreshVisibility()
    local frame = ns.Display.frame
    if not frame then return end
    local hideNow = inCombat() and db.hideInCombat ~= false
    local show = state.demo ~= nil or (isTauren() and not ask(UnitOnTaxi, "player") and not hideNow)
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
        -- the streaks' default became "right": move saved files that still hold the old default
        if not db.streakRightDefault then
            db.streakDir = "right"
            db.streakRightDefault = true
        end
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
        state.fighting = true
        refreshVisibility()
    elseif event == "PLAYER_REGEN_ENABLED" then
        state.fighting = false
        -- start over from what the buff says now: no gain, loss or hit animation for the fight
        state.stacks, state.source = nil, "none"
        state.lastGainAt, state.lastDecayAt, state.beats = nil, nil, {}
        state.moveChecks, state.pendingLossAt, state.pendingGainAt, state.sampledTick, state.lossTick = 0, nil, nil, nil, nil
        state.missedGain, state.missedLoss = nil, nil
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
    print("skin: " .. tostring(ns.report.skin or "?") .. ", Dark opacity " .. tostring(db.darkAlpha) .. ".")
    for k, v in pairs(ns.report) do
        if type(k) == "string" and k:find("^skin error") then print(k .. ": " .. tostring(v)) end
    end
    local last = db.log[#db.log]
    if last then
        print(string.format("last change: %s -> %s (%s, %s)%s.", tostring(last.from), tostring(last.to), last.kind, last.src,
            last.sinceStop and string.format(", %.2fs after stopping", last.sinceStop) or ""))
    end
end

-- The last N stack changes, newest last: what the bar saw, and how each hit compares to halving.
function ns.printLog(count)
    local log = db.log
    if #log == 0 then
        print("no stack changes recorded yet.")
        return
    end
    local now = GetTime()
    local first = math.max(1, #log - count + 1)
    print(string.format("last %d stack changes (of %d):", #log - first + 1, #log))
    for i = first, #log do
        local e = log[i]
        local ago = now - e.t
        local when = (ago >= 0 and ago < 86400) and string.format("%.0fs ago", ago) or "earlier session"
        local extra = ""
        if e.kind == "hit" and e.from then
            extra = (e.to == math.floor(e.from / 2)) and ", exactly half" or string.format(", half would be %d", math.floor(e.from / 2))
        elseif e.kind == "decay" and e.sinceStop then
            extra = string.format(", %.2fs after stopping", e.sinceStop)
        elseif e.kind == "gain" and e.sinceGain then
            extra = string.format(", %.2fs after the last gain", e.sinceGain)
        end
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s: %s -> %s %s%s%s", when, tostring(e.from), tostring(e.to),
            e.kind or "?", e.moving and " (moving)" or "", extra))
    end
end

local function help()
    print("/plainstride opens the options. Also: lock | unlock | scale <0.4-2> | idle <0-1> | background <0-1> | count | timer | fade | fill [name] | flat | combat | streaks [left|right] | marker | tooltip | dock | log [N] | layout | lossbar | style [auto|blizzard|dark] | minimap | demo | reset | debug")
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
    elseif cmd == "background" and n then
        db.bgAlpha = clamp(n, 0, 1) D.ApplyBackground() print("background opacity: " .. db.bgAlpha .. ".")
    elseif cmd == "idle" and n then
        db.idleAlpha = clamp(n, 0, 1) print("opacity at 0 stacks: " .. db.idleAlpha .. ".")
    elseif cmd == "fade" then
        db.fadeEmpty = not db.fadeEmpty print("fade out at 0 stacks " .. (db.fadeEmpty and "on" or "off") .. ".")
    elseif cmd == "count" then
        db.showCount = not db.showCount print("stack count text " .. (db.showCount and "on" or "off") .. ".")
    elseif cmd == "timer" then
        db.showTimer = not db.showTimer print("countdown text " .. (db.showTimer and "on" or "off") .. ".")
    elseif cmd == "demo" then
        state.demo = { start = GetTime(), step = 1 }
        state.stacks = nil
        D.frame:Show()
        print("demo running (about 40 seconds).")
    elseif cmd == "reset" then
        db.scale, db.idleAlpha, db.showTimer, db.showCount = defaults.scale, defaults.idleAlpha, true, true
        db.bgAlpha = 1
        D.ApplyBackground()
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
    elseif cmd == "style" then
        local Styles = ns.Styles
        local arg = string.lower(rest or "")
        if arg == "auto" or arg == "automatic" then Styles.Set("auto")
        elseif arg == "blizzard" or arg == "dark" then Styles.Set(arg)
        elseif arg == "" then Styles.Cycle(1)
        else print("styles: auto, blizzard, dark.") return end
        print("window style: " .. Styles.Name(db.style) .. ". " .. Styles.Note())
    elseif cmd == "lossbar" then
        db.lossBar = db.lossBar == false
        D.Layout()
        print(db.lossBar and "the loss bar shows under the gain bar while a loss is coming." or "no loss bar.")
    elseif cmd == "minimap" then
        db.minimap = not db.minimap
        ns.Options.UpdateMinimapButton()
        print("minimap button " .. (db.minimap and "shown" or "hidden") .. ".")
    elseif cmd == "fill" then
        local list, pick = D.FILLS, nil
        local want = string.lower(rest or "")
        for i, f in ipairs(list) do
            if want ~= "" and string.find(string.lower(f.name), want, 1, true) == 1 then pick = f end
            if want == "" and f.key == db.fill then pick = list[i % #list + 1] end
        end
        pick = pick or list[1]
        db.fill = pick.key
        D.ApplyFill()
        print("bar texture: " .. pick.name .. ".")
    elseif cmd == "flat" then
        db.flatBar = not db.flatBar
        D.ApplyFill()
        print(db.flatBar and "flat bars: one plain color." or "bars in Blizzard's art again.")
    elseif cmd == "combat" then
        db.hideInCombat = not db.hideInCombat
        refreshVisibility()
        print(db.hideInCombat and "the bar hides in combat." or "the bar stays in combat, frozen at your last count.")
    elseif cmd == "streaks" then
        local arg = string.lower(rest or "")
        if arg == "left" or arg == "right" then
            db.streakDir = arg
            print("wind streaks move " .. (arg == "right" and "right, toward the next stack." or "left, rushing past you."))
        else
            db.streaks = db.streaks == false
            print("wind streaks " .. (db.streaks and "on" or "off") .. ".")
        end
    elseif cmd == "marker" then
        db.hitMarker = not db.hitMarker print("hit marker " .. (db.hitMarker and "on" or "off") .. ".")
    elseif cmd == "tooltip" then
        db.tooltip = not db.tooltip D.ApplyLock() print("tooltip " .. (db.tooltip and "on" or "off") .. ".")
    elseif cmd == "dock" then
        db.dock = not db.dock
        D.Layout()
        if db.dock and not D.DockTarget() then print("there is no player frame to dock under.")
        else print(db.dock and (D.DockTarget() ~= PlayerFrame and "docked under EllesmereUI's player frame." or "docked under the player frame.") or "undocked: back where you put it.") end
    elseif cmd == "log" then
        ns.printLog(n or 10)
    elseif cmd == "debug" then
        describe()
    elseif cmd == "" then
        ns.Options.Toggle()
    else
        help()
    end
    ns.Options.Refresh()
end
