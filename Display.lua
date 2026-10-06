-- Plainstride display: Blizzard's own interface art, put together the way Blizzard builds it.
--
--   stack bar  the profession skill bar (Professions-skillbar-bg/-frame/-mask) with the animated
--              Herbalism fill flipbook and its flare. Blizzard_ProfessionsTemplates is load on
--              demand, so the template itself is never used (loading a Blizzard addon taints it);
--              the same pieces are rebuilt here from its XML.
--   tick bar   a real CastingBarFrameTemplate (Blizzard_UIPanels_Game, loaded at startup) with its
--              events and scripts switched off: the client's own cast bar art, spark and finish /
--              interrupt effects, driven by our clocks. A plain look-alike stands in if the
--              template cannot be made.
--   portrait   your character as a 3D model in an action button frame: runs when you run, stands
--              when you stand, flinches when a hit knocks stacks off. Or the Plainsrunning icon.
local ADDON, ns = ...

local D = {}
ns.Display = D

local MAX = ns.MAX_STACKS or 30
local BAR_W, BAR_H = 453, 29          -- ProfessionsRankBarTemplate
local FILL_W, FILL_H = 441, 18        -- its Fill
local FILL_X, FILL_Y = 5, -3
local PORTRAIT_W, PORTRAIT_H = 46, 45 -- UI-HUD-ActionBar-IconFrame
local GAP = 6
local TICK_H = 11                     -- the cast bar's natural height
local TOTAL_W = PORTRAIT_W + GAP + BAR_W
local TOTAL_H = 48

local ANIM = { STAND = 0, RUN = 5, WOUND = 9 }

local frame, stack, tick, portrait
local view = {
    shown = 0, tweenFrom = 0, tweenTo = 0, tweenStart = 0, tweenDur = 0,
    ghost = nil,
    barFrac = 0,
    mode = nil,
    tickArt = nil,
    flowing = nil,
    modelAnim = nil, woundUntil = nil,
}
ns.view = view
D.view = view

local function db() return ns.db end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function easeOut(t) t = clamp(t, 0, 1) return 1 - (1 - t) * (1 - t) * (1 - t) end

local function try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
    return nil
end

-- The first font object this client has, so SetText never meets a font string without a font.
local function newFont(parent, layer, ...)
    local fs = parent:CreateFontString(nil, layer)
    for i = 1, select("#", ...) do
        local obj = _G[select(i, ...)]
        if obj and pcall(fs.SetFontObject, fs, obj) then return fs end
    end
    pcall(fs.SetFontObject, fs, GameFontHighlight)
    return fs
end

local function setAtlas(tex, atlas, useSize)
    if tex and tex.SetAtlas then
        local ok, res = pcall(tex.SetAtlas, tex, atlas, useSize)
        return ok and res ~= false
    end
    return false
end

