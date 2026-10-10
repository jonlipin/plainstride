-- Window styles, shared by Jon's addons. The same file ships in each addon and keeps
-- everything on that addon's own namespace, so the copies never meet.
--   Blizzard     the interface's own art; nothing here draws anything.
--   Dark         a flat dark style drawn by this file. Needs no other addon.
--   EllesmereUI  that addon's look, through its public skinning API (SKINNING_API.md in
--                EllesmereUI). "Automatic" uses it when EllesmereUI's Blizzard Skins+ is running.
-- An addon restyles its windows through one set of drawing calls (S.Shell, S.Button, ...).
-- EllesmereUI hands over its own; Dark below has the same names and behaves the same way, so
-- the addon writes its restyle once. A restyle fades the original art rather than keeping it,
-- so leaving one style for another takes a reload; the player is offered one.
--
-- From the addon's own skin file:
--   ns.Styles.Setup({
--       addon  = ADDON,                          -- folder name, registered with EllesmereUI
--       title  = "Shard Grid",                   -- shown in the reload prompt
--       db     = function() return ns.DB() end,  -- the settings table: .style and .darkAlpha
--       report = ns.report,                      -- optional: gets "skin" and "skin error: ..." lines
--       accent = { 0.58, 0.26, 0.9 },            -- optional: Dark's accent color
--       skin   = function(S) ... end,            -- restyle everything built so far
--   })
-- Later-built frames check ns.Styles.S (nil while the Blizzard look is in use). After the
-- player changes db.style, call ns.Styles.Changed().

local _, ns = ...
local Styles = { VERSION = 2 }
ns.Styles = Styles

local FLAT = "Interface\\Buttons\\WHITE8X8"
local NAMES = { auto = "Automatic", blizzard = "Blizzard", dark = "Dark", eui = "EllesmereUI" }
local ORDER = { "auto", "blizzard", "dark" }

local cfg = {}       -- what Setup was given
local applied        -- the style drawn this session: nil (Blizzard), "dark" or "eui"
local euiSkin        -- EllesmereUI's drawing calls, once it hands them over
local report = {}

local function DB()
	local db = cfg.db and cfg.db()
	return type(db) == "table" and db or nil
end

