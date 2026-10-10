-- Plainstride's pieces in the window styles. Styles.lua does the choosing and the drawing
-- (Blizzard, Dark, or EllesmereUI's look); this file says what Plainstride restyles.
--
-- The bar: in Dark and EllesmereUI it is flattened the way EllesmereUI flattens the profession
-- window's own skill bar, the bar it is built from. The gold profession frame and the cast bar's
-- frame fade; each bar's band gets a dark track and a thin edge right on it, and the gold stack
-- pips become thin dark marks inside the band. Everything that moves stays as it is: the animated
-- fill, its flare, the wind streaks, the cast bar's fills, spark and glows, the hit marker, the
-- ghost and the effects at 30. Nothing is added around the bar.
-- The options live on the game's own Options > AddOns page, which keeps the game's look. The
-- window used in combat gets its frame restyled; the controls inside it are the same frame as on
-- the page, so they stay as they are.

local ADDON, ns = ...
local Styles = ns.Styles
local Try = Styles.Try

local function S() return Styles.S end

local troughs = {} -- the recolored track textures, painted again when the style's colors change

local function PaintTrough(tex)
    local r, g, b = S().GetPanelColor()
    tex:SetColorTexture(r or 0.07, g or 0.07, b or 0.08, 0.85)
end

-- The bar's empty part becomes a flat track over exactly its band. Its opacity is still the
-- Background opacity option, which sets the texture's alpha.
local function Trough(tex, band)
    tex:ClearAllPoints()
    tex:SetAllPoints(band)
    tex:SetTexCoord(0, 1, 0, 1)
    PaintTrough(tex)
    troughs[#troughs + 1] = tex
end

-- An empty frame one unit outside a band, for the style to draw its edge on. S.Panel would fade
-- every texture on a frame, so it only ever gets this empty one.
local function Edge(parent, band, level)
    local edge = CreateFrame("Frame", nil, parent)
    edge:SetPoint("TOPLEFT", band, "TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", band, "BOTTOMRIGHT", 1, -1)
    edge:SetFrameLevel(level)
    S().Panel(edge, { noBg = true })
    return edge
end

-- A border frame a style adds sits above everything in the window; put the button back on top.
local function RaiseAbove(button, win)
    local level = win:GetFrameLevel() or 1
    for _, child in ipairs({ win:GetChildren() }) do
        if child ~= button then level = math.max(level, child:GetFrameLevel() or 0) end
    end
    button:SetFrameLevel(level + 5)
end

function ns.SkinBar()
    local D = ns.Display
    local stack, tick = D and D.stack, D and D.tick
    if not S() or not stack or stack.psFlat then return end
    stack.psFlat = true
    Try("stack bar", function()
        stack.Border:SetAlpha(0) -- the profession frame
        Trough(stack.Background, stack.FillArea)
        local h = stack.FillArea:GetHeight() or 18
        if h <= 0 then h = 18 end
        for i, mark in ipairs(stack.Dividers or {}) do
            local major = i % 5 == 0
            mark:SetTexCoord(0, 1, 0, 1)
            mark:SetColorTexture(0, 0, 0, major and 0.9 or 0.5)
            mark:SetSize(major and 2 or 1, major and h or h - 6)
            mark:SetAlpha(1)
        end
        stack.psEdge = Edge(stack.Over, stack.FillArea, stack.Over:GetFrameLevel() + 1)
        S().Font(stack.Text)
        S().Font(stack.Timer)
    end)
    for _, bar in ipairs({ tick, D.loss }) do
        Try("cast bar", function()
            if bar.Border then bar.Border:SetAlpha(0) end
            if bar.Background then Trough(bar.Background, bar) end
            bar.psEdge = Edge(bar, bar, bar:GetFrameLevel() + 2)
            if bar.Text then S().Font(bar.Text) end
        end)
    end
    -- the gain bar's five parts: thin dark marks, like the stack marks
    for _, mark in ipairs(tick and tick.psMarks or {}) do
        mark:SetTexCoord(0, 1, 0, 1)
        mark:SetColorTexture(0, 0, 0, 0.6)
        mark:SetWidth(1)
    end
end

-- The options window, used when the game's page cannot open (in combat).
function ns.SkinWindow(win)
    if not S() or type(win) ~= "table" then return end
    Try("options window", function()
        S().Shell(win)
        if type(win.Inset) == "table" then S().Inset(win.Inset) end
        if type(win.PortraitContainer) == "table" then S().FadeRegions(win.PortraitContainer) end
        local title = win.TitleText or (type(win.TitleContainer) == "table" and win.TitleContainer.TitleText)
        if type(title) == "table" then S().Font(title) end
        local close = win.CloseButton or _G.PlainstrideOptionsCloseButton or win.psClose
        if type(close) == "table" then
            S().CloseButton(close)
            RaiseAbove(close, win)
        end
    end)
end

local function SkinAll(S)
    ns.SkinBar()
    if PlainstrideOptions then ns.SkinWindow(PlainstrideOptions) end
    -- Flat bars take the style's accent color.
    if ns.Display and ns.Display.ApplyFill then Try("flat fill", ns.Display.ApplyFill) end
    S.OnLooksChanged(function()
        for _, tex in ipairs(troughs) do Try("track color", PaintTrough, tex) end
        if ns.Display and ns.Display.ApplyFill then Try("flat fill", ns.Display.ApplyFill) end
    end)
end

Styles.Setup({
    addon = ADDON,
    title = "Plainstride",
    db = function() return ns.DB and ns.DB() end,
    report = ns.report,
    accent = { 0.56, 0.86, 0.4 }, -- the green of "Next stack"
    skin = SkinAll,
})