------------------------------------------------------------------------
-- Animation helpers (the same building blocks Blizzard's XML uses)
------------------------------------------------------------------------
local function group(region, looping)
    local g = region:CreateAnimationGroup()
    if looping then g:SetLooping(looping) end
    if g.SetToFinalAlpha then g:SetToFinalAlpha(true) end
    return g
end

local function alpha(g, from, to, duration, order, delay, smoothing)
    local a = g:CreateAnimation("Alpha")
    a:SetFromAlpha(from)
    a:SetToAlpha(to)
    a:SetDuration(duration)
    a:SetOrder(order or 1)
    if delay then a:SetStartDelay(delay) end
    if smoothing then a:SetSmoothing(smoothing) end
    return a
end

local function translation(g, x, y, duration, order, delay, smoothing)
    local a = g:CreateAnimation("Translation")
    a:SetOffset(x, y)
    a:SetDuration(duration)
    a:SetOrder(order or 1)
    if delay then a:SetStartDelay(delay) end
    if smoothing then a:SetSmoothing(smoothing) end
    return a
end

local function scale(g, from, to, duration, order, delay)
    local a = g:CreateAnimation("Scale")
    if a.SetScaleFrom then
        a:SetScaleFrom(from, from)
        a:SetScaleTo(to, to)
    else
        a:SetFromScale(from, from)
        a:SetToScale(to, to)
    end
    a:SetDuration(duration)
    a:SetOrder(order or 1)
    if delay then a:SetStartDelay(delay) end
    return a
end

local function play(g)
    if g then
        g:Stop()
        g:Play()
    end
end

------------------------------------------------------------------------
-- The stack bar: Blizzard's profession skill bar with the Herbalism fill
------------------------------------------------------------------------
local function buildStackBar(parent)
    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(BAR_W, BAR_H)

    s.Background = s:CreateTexture(nil, "ARTWORK", nil, 1)
    setAtlas(s.Background, "Professions-skillbar-bg", true)
    s.Background:SetPoint("TOPLEFT")

    s.Fill = s:CreateTexture(nil, "ARTWORK", nil, 2)
    s.Fill:SetSize(FILL_W, FILL_H)
    s.Fill:SetPoint("TOPLEFT", FILL_X, FILL_Y)
    if not setAtlas(s.Fill, "skillbar_fill_flipbook_herbalism", false) then
        setAtlas(s.Fill, "Skillbar_Fill_Flipbook_DefaultBlue", false)
    end

    s.Flare = s:CreateTexture(nil, "ARTWORK", nil, 2)
    s.Flare:SetSize(53, 16)
    s.Flare:SetBlendMode("ADD")
    setAtlas(s.Flare, "skillbar_flare_herbalism", false)
    s.Flare:SetAlpha(0)

    -- Blizzard sizes a mask instead of the fill, so the flipbook never stretches
    if s.CreateMaskTexture then
        s.Mask = s:CreateMaskTexture(nil, "ARTWORK", nil, 2)
        setAtlas(s.Mask, "Professions-skillbar-mask", true)
        if s.Mask.SetTextureWrap then pcall(s.Mask.SetTextureWrap, s.Mask, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE") end
        s.Mask:SetPoint("LEFT", s.Fill, "LEFT", 1, 0)
        s.Fill:AddMaskTexture(s.Mask)
        s.Flare:AddMaskTexture(s.Mask)
        s.Flare:SetPoint("RIGHT", s.Mask, "RIGHT", 0, 0)
    else
        s.Flare:SetPoint("RIGHT", s.Fill, "LEFT", 0, 0)
    end

    -- what was just lost, lingering on top of the empty part of the bar
    s.Ghost = s:CreateTexture(nil, "ARTWORK", nil, 3)
    s.Ghost:SetHeight(FILL_H - 2)
    s.Ghost:Hide()
    s.GhostFlash = s:CreateTexture(nil, "ARTWORK", nil, 4)
    s.GhostFlash:SetBlendMode("ADD")
    setAtlas(s.GhostFlash, "ui-castingbar-full-glow-standard", false)
    s.GhostFlash:SetPoint("TOPLEFT", s.Ghost, "TOPLEFT", -2, 2)
    s.GhostFlash:SetPoint("BOTTOMRIGHT", s.Ghost, "BOTTOMRIGHT", 2, -2)
    s.GhostFlash:SetAlpha(0)

    -- one mark per stack, a pip on every fifth (the experience bar's own divider and pip)
    s.Dividers = {}
    for i = 1, MAX - 1 do
        local major = i % 5 == 0
        local t = s:CreateTexture(nil, "ARTWORK", nil, 5)
        if major then
            setAtlas(t, "UI-HUD-ExperienceBar-Frame-Pip", false)
            t:SetSize(6, FILL_H + 4)
        else
            setAtlas(t, "UI-HUD-ExperienceBar-Divider", false)
            t:SetSize(2, FILL_H - 6)
            t:SetAlpha(0.7)
        end
        t:SetPoint("CENTER", s.Fill, "LEFT", FILL_W * i / MAX, 0)
        s.Dividers[i] = t
    end

    s.Border = s:CreateTexture(nil, "ARTWORK", nil, 6)
    setAtlas(s.Border, "Professions-skillbar-frame", true)
    s.Border:SetPoint("TOPLEFT")

    -- hit: the cast bar's interrupt glow, stretched around this bar
    s.HitGlow = s:CreateTexture(nil, "BACKGROUND")
    s.HitGlow:SetBlendMode("ADD")
    setAtlas(s.HitGlow, "cast_interrupt_outerglow", false)
    s.HitGlow:SetPoint("TOPLEFT", s.Fill, "TOPLEFT", -22, 18)
    s.HitGlow:SetPoint("BOTTOMRIGHT", s.Fill, "BOTTOMRIGHT", 22, -18)
    s.HitGlow:SetAlpha(0)

    -- full: the bonus objective bar's starburst and sheen
    s.Starburst = s:CreateTexture(nil, "OVERLAY", nil, 1)
    s.Starburst:SetBlendMode("ADD")
    setAtlas(s.Starburst, "bonusobjectives-bar-starburst", false)
    s.Starburst:SetSize(54, 54)
    s.Starburst:SetPoint("CENTER", s.Fill, "RIGHT", 0, 0)
    s.Starburst:SetAlpha(0)
    s.Sheen = s:CreateTexture(nil, "OVERLAY")
    s.Sheen:SetBlendMode("ADD")
    setAtlas(s.Sheen, "bonusobjectives-bar-sheen", false)
    s.Sheen:SetSize(97, FILL_H + 4)
    s.Sheen:SetPoint("LEFT", s.Fill, "LEFT", -60, 0)
    s.Sheen:SetAlpha(0)

    local textHolder = CreateFrame("Frame", nil, s)
    textHolder:SetAllPoints(s.Fill)
    textHolder:SetFrameLevel(s:GetFrameLevel() + 5)
    s.Text = newFont(textHolder, "OVERLAY", "Number12FontOutline", "GameFontHighlightOutline", "GameFontHighlight")
    s.Text:SetPoint("CENTER", s.Fill, "CENTER", 0, 0)
    s.Text:SetJustifyH("CENTER")

    -- animations
    s.FillAnim = group(s.Fill, "REPEAT")
    do
        local fb = s.FillAnim:CreateAnimation("FlipBook")
        fb:SetDuration(2.0)
        fb:SetFlipBookRows(30)
        fb:SetFlipBookColumns(2)
        fb:SetFlipBookFrames(60)
        fb:SetFlipBookFrameWidth(0)
        fb:SetFlipBookFrameHeight(0)
    end
    s.FlareFadeOut = group(s.Flare)
    alpha(s.FlareFadeOut, 1, 0, 1.0, 1, nil, "OUT")
    s.GhostFlashAnim = group(s.GhostFlash)
    alpha(s.GhostFlashAnim, 0, 1, 0.05, 1)
    alpha(s.GhostFlashAnim, 1, 0, 0.45, 2, nil, "OUT")
    s.HitGlowAnim = group(s.HitGlow)
    alpha(s.HitGlowAnim, 0, 1, 0.0, 1)
    alpha(s.HitGlowAnim, 1, 0, 1.0, 2)
    s.MaxAnim = group(s.Starburst)
    scale(s.MaxAnim, 1, 0.5, 0.1, 1)
    scale(s.MaxAnim, 1, 2, 0.5, 1, 0.34)
    alpha(s.MaxAnim, 0, 1, 0.1, 1, 0.34)
    alpha(s.MaxAnim, 1, 0, 0.9, 1, 0.44)
    do
        local r = s.MaxAnim:CreateAnimation("Rotation")
        r:SetDegrees(-76)
        r:SetDuration(1.41)
        r:SetOrder(1)
    end
    s.SheenAnim = group(s.Sheen)
    translation(s.SheenAnim, FILL_W + 60, 0, 0.6, 1, 0, "IN_OUT")
    alpha(s.SheenAnim, 0, 1, 0.1, 1)
    alpha(s.SheenAnim, 1, 0, 0.2, 1, 0.45)
    return s
end

------------------------------------------------------------------------
-- The tick bar: the client's cast bar
------------------------------------------------------------------------
local function buildFallbackTick(parent)
    local b = CreateFrame("StatusBar", nil, parent)
    b:SetStatusBarTexture("ui-castingbar-filling-standard")
    b.Background = b:CreateTexture(nil, "BACKGROUND", nil, 2)
    setAtlas(b.Background, "ui-castingbar-background", false)
    b.Background:SetPoint("TOPLEFT", -1, 1)
    b.Background:SetPoint("BOTTOMRIGHT", 1, -1)
    b.Border = b:CreateTexture(nil, "ARTWORK", nil, 4)
    setAtlas(b.Border, "ui-castingbar-frame", false)
    b.Border:SetPoint("TOPLEFT", -2, 2)
    b.Border:SetPoint("BOTTOMRIGHT", 2, -2)
    b.Flash = b:CreateTexture(nil, "OVERLAY", nil, 1)
    b.Flash:SetBlendMode("ADD")
    setAtlas(b.Flash, "ui-castingbar-full-glow-standard", false)
    b.Flash:SetPoint("TOPLEFT", -1, 1)
    b.Flash:SetPoint("BOTTOMRIGHT", 1, -1)
    b.Spark = b:CreateTexture(nil, "OVERLAY", nil, 2)
    setAtlas(b.Spark, "ui-castingbar-pip", false)
    b.Spark:SetSize(8, 20)
    b.Text = newFont(b, "OVERLAY", "GameFontHighlightSmall", "GameFontHighlight")
    b.fallback = true
    return b
end

local function buildTickBar(parent)
    local ok, b = pcall(CreateFrame, "StatusBar", nil, parent, "CastingBarFrameTemplate")
    if not ok or not b then
        b = buildFallbackTick(parent)
    else
        -- ours now: no unit, no events, no Blizzard update loop
        if b.SetUnit then pcall(b.SetUnit, b, nil) end
        b:UnregisterAllEvents()
        b:SetScript("OnEvent", nil)
        b:SetScript("OnUpdate", nil)
        b:SetScript("OnShow", nil)
        b.playCastFX = true
        for _, key in ipairs({ "TextBorder", "Icon", "BorderShield", "DropShadow", "CastTimeText" }) do
            if b[key] then b[key]:Hide() end
        end
        if b.BorderMask then b.BorderMask:SetSize(FILL_W + 16, 13) end
        if b.EnergyMask then pcall(b.EnergyMask.SetWidth, b.EnergyMask, FILL_W) end
        b.templated = true
    end
    b:SetMinMaxValues(0, 1)
    b:SetValue(0)
    b:SetSize(FILL_W, TICK_H)
    b:Show()
    if b.Flash then
        b.Flash:SetAlpha(0)
        b.Flash:Show()
    end
    b.FlashFade = group(b.Flash)
    alpha(b.FlashFade, 0, 1, 0.05, 1)
    alpha(b.FlashFade, 1, 0, 0.5, 2, nil, "OUT")
    if b.Text then
        b.Text:ClearAllPoints()
        b.Text:SetPoint("CENTER", b, "CENTER", 0, 0)
        b.Text:SetSize(FILL_W, 16)
        b.Text:SetJustifyH("CENTER")
        b.Text:Show()
    end
    return b
end

local TICK_ART = {
    gain = { fill = "ui-castingbar-filling-channel", glow = "ui-castingbar-full-glow-channel", sparkFx = "ChannelShadow" },
    decay = { fill = "ui-castingbar-filling-standard", glow = "ui-castingbar-full-glow-standard", sparkFx = "StandardGlow" },
    urgent = { fill = "ui-castingbar-interrupted", glow = "ui-castingbar-full-glow-standard", sparkFx = "StandardGlow" },
    max = { fill = "ui-castingbar-full-channel", glow = "ui-castingbar-full-glow-channel" },
    idle = { fill = "ui-castingbar-filling-standard", glow = "ui-castingbar-full-glow-standard" },
}

local function setTickArt(key)
    if view.tickArt == key then return end
    view.tickArt = key
    local art = TICK_ART[key]
    tick:SetStatusBarTexture(art.fill)
    if tick.Flash then setAtlas(tick.Flash, art.glow, false) end
    for _, fx in ipairs({ "StandardGlow", "ChannelShadow", "CraftGlow" }) do
        if tick[fx] then tick[fx]:SetShown(fx == art.sparkFx) end
    end
end

------------------------------------------------------------------------
-- The portrait: you, in 3D, or the spell icon
------------------------------------------------------------------------
local function buildPortrait(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(PORTRAIT_W, PORTRAIT_H)

    p.Background = p:CreateTexture(nil, "BACKGROUND")
    if not setAtlas(p.Background, "UI-HUD-ActionBar-IconFrame-Background", false) then
        p.Background:SetColorTexture(0, 0, 0, 0.85)
    end
    p.Background:SetPoint("TOPLEFT", 2, -2)
    p.Background:SetPoint("BOTTOMRIGHT", -2, 2)

    p.Icon = p:CreateTexture(nil, "ARTWORK")
    p.Icon:SetPoint("CENTER")
    p.Icon:SetSize(PORTRAIT_W - 4, PORTRAIT_H - 4)
    local tex = C_Spell and try(C_Spell.GetSpellTexture, ns.BUFF_ID)
    p.Icon:SetTexture(tex or "Interface\\Icons\\Spell_Nature_Swiftness")
    if p.CreateMaskTexture then
        local m = p:CreateMaskTexture()
        setAtlas(m, "UI-HUD-ActionBar-IconFrame-Mask", false)
        local size = (PORTRAIT_W - 4) * 64 / 45
        m:SetSize(size, size)
        m:SetPoint("CENTER", p.Icon, "CENTER")
        p.Icon:AddMaskTexture(m)
    end

    local ok, model = pcall(CreateFrame, "PlayerModel", nil, p)
    if ok and model then
        model:SetPoint("TOPLEFT", 3, -3)
        model:SetPoint("BOTTOMRIGHT", -3, 3)
        p.Model = model
    end

    -- the frame art sits above the model
    p.Overlay = CreateFrame("Frame", nil, p)
    p.Overlay:SetAllPoints(p)
    p.Overlay:SetFrameLevel(p:GetFrameLevel() + 3)
    p.Border = p.Overlay:CreateTexture(nil, "ARTWORK")
    setAtlas(p.Border, "UI-HUD-ActionBar-IconFrame", false)
    p.Border:SetAllPoints(p)
    p.Flash = p.Overlay:CreateTexture(nil, "OVERLAY")
    setAtlas(p.Flash, "UI-HUD-ActionBar-IconFrame-Flash", false)
    p.Flash:SetAllPoints(p)
    p.Flash:SetBlendMode("ADD")
    p.Flash:SetAlpha(0)
    p.FlashAnim = group(p.Flash)
    alpha(p.FlashAnim, 0, 1, 0.05, 1)
    alpha(p.FlashAnim, 1, 0, 0.6, 2, nil, "OUT")
    return p
end

local function modelAnim(id)
    local m = portrait and portrait.Model
    if not m or not m:IsShown() or view.modelAnim == id then return end
    view.modelAnim = id
    if m.SetAnimation then pcall(m.SetAnimation, m, id) end
end

function D.RefreshPortrait()
    if not portrait then return end
    local useModel = (db().portrait ~= "icon") and portrait.Model ~= nil
    if useModel then
        local m = portrait.Model
        local ok = pcall(m.SetUnit, m, "player")
        if ok then
            pcall(m.SetPortraitZoom, m, 0.35)
            pcall(m.SetFacing, m, -0.55)
            view.modelAnim = nil
        else
            useModel = false
        end
    end
    if portrait.Model then portrait.Model:SetShown(useModel) end
    portrait.Icon:SetShown(not useModel)
end

------------------------------------------------------------------------
-- Building, layout, lock
------------------------------------------------------------------------
local function savePosition()
    local p, _, rp, x, y = frame:GetPoint(1)
    if p then db().point = { p, "UIParent", rp, x, y } end
end

function D.ApplyLock()
    if not frame then return end
    local locked = db().locked
    frame:EnableMouse(not locked)
    frame.Unlocked:SetShown(not locked)
end

function D.Layout()
    if not frame then return end
    frame:SetScale(clamp(db().scale or 0.75, 0.4, 2))
end

function D.Build()
    local p = db().point or ns.defaults.point
    frame = CreateFrame("Frame", "PlainstrideFrame", UIParent)
    D.frame = frame
    frame:SetSize(TOTAL_W, TOTAL_H)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) if not db().locked then self:StartMoving() end end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() savePosition() end)
    frame:SetPoint(p[1], UIParent, p[3], p[4], p[5])

    -- the Edit Mode selection look while unlocked
    frame.Unlocked = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    if not setAtlas(frame.Unlocked, "editmode-actionbar-highlight-nineslice-center", false) then
        frame.Unlocked:SetColorTexture(0.2, 0.5, 1, 0.25)
    end
    frame.Unlocked:SetPoint("TOPLEFT", -6, 6)
    frame.Unlocked:SetPoint("BOTTOMRIGHT", 6, -6)

    -- everything that shakes lives on `content`; `frame` stays where you put it
    local content = CreateFrame("Frame", nil, frame)
    content:SetAllPoints(frame)
    D.content = content
    D.Shake = group(content)
    D.ShakeSteps = {}
    for i = 1, 6 do
        D.ShakeSteps[i] = translation(D.Shake, 0, 0, 0.0, i + 1, 0.05)
    end
    translation(D.Shake, 0, 0, 0.1, 1)

    portrait = buildPortrait(content)
    portrait:SetPoint("LEFT", content, "LEFT", 0, 0)
    D.portrait = portrait

    stack = buildStackBar(content)
    stack:SetPoint("TOPLEFT", content, "TOPLEFT", PORTRAIT_W + GAP, 0)
    D.stack = stack

    tick = buildTickBar(content)
    tick:SetPoint("TOPLEFT", stack, "TOPLEFT", FILL_X, -33)
    D.tick = tick

    -- floating loss on a hit, Blizzard combat text style
    local floatHolder = CreateFrame("Frame", nil, content)
    floatHolder:SetAllPoints(content)
    floatHolder:SetFrameLevel(content:GetFrameLevel() + 10)
    D.Float = newFont(floatHolder, "OVERLAY", "CombatTextFont", "GameFontNormalHuge", "GameFontNormalLarge")
    D.Float:SetTextColor(1, 0.12, 0.08)
    D.Float:SetPoint("BOTTOM", stack.Fill, "TOP", 0, 2)
    D.Float:SetAlpha(0)
    D.FloatAnim = group(D.Float)
    alpha(D.FloatAnim, 0, 1, 0.08, 1)
    scale(D.FloatAnim, 1.6, 1, 0.2, 1)
    translation(D.FloatAnim, 0, 26, 1.0, 1, 0, "OUT")
    alpha(D.FloatAnim, 1, 0, 0.5, 1, 0.5)

    D.Layout()
    D.ApplyLock()
    D.RefreshPortrait()
    D.Snap(0)
end

------------------------------------------------------------------------
-- Changes
------------------------------------------------------------------------
function D.Snap(n)
    view.shown, view.tweenFrom, view.tweenTo, view.tweenDur = n or 0, n or 0, n or 0, 0
    view.ghost = nil
end

local function shake(amp)
    if not D.Shake then return end
    local steps = { { -1, 1 }, { 1, -2 }, { 1, 2 }, { -1, -1 }, { 1, 1 }, { -1, -1 } }
    for i, step in ipairs(steps) do
        D.ShakeSteps[i]:SetOffset(step[1] * amp, step[2] * amp)
    end
    play(D.Shake)
end

function D.Animate(from, to, kind, now)
    if not frame then return end
    if to > from then
        view.tweenFrom, view.tweenTo, view.tweenStart = view.shown, to, now
        view.tweenDur = 0.5 -- Blizzard's rank bar interpolates over half a second, easing out
        if to >= MAX then
            stack.Flare:SetAlpha(0)
            play(stack.MaxAnim)
            play(stack.SheenAnim)
            play(tick.FlashFade)
        else
            stack.FlareFadeOut:Stop()
            stack.Flare:SetAlpha(1)
            play(stack.FlareFadeOut)
            play(tick.FlashFade)
            if tick.ChannelFinish then play(tick.ChannelFinish) end
        end
        return
    end
    -- losses: the fill drops at once and what was lost lingers as a ghost, then drains away
    local top = math.max(view.shown, from)
    if view.ghost and view.ghost.from > top then top = view.ghost.from end
    D.Snap(to)
    if kind == "hit" then
        local lost = from - to
        view.ghost = { from = top, to = to, start = now, hold = 0.45, dur = 0.55, atlas = "ui-castingbar-interrupted" }
        play(stack.GhostFlashAnim)
        play(stack.HitGlowAnim)
        if tick.InterruptGlowAnim then play(tick.InterruptGlowAnim) end
        shake(1 + math.min(lost, 10) * 0.25)
        D.Float:SetText("-" .. lost)
        play(D.FloatAnim)
        play(portrait.FlashAnim)
        if portrait.Model and portrait.Model:IsShown() then
            view.modelAnim = nil
            modelAnim(ANIM.WOUND)
            view.woundUntil = now + 0.6
        end
    else
        view.ghost = { from = top, to = to, start = now, hold = 0.1, dur = 0.4, atlas = "ui-castingbar-filling-standard" }
        play(tick.FlashFade)
    end
    if stack.Ghost then
        setAtlas(stack.Ghost, view.ghost.atlas, false)
    end
end

------------------------------------------------------------------------
-- Every frame
------------------------------------------------------------------------
function D.Render(now)
    if not frame then return end
    local state = ns.state
    local cfg = db()

    -- the stack value
    if view.tweenDur > 0 then
        local t = (now - view.tweenStart) / view.tweenDur
        view.shown = view.tweenFrom + (view.tweenTo - view.tweenFrom) * easeOut(t)
        if t >= 1 then view.tweenDur, view.shown = 0, view.tweenTo end
    end
    local shown = clamp(view.shown, 0, MAX)
    local p = shown / MAX
    if p > 0 then
        stack.Fill:Show()
        if stack.Mask then
            stack.Mask:SetWidth(math.max(0.01, BAR_W * p))
        else
            stack.Fill:SetWidth(math.max(0.01, FILL_W * p))
        end
    else
        stack.Fill:Hide()
        stack.Flare:SetAlpha(0)
    end

    -- the ghost of what was lost
    local g = view.ghost
    if g then
        local t = now - g.start
        if t >= g.hold + g.dur then
            view.ghost = nil
            stack.Ghost:Hide()
        else
            local drain = t <= g.hold and 0 or easeOut((t - g.hold) / g.dur)
            local top = g.from + (g.to - g.from) * drain
            local w = FILL_W * (top - shown) / MAX
            if w > 0.5 then
                stack.Ghost:ClearAllPoints()
                stack.Ghost:SetPoint("LEFT", stack.Fill, "LEFT", FILL_W * shown / MAX, 0)
                stack.Ghost:SetWidth(w)
                stack.Ghost:SetAlpha(1 - 0.5 * drain)
                stack.Ghost:Show()
            else
                stack.Ghost:Hide()
            end
        end
    end

    -- the fill flows while you run and rests while you stand
    local flowing = state.moving and (state.stacks or 0) > 0
    if flowing ~= view.flowing then
        view.flowing = flowing
        if flowing then stack.FillAnim:Play() else stack.FillAnim:Stop() end
    end

    local stacks = state.stacks
    local mark = (state.source == "estimate") and "~" or ""
    if stacks then
        stack.Text:SetText(string.format("Plainsrunning  %s%d / %d", mark, stacks, MAX))
    else
        stack.Text:SetText("Plainsrunning")
    end

    -- the tick bar
    local mode, frac, left = ns.clocks(now, stacks)
    view.mode = mode
    if math.abs(frac - view.barFrac) > 0.5 then view.barFrac = frac
    else view.barFrac = view.barFrac + (frac - view.barFrac) * 0.5 end
    local art = mode
    if mode == "decay" and left and left < 0.35 then art = "urgent" end
    if mode == "hold" then art = "gain" end
    setTickArt(TICK_ART[art] and art or "idle")
    tick:SetValue(clamp(view.barFrac, 0, 1))
    local sparkOn = (mode == "gain" or mode == "decay") and view.barFrac > 0.01 and view.barFrac < 0.99
    if tick.Spark then
        tick.Spark:ClearAllPoints()
        tick.Spark:SetPoint("CENTER", tick, "LEFT", FILL_W * clamp(view.barFrac, 0, 1), 0)
        tick.Spark:SetShown(sparkOn)
    end
    if tick.Text then
        local text = ""
        if cfg.showTimer then
            if mode == "max" then
                text = "Full speed"
            elseif mode == "gain" then
                text = (left and left > 0) and string.format("Next stack  %.1f", left) or "Next stack"
            elseif mode == "decay" then
                text = (left and left > 0) and string.format("Losing a stack  %.1f", left) or "Losing a stack"
            elseif state.source == "demo" then
                text = "Demo"
            end
        end
        tick.Text:SetText(text)
    end

    -- the 3D portrait: run, stand, or still flinching from a hit
    if view.woundUntil and now >= view.woundUntil then
        view.woundUntil = nil
        view.modelAnim = nil
    end
    if not view.woundUntil then
        modelAnim(state.moving and ANIM.RUN or ANIM.STAND)
    end

    -- quiet when there is nothing to show
    local idle = (stacks or 0) <= 0 and not state.moving and not ns.inCombat() and not state.demo
    frame:SetAlpha(idle and cfg.idleAlpha or 1)
end