-- One piece failing must not leave the rest unstyled. Failures go to the addon's report.
function Styles.Try(what, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then report["skin error: " .. what] = tostring(err) end
	return ok
end
local Try = Styles.Try

-- Secure frames are locked in combat. Anything reaching one then waits for combat to end.
local waiting = {}
local waiter = CreateFrame("Frame")
waiter:SetScript("OnEvent", function(self)
	self:UnregisterEvent("PLAYER_REGEN_ENABLED")
	local list = waiting
	waiting = {}
	for _, job in ipairs(list) do Try(job[1], job[2]) end
end)
function Styles.OutOfCombat(what, fn)
	if InCombatLockdown() then
		waiting[#waiting + 1] = { what, fn }
		waiter:RegisterEvent("PLAYER_REGEN_ENABLED")
	else
		Try(what, fn)
	end
end

-- ---- Dark --------------------------------------------------------------------------------------

local Dark = { apiVersion = 3 }
Styles.Dark = Dark
local done = setmetatable({}, { __mode = "k" }) -- what Dark has already drawn on
local backdrops = {}                            -- window backdrops, for the opacity setting
local looksChanged = {}
local TITLE_H = 24
local PANEL = { 0.07, 0.07, 0.08, 0.92 }
local INSET = { 0.025, 0.025, 0.03, 0.9 }

local function Accent()
	local c = cfg.accent
	if type(c) == "table" then return c[1] or 0.58, c[2] or 0.26, c[3] or 0.9 end
	return 0.58, 0.26, 0.9
end

local function DarkAlpha()
	local db = DB()
	return db and type(db.darkAlpha) == "number" and db.darkAlpha or 0.92
end

-- The opacity goes into the backdrop's colors: set on the texture as a whole it had no effect.
local function PaintBackdrop(tex, alpha)
	local ok = pcall(function()
		tex:SetColorTexture(1, 1, 1, 1)
		tex:SetGradient("VERTICAL", CreateColor(0.035, 0.035, 0.045, alpha), CreateColor(0.085, 0.08, 0.1, alpha))
	end)
	if not ok then tex:SetColorTexture(0.05, 0.05, 0.06, alpha) end
end

function Styles.SetDarkAlpha(alpha)
	for _, tex in ipairs(backdrops) do PaintBackdrop(tex, alpha) end
	for _, fn in ipairs(looksChanged) do pcall(fn) end
end

-- One screen pixel at this frame's scale, so the edges stay crisp.
local function Pixel(frame)
	if PixelUtil and PixelUtil.GetNearestPixelSize and frame.GetEffectiveScale then
		local ok, px = pcall(PixelUtil.GetNearestPixelSize, 1, frame:GetEffectiveScale(), 1)
		if ok and type(px) == "number" and px > 0 then return px end
	end
	return 1
end

local function IsTable(x) return type(x) == "table" end

-- Art is faded, never hidden, so the interface's own code keeps working on it.
local function FadeTextures(frame, keep)
	if not IsTable(frame) or not frame.GetRegions then return end
	for _, region in ipairs({ frame:GetRegions() }) do
		if region.IsObjectType and region:IsObjectType("Texture") and not (keep and keep[region]) then
			region:SetAlpha(0)
		end
	end
end

local function FadeButtonArt(button, keep)
	FadeTextures(button, keep)
	for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture", "GetDisabledTexture" }) do
		local tex = button[getter] and button[getter](button)
		if IsTable(tex) and tex.SetAlpha and not (keep and keep[tex]) then tex:SetAlpha(0) end
	end
end

-- A 1px line round `target`, drawn on `owner`. `out` moves it outward by whole pixels: 1 sits
-- just outside, 0 on the edge, -1 just inside.
local function Outline(owner, target, layer, r, g, b, a, out)
	local px = Pixel(owner)
	local d = (out or 0) * px
	local lines = {}
	local function Line()
		local tex = owner:CreateTexture(nil, layer, nil, 7)
		tex:SetColorTexture(r, g, b, a)
		lines[#lines + 1] = tex
		return tex
	end
	local top = Line()
	top:SetPoint("TOPLEFT", target, "TOPLEFT", -d, d)
	top:SetPoint("TOPRIGHT", target, "TOPRIGHT", d, d)
	top:SetHeight(px)
	local bottom = Line()
	bottom:SetPoint("BOTTOMLEFT", target, "BOTTOMLEFT", -d, -d)
	bottom:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", d, -d)
	bottom:SetHeight(px)
	local left = Line()
	left:SetPoint("TOPLEFT", target, "TOPLEFT", -d, d)
	left:SetPoint("BOTTOMLEFT", target, "BOTTOMLEFT", -d, -d)
	left:SetWidth(px)
	local right = Line()
	right:SetPoint("TOPRIGHT", target, "TOPRIGHT", d, d)
	right:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", d, -d)
	right:SetWidth(px)
	return lines
end
Styles.Outline = Outline

-- Keys named in keepKeys ({"Icon"}) are left as they are.
local function KeepSet(frame, keepKeys)
	local keep = {}
	for _, key in ipairs(keepKeys or {}) do
		local region = frame[key]
		if IsTable(region) then keep[region] = true end
	end
	return keep
end

function Dark.FadeRegions(frame)
	FadeTextures(frame)
	if IsTable(frame) and IsTable(frame.NineSlice) then FadeTextures(frame.NineSlice) end
end

local NINESLICE_PIECES = { "TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner",
	"TopEdge", "BottomEdge", "LeftEdge", "RightEdge", "Center" }
function Dark.FadeNineSlice(nineSlice)
	if not IsTable(nineSlice) then return end
	FadeTextures(nineSlice)
	for _, key in ipairs(NINESLICE_PIECES) do
		local piece = nineSlice[key]
		if IsTable(piece) and piece.SetAlpha then piece:SetAlpha(0) end
	end
	if nineSlice.SetAlpha then nineSlice:SetAlpha(0) end
end

-- A template's own background, which on this client is a whole frame (DefaultPanelFlatTemplate's
-- Bg), is hidden and kept hidden; a plain texture background is faded.
local function HideBackground(frame)
	local back = frame.Bg
	if not IsTable(back) then return end
	if back.SetAlpha then back:SetAlpha(0) end
	if back.IsObjectType and back:IsObjectType("Texture") then return end
	if back.Hide then
		back:Hide()
		if back.HookScript then back:HookScript("OnShow", back.Hide) end
	end
end

function Dark.Inset(inset)
	if not IsTable(inset) or done[inset] then return end
	done[inset] = true
	Dark.FadeRegions(inset)
	HideBackground(inset)
	Dark.FadeNineSlice(inset.NineSlice)
end

-- The window: a dark gradient, a title strip with an accent rule under it, and a black edge
-- with a faint light line just inside. opts.noTopBar skips the strip, opts.bottomBar = true or
-- a height adds a matching footer strip, opts.noBorder skips the edge.
function Dark.Shell(frame, opts)
	if not IsTable(frame) or done[frame] then return end
	done[frame] = true
	opts = opts or {}
	FadeTextures(frame)
	if IsTable(frame.TitleContainer) then FadeTextures(frame.TitleContainer) end
	Dark.FadeNineSlice(frame.NineSlice)
	HideBackground(frame)

	local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
	bg:SetAllPoints()
	PaintBackdrop(bg, DarkAlpha())
	backdrops[#backdrops + 1] = bg

	if not opts.noTopBar then
		local bar = frame:CreateTexture(nil, "BACKGROUND", nil, -5)
		bar:SetPoint("TOPLEFT")
		bar:SetPoint("TOPRIGHT")
		bar:SetHeight(TITLE_H)
		bar:SetColorTexture(0, 0, 0, 0.45)
		local r, g, b = Accent()
		local rule = frame:CreateTexture(nil, "BORDER")
		rule:SetPoint("TOPLEFT", 0, -TITLE_H)
		rule:SetPoint("TOPRIGHT", 0, -TITLE_H)
		rule:SetHeight(Pixel(frame))
		rule:SetColorTexture(r, g, b, 0.7)
	end
	if opts.bottomBar then
		local foot = frame:CreateTexture(nil, "BACKGROUND", nil, -5)
		foot:SetPoint("BOTTOMLEFT")
		foot:SetPoint("BOTTOMRIGHT")
		foot:SetHeight(type(opts.bottomBar) == "number" and opts.bottomBar or 25)
		foot:SetColorTexture(0, 0, 0, 0.45)
	end
	if not opts.noBorder then
		Outline(frame, frame, "BORDER", 0, 0, 0, 1, 0)
		Outline(frame, frame, "BORDER", 1, 1, 1, 0.06, -1)
	end

	local title = frame.TitleText or (IsTable(frame.TitleContainer) and frame.TitleContainer.TitleText)
	if IsTable(title) and title.SetTextColor then title:SetTextColor(1, 1, 1) end
end

-- A flat panel for sub-frames and popups. Like EllesmereUI's, it fades every texture already on
-- the frame. opts.inset is darker, opts.noBg strips only, opts.noBorder skips the edge.
function Dark.Panel(frame, opts)
	if not IsTable(frame) or done[frame] then return end
	done[frame] = true
	opts = opts or {}
	Dark.FadeRegions(frame)
	HideBackground(frame)
	if not opts.noBg then
		local c = opts.inset and INSET or PANEL
		local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
		bg:SetAllPoints()
		if opts.shade then bg:SetColorTexture(0, 0, 0, 0.25) else bg:SetColorTexture(c[1], c[2], c[3], c[4]) end
	end
	if not opts.noBorder then Outline(frame, frame, "BORDER", 0, 0, 0, 1, 0) end
end

-- A flat button with a black edge. Lighter under the mouse, darker while held, dimmed while
-- disabled. The label is left alone, as EllesmereUI leaves it.
function Dark.Button(button, keepKeys)
	if not IsTable(button) or done[button] then return end
	done[button] = true
	FadeButtonArt(button, KeepSet(button, keepKeys))

	local bg = button:CreateTexture(nil, "BACKGROUND", nil, -7)
	bg:SetAllPoints()
	local function Paint(shade) bg:SetColorTexture(shade, shade, shade + 0.015, 0.95) end
	Paint(0.13)
	Outline(button, button, "BORDER", 0, 0, 0, 1, 0)

	local hl = button:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.08)

	if button.HookScript then
		button:HookScript("OnMouseDown", function() Paint(0.08) end)
		button:HookScript("OnMouseUp", function() Paint(0.13) end)
		button:HookScript("OnDisable", function() bg:SetAlpha(0.5) end)
		button:HookScript("OnEnable", function() bg:SetAlpha(1) end)
	end
	if button.IsEnabled and not button:IsEnabled() then bg:SetAlpha(0.5) end
end

function Dark.WhiteButtonLabel(button)
	if IsTable(button) and button.SetNormalFontObject and GameFontHighlight then
		button:SetNormalFontObject(GameFontHighlight)
		if button.SetHighlightFontObject then button:SetHighlightFontObject(GameFontHighlight) end
	end
end

function Dark.StateButtonLabel(button)
	Dark.WhiteButtonLabel(button)
	if IsTable(button) and button.SetDisabledFontObject and GameFontDisable then
		button:SetDisabledFontObject(GameFontDisable)
	end
end

-- A near-black field with an edge. opts.padInput moves the box 6px left and its text 6px in,
-- so the text keeps its place with room before the edge; opts.noBorder skips the edge.
function Dark.EditBox(box, opts)
	if not IsTable(box) or done[box] then return end
	done[box] = true
	opts = opts or {}
	FadeTextures(box)
	for _, key in ipairs({ "Left", "Middle", "Right" }) do
		local part = box[key]
		if IsTable(part) and part.SetAlpha then part:SetAlpha(0) end
	end
	local bg = box:CreateTexture(nil, "BACKGROUND", nil, -6)
	bg:SetPoint("TOPLEFT", -4, 1)
	bg:SetPoint("BOTTOMRIGHT", 1, -1)
	bg:SetColorTexture(0, 0, 0, 0.55)
	if not opts.noBorder then Outline(box, bg, "BORDER", 0, 0, 0, 1, 0) end
	if opts.padInput and box.GetNumPoints and (box:GetNumPoints() or 0) > 0 and box.GetTextInsets then
		local point, rel, relPoint, x, y = box:GetPoint(1)
		if point and type(x) == "number" then
			box:SetPoint(point, rel, relPoint, x - 6, y)
			local l, r, t, b = box:GetTextInsets()
			box:SetTextInsets((l or 0) + 6, r or 0, t or 0, b or 0)
		end
	end
end

-- A dark box with an accent square for the check. opts.stockCheck keeps the game's check mark.
function Dark.Checkbox(check, opts)
	if not IsTable(check) or done[check] then return end
	done[check] = true
	opts = opts or {}
	local mark = check.GetCheckedTexture and check:GetCheckedTexture()
	local disabledMark = check.GetDisabledCheckedTexture and check:GetDisabledCheckedTexture()
	local keep = {}
	if IsTable(mark) then keep[mark] = true end
	if IsTable(disabledMark) then keep[disabledMark] = true end
	FadeButtonArt(check, keep)

	local box = check:CreateTexture(nil, "BACKGROUND", nil, -6)
	box:SetSize(16, 16)
	box:SetPoint("CENTER")
	box:SetColorTexture(0.02, 0.02, 0.025, 0.9)
	Outline(check, box, "BORDER", 0, 0, 0, 1, 0)
	local hl = check:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(box)
	hl:SetColorTexture(1, 1, 1, 0.08)

	if not opts.stockCheck then
		local r, g, b = Accent()
		for _, tex in ipairs({ mark, disabledMark }) do
			if IsTable(tex) and tex.SetTexture then
				tex:SetTexture(FLAT)
				tex:ClearAllPoints()
				tex:SetSize(10, 10)
				tex:SetPoint("CENTER", box)
			end
		end
		if IsTable(mark) then mark:SetVertexColor(r, g, b) end
		if IsTable(disabledMark) then disabledMark:SetVertexColor(0.45, 0.45, 0.45) end
	end
end

-- Flat, with its own arrow and text left in place.
function Dark.Dropdown(dropdown)
	if not IsTable(dropdown) then return end
	Dark.Button(dropdown, { "Arrow", "Text", "Icon" })
end

-- The arrows and track art fade; the thumb becomes a thin white strip. Scrolling is untouched.
function Dark.ScrollBar(bar)
	if not IsTable(bar) or done[bar] then return end
	done[bar] = true
	local function Walk(frame, depth)
		if depth > 3 or not IsTable(frame) then return end
		FadeButtonArt(frame)
		if frame.GetChildren then
			for _, child in ipairs({ frame:GetChildren() }) do Walk(child, depth + 1) end
		end
	end
	Walk(bar, 0)
	local thumb = (IsTable(bar.Track) and bar.Track.Thumb) or bar.ThumbTexture
		or (bar.GetThumbTexture and bar:GetThumbTexture())
	if not IsTable(thumb) then return end
	if thumb.IsObjectType and thumb:IsObjectType("Texture") then
		thumb:SetAlpha(1)
		thumb:SetColorTexture(1, 1, 1, 0.35)
		thumb:SetWidth(4)
	elseif thumb.CreateTexture then
		local strip = thumb:CreateTexture(nil, "OVERLAY")
		strip:SetPoint("TOP")
		strip:SetPoint("BOTTOM")
		strip:SetWidth(4)
		strip:SetColorTexture(1, 1, 1, 0.35)
	end
end

-- Tabs: a flat plate, with an accent line under the selected one. Selection follows the game's
-- own tab functions; SetTabSelection overrides it for tabs an addon switches itself.
local tabs = setmetatable({}, { __mode = "k" })
local tabOverride = setmetatable({}, { __mode = "k" })
local tabHooked = false

local function TabSelected(tab)
	local forced = tabOverride[tab]
	if forced ~= nil then return forced end
	if tab.isSelected ~= nil then return tab.isSelected and true or false end
	if tab.selected ~= nil then return tab.selected and true or false end
	-- The game's PanelTemplates disables the selected tab.
	return tab.IsEnabled and not tab:IsEnabled() or false
end

local function PaintTab(tab)
	local parts = tabs[tab]
	if not parts then return end
	local on = TabSelected(tab)
	parts.line:SetShown(on)
	parts.bg:SetColorTexture(on and 0.16 or 0.1, on and 0.16 or 0.1, on and 0.18 or 0.115, 0.95)
	local text = tab.Text or (tab.GetFontString and tab:GetFontString())
	if IsTable(text) and text.SetTextColor then
		if on then text:SetTextColor(1, 1, 1) else text:SetTextColor(0.72, 0.72, 0.75) end
	end
end

local function HookTabs()
	if tabHooked then return end
	tabHooked = true
	local function Again() for tab in pairs(tabs) do PaintTab(tab) end end
	for _, name in ipairs({ "PanelTemplates_SelectTab", "PanelTemplates_DeselectTab", "PanelTemplates_SetTab", "PanelTemplates_UpdateTabs" }) do
		if type(_G[name]) == "function" and hooksecurefunc then hooksecurefunc(name, Again) end
	end
end

function Dark.Tab(tab)
	if not IsTable(tab) or done[tab] then return end
	done[tab] = true
	FadeButtonArt(tab, KeepSet(tab, { "Icon", "Text" }))
	local bg = tab:CreateTexture(nil, "BACKGROUND", nil, -6)
	bg:SetAllPoints()
	Outline(tab, tab, "BORDER", 0, 0, 0, 1, 0)
	local r, g, b = Accent()
	local line = tab:CreateTexture(nil, "OVERLAY")
	line:SetPoint("BOTTOMLEFT", 1, 1)
	line:SetPoint("BOTTOMRIGHT", -1, 1)
	line:SetHeight(2)
	line:SetColorTexture(r, g, b, 1)
	local hl = tab:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.06)
	tabs[tab] = { bg = bg, line = line }
	HookTabs()
	if tab.HookScript then
		tab:HookScript("OnEnable", PaintTab)
		tab:HookScript("OnDisable", PaintTab)
		tab:HookScript("OnShow", PaintTab)
	end
	if type(tab.SetTabSelected) == "function" and hooksecurefunc then hooksecurefunc(tab, "SetTabSelected", PaintTab) end
	PaintTab(tab)
end

function Dark.SetTabSelection(tab, selected)
	if not IsTable(tab) then return end
	tabOverride[tab] = selected
	PaintTab(tab)
end

-- An X of two thin strokes, gray at rest and red under the mouse.
local function Strokes(button, angles, length)
	local strokes = {}
	local px = Pixel(button)
	for _, angle in ipairs(angles) do
		local stroke = button:CreateTexture(nil, "OVERLAY")
		stroke:SetColorTexture(1, 1, 1, 1)
		stroke:SetSize(length, px * 1.5)
		stroke:SetPoint("CENTER")
		stroke:SetRotation(math.rad(angle))
		stroke:SetVertexColor(0.72, 0.72, 0.76)
		strokes[#strokes + 1] = stroke
	end
	return strokes
end

function Dark.CloseButton(button)
	if not IsTable(button) or done[button] then return end
	done[button] = true
	FadeButtonArt(button)
	local strokes = Strokes(button, { 45, -45 }, 12)
	local function Tint(r, g, b) for _, stroke in ipairs(strokes) do stroke:SetVertexColor(r, g, b) end end
	if button.HookScript then
		button:HookScript("OnEnter", function() Tint(1, 0.35, 0.35) end)
		button:HookScript("OnLeave", function() Tint(0.72, 0.72, 0.76) end)
	end
end

-- Previous and next page: a flat button with a chevron.
function Dark.PageButton(button, direction)
	if not IsTable(button) or done[button] then return end
	Dark.Button(button)
	local left = direction == "<"
	local strokes = {}
	local px = Pixel(button)
	for i, angle in ipairs({ 45, -45 }) do
		local stroke = button:CreateTexture(nil, "OVERLAY")
		stroke:SetColorTexture(1, 1, 1, 1)
		stroke:SetSize(7, px * 1.5)
		local dy = (i == 1) and 2 or -2
		stroke:SetPoint("CENTER", left and -1 or 1, dy)
		stroke:SetRotation(math.rad(left and angle or -angle))
		stroke:SetVertexColor(0.85, 0.85, 0.88)
		strokes[#strokes + 1] = stroke
	end
	if button.HookScript then
		button:HookScript("OnDisable", function() for _, s in ipairs(strokes) do s:SetAlpha(0.35) end end)
		button:HookScript("OnEnable", function() for _, s in ipairs(strokes) do s:SetAlpha(1) end end)
	end
end

-- The bevel is cropped off and a black pixel edge drawn round the icon. A masked icon cannot be
-- cropped, so it is left as it is (the same rule EllesmereUI follows).
local edges = setmetatable({}, { __mode = "k" })

local function QualityColor(quality)
	if type(quality) ~= "number" then return 0, 0, 0 end
	local r, g, b
	if C_Item and C_Item.GetItemQualityColor then
		local ok, cr, cg, cb = pcall(C_Item.GetItemQualityColor, quality)
		if ok then r, g, b = cr, cg, cb end
	end
	if not r and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality] then
		local c = ITEM_QUALITY_COLORS[quality]
		r, g, b = c.r, c.g, c.b
	end
	if not r or quality <= 1 then return 0, 0, 0 end -- poor and common keep the plain black edge
	return r, g, b
end

function Dark.SquareIcon(icon, parent, quality)
	if not IsTable(icon) then return end
	if not done[icon] then
		if icon.GetNumMaskTextures and (icon:GetNumMaskTextures() or 0) > 0 then return end
		if not pcall(icon.SetTexCoord, icon, 0.08, 0.92, 0.08, 0.92) then return end
		done[icon] = true
		if IsTable(parent) then edges[icon] = Outline(parent, icon, "BORDER", 0, 0, 0, 1, 1) end
	end
	if quality ~= nil and edges[icon] then
		local r, g, b = QualityColor(quality)
		for _, line in ipairs(edges[icon]) do line:SetColorTexture(r, g, b, 1) end
	end
	return true
end

-- A column-header bar: its art fades and each header gets a thin rule under it.
function Dark.SortHeaderBar(list)
	if not IsTable(list) or done[list] then return end
	done[list] = true
	local bar = IsTable(list.HeaderContainer) and list.HeaderContainer or list
	FadeTextures(bar)
	if bar.GetChildren then
		for _, header in ipairs({ bar:GetChildren() }) do
			FadeButtonArt(header)
			local rule = header:CreateTexture(nil, "BORDER")
			rule:SetPoint("BOTTOMLEFT")
			rule:SetPoint("BOTTOMRIGHT")
			rule:SetHeight(Pixel(header))
			rule:SetColorTexture(1, 1, 1, 0.12)
		end
	end
end

-- Dark keeps the interface's own fonts; a color passed in is still applied.
function Dark.Font(fs, r, g, b)
	if IsTable(fs) and r and fs.SetTextColor then fs:SetTextColor(r, g or r, b or r) end
end

function Dark.White(fs, r, g, b)
	if IsTable(fs) and fs.SetTextColor then fs:SetTextColor(r or 1, g or 1, b or 1) end
end

function Dark.ApplyBarFill(bar)
	if not IsTable(bar) or not bar.SetStatusBarTexture then return end
	bar:SetStatusBarTexture(FLAT)
	if bar.SetStatusBarColor then bar:SetStatusBarColor(Accent()) end
end

function Dark.IsEnabled() return applied == "dark" end
function Dark.GetStyle() return "dark" end
function Dark.GetAccentColor() return Accent() end
function Dark.GetPanelColor() return PANEL[1], PANEL[2], PANEL[3], DarkAlpha() end
function Dark.GetFont()
	local path = GameFontNormal and GameFontNormal.GetFont and GameFontNormal:GetFont()
	return path or STANDARD_TEXT_FONT, ""
end
function Dark.OnLooksChanged(fn)
	if type(fn) == "function" then looksChanged[#looksChanged + 1] = fn end
end

-- ---- choosing ----------------------------------------------------------------------------------

local function Chosen()
	local db = DB()
	local style = db and db.style
	if style == "blizzard" or style == "dark" then return style end
	return "auto"
end

-- What the chosen style comes to right now. Automatic is EllesmereUI when it has handed its
-- drawing calls over, and Blizzard otherwise.
local function Wanted()
	local chosen = Chosen()
	if chosen == "auto" then return euiSkin and "eui" or "blizzard" end
	return chosen
end

local function Describe()
	if applied == "eui" then
		local style = euiSkin.GetStyle and euiSkin.GetStyle()
		return "EllesmereUI" .. (style and (" (" .. tostring(style) .. " style)") or "")
	elseif applied == "dark" then
		return "Dark"
	elseif Chosen() == "blizzard" then
		return "Blizzard (chosen in the options)"
	elseif not (EllesmereUI and EllesmereUI.RegisterSkin) then
		return "Blizzard (EllesmereUI is not loaded)"
	elseif type(EllesmereUI._DispatchSkinRegistration) ~= "function" then
		return "Blizzard (EllesmereUI's Blizzard Skins+ module is off)"
	else
		return "Blizzard (switched off for " .. tostring(cfg.title) .. " in EllesmereUI's options)"
	end
end

local function UpdateStatus()
	local text = Describe()
	local wanted = Wanted()
	if wanted ~= (applied or "blizzard") then
		text = text .. ", " .. NAMES[wanted] .. " after a /reload"
	end
	report["skin"] = text
end

local function Apply(style)
	if applied or style == "blizzard" or not cfg.skin then return end
	Styles.S = (style == "eui") and euiSkin or Dark
	applied = style
	Try("restyle", cfg.skin, Styles.S, style)
end

function Styles.Applied() return applied end
function Styles.Name(style) return NAMES[style] or NAMES.auto end

local function Reload()
	if C_UI and C_UI.Reload then C_UI.Reload() elseif ReloadUI then ReloadUI() end
end

-- A small window of the addon's own rather than a StaticPopup, so the game's shared popups are
-- never touched by addon code.
local prompt
local function ReloadPrompt()
	if prompt then return prompt end
	local name = (cfg.addon or "Addon") .. "ReloadPrompt"
	local frame
	for _, template in ipairs({ "DefaultPanelFlatTemplate", "BackdropTemplate" }) do
		local ok, made = pcall(CreateFrame, "Frame", name, UIParent, template)
		if ok and made then frame = made break end
	end
	frame = frame or CreateFrame("Frame", name, UIParent)
	if frame.SetBackdrop and not IsTable(frame.NineSlice) then
		frame:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 14,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		frame:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
	end
	frame:SetSize(330, 112)
	frame:SetPoint("CENTER", 0, 120)
	frame:SetFrameStrata("FULLSCREEN_DIALOG")
	frame:SetToplevel(true)
	frame:EnableMouse(true)
	frame:Hide()
	if UISpecialFrames then table.insert(UISpecialFrames, name) end -- Esc closes it

	local container = frame.TitleContainer
	local title = IsTable(container) and container.TitleText
	if not IsTable(title) then
		title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOP", 0, -6)
	end
	title:SetText(cfg.title or "")

	frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	frame.text:SetPoint("TOPLEFT", 16, -34)
	frame.text:SetPoint("TOPRIGHT", -16, -34)
	frame.text:SetJustifyH("CENTER")

	local function MakeButton(label)
		local ok, button = pcall(CreateFrame, "Button", nil, frame, "UIPanelButtonTemplate")
		if not (ok and button) then
			button = CreateFrame("Button", nil, frame)
			local text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			text:SetPoint("CENTER")
			if button.SetFontString then button:SetFontString(text) end
		end
		button:SetText(label)
		return button
	end

	frame.reload = MakeButton("Reload now")
	frame.reload:SetSize(120, 22)
	frame.reload:SetPoint("BOTTOMRIGHT", frame, "BOTTOM", -4, 14)
	frame.reload:SetScript("OnClick", Reload)

	frame.later = MakeButton("Later")
	frame.later:SetSize(120, 22)
	frame.later:SetPoint("BOTTOMLEFT", frame, "BOTTOM", 4, 14)
	frame.later:SetScript("OnClick", function() frame:Hide() end)

	-- In whatever style is drawn now, like the rest of the addon.
	local S = Styles.S
	if S then
		Try("reload prompt", function()
			S.Shell(frame)
			S.Font(title)
			S.Font(frame.text)
			for _, button in ipairs({ frame.reload, frame.later }) do
				S.Button(button)
				S.WhiteButtonLabel(button)
			end
		end)
	end
	prompt = frame
	return frame
end
Styles.ReloadPrompt = ReloadPrompt

-- From Blizzard to anything else is drawn at once. Anything else needs a reload, since the art a
-- restyle fades is not brought back; the prompt offers one, and goes away again if the choice
-- comes back to what is drawn.
function Styles.Changed()
	if not applied then Apply(Wanted()) end
	UpdateStatus()
	local wanted = Wanted()
	if wanted ~= (applied or "blizzard") then
		local frame = ReloadPrompt()
		frame.text:SetText(("Switching %s to %s takes a reload of the interface. Until then it stays %s."):format(
			tostring(cfg.title), NAMES[wanted], NAMES[applied or "blizzard"]))
		frame:Show()
	elseif prompt then
		prompt:Hide()
	end
end

-- One line for an options page saying what is in use and what a reload would change.
function Styles.Note()
	UpdateStatus()
	local wanted = Wanted()
	local now = NAMES[applied or "blizzard"]
	if wanted ~= (applied or "blizzard") then
		return ("|cffffd100Type /reload to switch to %s.|r In use until then: %s."):format(NAMES[wanted], now)
	end
	if Chosen() == "auto" and applied ~= "eui" then
		local reason = Describe():match("%((.+)%)")
		return "In use: " .. now .. (reason and (" (" .. reason .. ").") or ".")
	end
	return "In use: " .. now .. "."
end

function Styles.Set(style)
	local db = DB()
	if not db or not NAMES[style] or style == "eui" then return end
	db.style = style
	Styles.Changed()
end

function Styles.Cycle(step)
	local current = Chosen()
	local index = 1
	for i, style in ipairs(ORDER) do
		if style == current then index = i end
	end
	index = (index - 1 + (step or 1)) % #ORDER + 1
	Styles.Set(ORDER[index])
end

-- The tooltip text for a style control, one line per style.
Styles.HELP = {
	"Automatic: EllesmereUI's look when it is installed, otherwise Blizzard.",
	"Blizzard: the interface's own window art.",
	"Dark: a flat dark style built in. Needs no other addon.",
}

-- Every texture still drawing on a window, with what it really shows (its own alpha, its
-- frame's and its color's), for finding art a restyle did not reach. `skip` frames are passed by.
function Styles.Probe(win, out, skip)
	if not IsTable(win) or not win.GetRegions then return end
	skip = skip or {}
	local ours = {}
	for _, tex in ipairs(backdrops) do ours[tex] = true end
	local function Walk(frame, path, depth)
		if depth > 6 or skip[frame] then return end
		for _, region in ipairs({ frame:GetRegions() }) do
			if region.IsObjectType and region:IsObjectType("Texture") and region:IsVisible() then
				local alpha = (region:GetAlpha() or 1) * (frame.GetEffectiveAlpha and frame:GetEffectiveAlpha() or 1)
				local _, _, _, colorAlpha = region:GetVertexColor()
				alpha = alpha * (colorAlpha or 1)
				if alpha > 0.02 then
					local art = (region.GetAtlas and region:GetAtlas()) or (region.GetTexture and region:GetTexture()) or "color"
					local w, h = region:GetSize()
					local layer, sub = region:GetDrawLayer()
					local name = region.GetDebugName and region:GetDebugName() or ""
					out(("%s %s %s %s:%s a=%.2f %dx%d %s"):format(path, name, ours[region] and "[Dark backdrop]" or "",
						tostring(layer), tostring(sub), alpha, math.floor((w or 0) + 0.5), math.floor((h or 0) + 0.5), tostring(art)))
				end
			end
		end
		for _, child in ipairs({ frame:GetChildren() }) do
			if child:IsVisible() then
				local key
				for k, v in pairs(frame) do if v == child and type(k) == "string" then key = k break end end
				Walk(child, path .. (key or "child") .. "(lvl " .. tostring(child:GetFrameLevel()) .. ").", depth + 1)
			end
		end
	end
	Walk(win, "", 0)
end

-- ---- starting ----------------------------------------------------------------------------------

function Styles.Setup(opts)
	cfg = opts or {}
	if type(cfg.report) == "table" then
		for k, v in pairs(report) do cfg.report[k] = v end
		report = cfg.report
	end
	-- EllesmereUI calls back at login when its Blizzard Skins+ module is running and this addon
	-- is switched on in its list. Registering costs nothing when it never does.
	if EllesmereUI and EllesmereUI.RegisterSkin and cfg.addon then
		EllesmereUI.RegisterSkin(cfg.addon, function(skin)
			euiSkin = skin
			if not applied then Apply(Wanted()) end
			UpdateStatus()
		end)
	end
	-- Dark needs nothing from anyone, so it is drawn once the world is up, whether EllesmereUI
	-- called back or not.
	local starter = CreateFrame("Frame")
	starter:RegisterEvent("PLAYER_ENTERING_WORLD")
	starter:SetScript("OnEvent", function(self)
		self:UnregisterAllEvents()
		if not applied then Apply(Wanted()) end
		UpdateStatus()
	end)
	UpdateStatus()
end
