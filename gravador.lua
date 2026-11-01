--[[
	gravador.lua⚡ Vits hub — Gravador de Rota Universal (versão Delta)

	- Bolinha vermelha: 1 toque grava, outro toque para e salva.
	- Botão ⚡: abre / fecha o hub.
	- Hub: ● gravar | ▶ reproduzir | 📁 salvar | 🗑 apagar tudo (toque 2x)
	- As gravações ficam em "VitsHub_Rotas.json" (pasta workspace do Delta)
	  e carregam sozinhas quando você executar de novo.
]]

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

repeat
	task.wait()
until Players.LocalPlayer
local player = Players.LocalPlayer

------------------------------------------------------------------
-- CONFIGURAÇÕES
------------------------------------------------------------------
local SAMPLE_RATE = 0.05
local MAX_RECORD_TIME = 600
local LOOKAHEAD = 0.25
local LINE_SPACING = 2
local STUD_TO_METER = 0.28
local FILE_NAME = "VitsHub_Rotas.json"
local RS_NAME = "VitsHubReplay"

local C = {
	bg = Color3.fromRGB(12, 12, 16),
	panel = Color3.fromRGB(28, 28, 34),
	neon = Color3.fromRGB(0, 150, 255),
	sel = Color3.fromRGB(16, 70, 170),
	text = Color3.fromRGB(235, 235, 240),
	dim = Color3.fromRGB(150, 150, 160),
	red = Color3.fromRGB(235, 50, 50),
	yellow = Color3.fromRGB(250, 195, 30),
	line = Color3.fromRGB(0, 230, 255),
	white = Color3.new(1, 1, 1),
}

------------------------------------------------------------------
-- ESTADO
------------------------------------------------------------------
local recs = {}
local selected = nil
local nextId = 1
local showLines = true
local recording = false
local playing = false
local recConn, jumpConn, diedConn
local recFrames, recOff
local pulseTween
local confirmClear = false

------------------------------------------------------------------
-- UTILITÁRIOS
------------------------------------------------------------------
local function getChar()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return char, hum, root
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function round2(x)
	return math.floor(x * 100 + 0.5) / 100
end

local function fmtTime(s)
	s = math.floor(s + 0.5)
	if s < 60 then
		return s .. "s"
	end
	return math.floor(s / 60) .. "m" .. string.format("%02d", s % 60) .. "s"
end

local function toMeters(studs)
	return math.floor(studs * STUD_TO_METER + 0.5)
end

local function make(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do
		o[k] = v
	end
	if parent then
		o.Parent = parent
	end
	return o
end

local function corner(o, r)
	return make("UICorner", { CornerRadius = UDim.new(0, r) }, o)
end

local function stroke(o, color, thickness, transparency)
	return make("UIStroke", {
		Color = color,
		Thickness = thickness,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, o)
end

local function setControls(enabled)
	pcall(function()
		local scripts = player:FindFirstChild("PlayerScripts")
		local module = scripts and scripts:FindFirstChild("PlayerModule")
		if not module then
			return
		end
		local controls = require(module):GetControls()
		if enabled then
			controls:Enable()
		else
			controls:Disable()
		end
	end)
end

local function makeDraggable(handle, target, onTap)
	local dragging, moved = false, false
	local dragInput, dragStart, startPos
	local lastTap = 0

	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, moved = true, false
			dragInput = input
			dragStart = input.Position
			startPos = target.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)

	if onTap then
		handle.Activated:Connect(function()
			if moved then
				return
			end
			if os.clock() - lastTap < 0.4 then
				return
			end
			lastTap = os.clock()
			onTap()
		end)
	end

	UserInputService.InputChanged:Connect(function(input)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input == dragInput then
			local delta = input.Position - dragStart
			if delta.Magnitude > 6 then
				moved = true
			end
			if moved then
				target.Position = UDim2.new(
					startPos.X.Scale, startPos.X.Offset + delta.X,
					startPos.Y.Scale, startPos.Y.Offset + delta.Y
				)
			end
		end
	end)
end

------------------------------------------------------------------
-- LIMPEZA DE EXECUÇÕES ANTERIORES
------------------------------------------------------------------
local guiParent = player:WaitForChild("PlayerGui")
do
	local containers = { guiParent }
	pcall(function()
		table.insert(containers, game:GetService("CoreGui"))
	end)
	pcall(function()
		if typeof(gethui) == "function" then
			table.insert(containers, gethui())
		end
	end)
	for _, cont in ipairs(containers) do
		pcall(function()
			local old = cont:FindFirstChild("VitsHubGravador")
			if old then
				old:Destroy()
			end
		end)
	end

	local oldLines = Workspace:FindFirstChild("VitsRotas")
	if oldLines then
		oldLines:Destroy()
	end
	pcall(function()
		RunService:UnbindFromRenderStep(RS_NAME)
	end)
end

local lineRoot = Instance.new("Folder")
lineRoot.Name = "VitsRotas"
lineRoot.Parent = Workspace

------------------------------------------------------------------
-- INTERFACE
------------------------------------------------------------------
local gui = make("ScreenGui", {
	Name = "VitsHubGravador",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 999,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
gui.Parent = guiParent

-- Botão flutuante (bolinha vermelha + atalho do hub)
local float = make("Frame", {
	Name = "Flutuante",
	Size = UDim2.fromOffset(48, 88),
	Position = UDim2.new(1, -72, 0.3, 0),
	BackgroundTransparency = 1,
}, gui)

local ball = make("TextButton", {
	Name = "BolinhaGravar",
	Size = UDim2.fromOffset(48, 48),
	BackgroundColor3 = C.red,
	Text = "",
	TextColor3 = C.white,
	Font = Enum.Font.GothamBold,
	TextSize = 20,
	AutoButtonColor = false,
	BorderSizePixel = 0,
}, float)
corner(ball, 24)
local ballStroke = stroke(ball, C.white, 3)

local bolt = make("TextButton", {
	Name = "AbrirHub",
	Position = UDim2.fromOffset(9, 58),
	Size = UDim2.fromOffset(30, 30),
	BackgroundColor3 = C.bg,
	Text = "⚡",
	TextColor3 = C.yellow,
	Font = Enum.Font.GothamBold,
	TextSize = 16,
	AutoButtonColor = false,
	BorderSizePixel = 0,
}, float)
corner(bolt, 15)
stroke(bolt, C.neon, 1.5)

-- Hub
local hub = make("Frame", {
	Name = "Hub",
	Size = UDim2.fromOffset(280, 278),
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	BackgroundColor3 = C.bg,
	BorderSizePixel = 0,
	Active = true,
}, gui)
corner(hub, 12)
stroke(hub, C.neon, 1.5)

local titleBar = make("Frame", {
	Size = UDim2.new(1, 0, 0, 30),
	BackgroundTransparency = 1,
	Active = true,
}, hub)

make("TextLabel", {
	Size = UDim2.new(1, -44, 1, 0),
	Position = UDim2.fromOffset(10, 0),
	BackgroundTransparency = 1,
	Text = "⚡ Vits hub gravador de rota",
	TextColor3 = C.neon,
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Left,
}, titleBar)

local closeBtn = make("TextButton", {
	Size = UDim2.fromOffset(22, 22),
	Position = UDim2.new(1, -30, 0, 4),
	BackgroundColor3 = C.panel,
	Text = "✕",
	TextColor3 = C.dim,
	Font = Enum.Font.GothamBold,
	TextSize = 12,
	BorderSizePixel = 0,
}, titleBar)
corner(closeBtn, 6)

-- Linha de 4 botões
local function actionButton(index, text, color)
	local b = make("TextButton", {
		Position = UDim2.fromOffset(9 + (index - 1) * 67, 38),
		Size = UDim2.fromOffset(62, 40),
		BackgroundColor3 = C.panel,
		Text = text,
		TextColor3 = color or C.text,
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		BorderSizePixel = 0,
	}, hub)
	corner(b, 8)
	return b
end

local btnRec = actionButton(1, "●", C.red)
local btnPlay = actionButton(2, "▶", C.neon)
local btnSave = actionButton(3, "📁", C.white)
local btnClear = actionButton(4, "🗑", C.white)

-- Mostrar linhas
make("TextLabel", {
	Size = UDim2.fromOffset(170, 24),
	Position = UDim2.fromOffset(10, 86),
	BackgroundTransparency = 1,
	Text = "Mostrar Linhas de Rota",
	TextColor3 = C.text,
	Font = Enum.Font.GothamMedium,
	TextSize = 12,
	TextXAlignment = Enum.TextXAlignment.Left,
}, hub)

local toggleBtn = make("TextButton", {
	Size = UDim2.fromOffset(80, 22),
	Position = UDim2.fromOffset(190, 87),
	BackgroundColor3 = C.yellow,
	Text = "LIGADO",
	TextColor3 = Color3.fromRGB(20, 20, 20),
	Font = Enum.Font.GothamBold,
	TextSize = 11,
	BorderSizePixel = 0,
}, hub)
corner(toggleBtn, 6)

-- Lista de gravações
local listFrame = make("ScrollingFrame", {
	Position = UDim2.fromOffset(8, 116),
	Size = UDim2.fromOffset(264, 96),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	ScrollBarImageColor3 = C.neon,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollingDirection = Enum.ScrollingDirection.Y,
}, hub)
make("UIListLayout", {
	Padding = UDim.new(0, 4),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, listFrame)

-- Nome da gravação selecionada
local nameBox = make("TextBox", {
	Position = UDim2.fromOffset(8, 218),
	Size = UDim2.fromOffset(264, 26),
	BackgroundColor3 = C.panel,
	Text = "",
	PlaceholderText = "Selecione uma gravação",
	PlaceholderColor3 = C.dim,
	TextColor3 = C.text,
	Font = Enum.Font.Gotham,
	TextSize = 12,
	ClearTextOnFocus = false,
	BorderSizePixel = 0,
}, hub)
corner(nameBox, 6)

local statusLbl = make("TextLabel", {
	Position = UDim2.fromOffset(8, 250),
	Size = UDim2.fromOffset(264, 20),
	BackgroundTransparency = 1,
	Text = "Pronto. Toque na bolinha vermelha para gravar.",
	TextColor3 = C.neon,
	Font = Enum.Font.GothamBold,
	TextSize = 11,
	TextTruncate = Enum.TextTruncate.AtEnd,
}, hub)

local refreshList, updateUI

local function setStatus(text)
	statusLbl.Text = text
end

------------------------------------------------------------------
-- LINHAS DE ROTA NO MUNDO
------------------------------------------------------------------
local function labelText(rec)
	return rec.name .. "\n" .. toMeters(rec.dist) .. "m"
end

local function buildLine(rec)
	if rec.folder then
		rec.folder:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = rec.name
	rec.folder = folder

	local drop = Vector3.new(0, rec.off - 0.15, 0)
	local pts, last = {}, nil
	for i, f in ipairs(rec.frames) do
		if not last or (f.pos - last).Magnitude >= LINE_SPACING or i == #rec.frames then
			pts[#pts + 1] = f.pos - drop
			last = f.pos
		end
	end

	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local len = (b - a).Magnitude
		if len > 0.05 then
			make("Part", {
				Anchored = true,
				CanCollide = false,
				CanQuery = false,
				CanTouch = false,
				CastShadow = false,
				Material = Enum.Material.Neon,
				Color = C.line,
				Transparency = 0.2,
				Size = Vector3.new(0.3, 0.3, len),
				CFrame = CFrame.lookAt(a, b) * CFrame.new(0, 0, -len / 2),
			}, folder)
		end
	end

	local anchor = make("Part", {
		Name = "Rotulo",
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Transparency = 1,
		Size = Vector3.new(0.2, 0.2, 0.2),
		Position = pts[1] + Vector3.new(0, 3.2, 0),
	}, folder)

	local billboard = make("BillboardGui", {
		Size = UDim2.fromOffset(130, 34),
		AlwaysOnTop = true,
		LightInfluence = 0,
		MaxDistance = 300,
	}, anchor)

	rec.label = make("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = labelText(rec),
		TextColor3 = C.white,
		TextStrokeTransparency = 0.4,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextWrapped = true,
	}, billboard)

	folder.Parent = lineRoot
end

local function addRecord(name, frames, off)
	local dist = 0
	for i = 2, #frames do
		dist += (frames[i].pos - frames[i - 1].pos).Magnitude
	end
	local rec = {
		name = name,
		frames = frames,
		off = off or 3,
		dur = frames[#frames].t,
		dist = dist,
	}
	recs[#recs + 1] = rec
	buildLine(rec)
	return rec
end

------------------------------------------------------------------
-- SALVAR / CARREGAR (arquivo)
------------------------------------------------------------------
local function hasFS()
	return typeof(writefile) == "function" and typeof(readfile) == "function" and typeof(isfile) == "function"
end

local function saveAll()
	if not hasFS() then
		return false, "nofs"
	end
	local data = { nextId = nextId, recs = {} }
	for _, rec in ipairs(recs) do
		local fr = {}
		for i, f in ipairs(rec.frames) do
			fr[i] = { round2(f.t), round2(f.pos.X), round2(f.pos.Y), round2(f.pos.Z), f.j and 1 or 0 }
		end
		data.recs[#data.recs + 1] = { name = rec.name, off = rec.off, frames = fr }
	end
	local ok, err = pcall(function()
		writefile(FILE_NAME, HttpService:JSONEncode(data))
	end)
	return ok, err
end

local function persist(label)
	local ok, err = saveAll()
	if ok then
		setStatus("SALVO: " .. label)
	elseif err == "nofs" then
		setStatus("Salvo na memória (sem suporte a arquivos)")
	else
		setStatus("Erro ao salvar o arquivo")
	end
end

local function loadAll()
	if not hasFS() then
		return
	end
	local ok, data = pcall(function()
		if not isfile(FILE_NAME) then
			return nil
		end
		return HttpService:JSONDecode(readfile(FILE_NAME))
	end)
	if not ok or type(data) ~= "table" then
		return
	end
	nextId = data.nextId or 1
	for _, r in ipairs(data.recs or {}) do
		local frames = {}
		for i, a in ipairs(r.frames or {}) do
			frames[i] = { t = a[1], pos = Vector3.new(a[2], a[3], a[4]), j = a[5] == 1 }
		end
		if #frames >= 2 then
			addRecord(r.name or "Gravação", frames, r.off)
		end
	end
end

------------------------------------------------------------------
-- SELEÇÃO / EXCLUSÃO
------------------------------------------------------------------
local stopPlayback

local function selectRec(i)
	selected = i
	nameBox.Text = (i and recs[i]) and recs[i].name or ""
	refreshList()
end

local function deleteRec(i)
	local rec = recs[i]
	if not rec then
		return
	end
	if playing then
		stopPlayback()
	end
	if rec.folder then
		rec.folder:Destroy()
	end
	table.remove(recs, i)
	if selected == i then
		selected = (#recs > 0) and math.min(i, #recs) or nil
	elseif selected and selected > i then
		selected -= 1
	end
	nameBox.Text = (selected and recs[selected]) and recs[selected].name or ""
	refreshList()
	persist("removida " .. rec.name)
end

local function deleteAll()
	if playing then
		stopPlayback()
	end
	for _, rec in ipairs(recs) do
		if rec.folder then
			rec.folder:Destroy()
		end
	end
	recs = {}
	selected = nil
	nameBox.Text = ""
	refreshList()
	persist("todas apagadas")
end

------------------------------------------------------------------
-- GRAVAÇÃO
------------------------------------------------------------------
local function stopRecording(discard)
	if not recording then
		return
	end
	recording = false
	if recConn then recConn:Disconnect() recConn = nil end
	if jumpConn then jumpConn:Disconnect() jumpConn = nil end
	if diedConn then diedConn:Disconnect() diedConn = nil end

	local frames = recFrames
	recFrames = nil
	updateUI()

	if discard then
		return
	end
	if not frames or #frames < 2 then
		setStatus("Gravação muito curta, descartada")
		return
	end

	local rec = addRecord("Gravação " .. nextId, frames, recOff)
	nextId += 1
	selectRec(#recs)
	persist(rec.name)
end

local function startRecording()
	local _, hum, root = getChar()
	if not (hum and root) or hum.Health <= 0 then
		setStatus("Personagem não encontrado")
		return
	end

	recording = true
	recFrames = {}
	recOff = (hum.HipHeight > 0) and (hum.HipHeight + root.Size.Y / 2) or 3

	local t0 = os.clock()
	local acc = 0
	local lastSec = -1
	local jumpFlag = false

	recFrames[1] = { t = 0, pos = root.Position, j = false }

	jumpConn = hum.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Jumping then
			jumpFlag = true
		end
	end)
	diedConn = hum.Died:Connect(function()
		stopRecording()
	end)

	recConn = RunService.Heartbeat:Connect(function(dt)
		local _, h, r = getChar()
		if not (h and r) then
			stopRecording()
			return
		end
		acc += dt
		if acc >= SAMPLE_RATE then
			acc = acc % SAMPLE_RATE
			local t = os.clock() - t0
			recFrames[#recFrames + 1] = { t = t, pos = r.Position, j = jumpFlag }
			jumpFlag = false

			local sec = math.floor(t)
			if sec ~= lastSec then
				lastSec = sec
				setStatus("Gravando... " .. fmtTime(t))
			end
			if t >= MAX_RECORD_TIME then
				stopRecording()
			end
		end
	end)

	updateUI()
	setStatus("Gravando...")
end

------------------------------------------------------------------
-- REPRODUÇÃO
------------------------------------------------------------------
function stopPlayback(msg)
	if not playing then
		return
	end
	playing = false
	pcall(function()
		RunService:UnbindFromRenderStep(RS_NAME)
	end)
	local _, h = getChar()
	if h then
		h:Move(Vector3.zero, false)
	end
	setControls(true)
	updateUI()
	if msg then
		setStatus(msg)
	end
end

local function startPlayback()
	local rec = selected and recs[selected]
	if not rec then
		setStatus("Selecione uma gravação na lista")
		return
	end
	if recording then
		stopRecording()
		rec = selected and recs[selected]
		if not rec then
			return
		end
	end

	local _, hum, root = getChar()
	if not (hum and root) or hum.Health <= 0 then
		setStatus("Personagem não encontrado")
		return
	end

	local frames = rec.frames
	local n = #frames
	local dur = frames[n].t
	local phase, startClock, approachT = "approach", 0, os.clock()
	local jumpIdx, aheadIdx = 1, 1

	playing = true
	setControls(false)
	updateUI()
	setStatus("Indo até o início de " .. rec.name .. "...")

	RunService:BindToRenderStep(RS_NAME, Enum.RenderPriority.Input.Value + 1, function()
		local _, h, r = getChar()
		if not (h and r) or h.Health <= 0 then
			stopPlayback("Reprodução interrompida")
			return
		end
		local pos = r.Position

		if phase == "approach" then
			local d = flat(frames[1].pos - pos)
			if d.Magnitude < 2.5 or os.clock() - approachT > 12 then
				phase = "run"
				startClock = os.clock()
				setStatus("Reproduzindo: " .. rec.name)
			else
				h:Move(d.Unit, false)
				return
			end
		end

		local el = os.clock() - startClock

		while jumpIdx <= n and frames[jumpIdx].t <= el do
			if frames[jumpIdx].j then
				h.Jump = true
			end
			jumpIdx += 1
		end

		local look = el + LOOKAHEAD
		while aheadIdx < n and frames[aheadIdx].t < look do
			aheadIdx += 1
		end

		local d = flat(frames[aheadIdx].pos - pos)
		if d.Magnitude > 0.6 then
			h:Move(d.Unit, false)
		else
			h:Move(Vector3.zero, false)
		end

		if el > dur + 4 or (el >= dur and flat(frames[n].pos - pos).Magnitude < 3) then
			stopPlayback("Reprodução concluída")
		end
	end)
end

------------------------------------------------------------------
-- LISTA E ESTADO VISUAL
------------------------------------------------------------------
function refreshList()
	for _, c in ipairs(listFrame:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end

	if #recs == 0 then
		make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 28),
			BackgroundTransparency = 1,
			Text = "Nenhuma gravação ainda",
			TextColor3 = C.dim,
			Font = Enum.Font.Gotham,
			TextSize = 12,
		}, listFrame)
		return
	end

	for i, rec in ipairs(recs) do
		local isSel = (i == selected)
		local row = make("TextButton", {
			LayoutOrder = i,
			Size = UDim2.new(1, -6, 0, 28),
			BackgroundColor3 = isSel and C.sel or C.panel,
			Text = "",
			AutoButtonColor = false,
			BorderSizePixel = 0,
		}, listFrame)
		corner(row, 6)
		if isSel then
			stroke(row, C.neon, 1)
		end

		make("TextLabel", {
			Size = UDim2.new(1, -96, 1, 0),
			Position = UDim2.fromOffset(8, 0),
			BackgroundTransparency = 0
	end
end

------------------------------------------------------------------
-- EVENTOS
------------------------------------------------------------------
local function toggleRecording()
	if recording then
		stopRecording()
	else
		if playing then
			stopPlayback()
		end
		startRecording()
	end
end

makeDraggable(ball, float, toggleRecording)
makeDraggable(bolt, float, function()
	hub.Visible = not hub.Visible
end)
makeDraggable(titleBar, hub, nil)

closeBtn.Activated:Connect(function()
	hub.Visible = false
end)

btnRec.Activated:Connect(toggleRecording)

btnPlay.Activated:Connect(function()
	if playing then
		stopPlayback("Reprodução parada")
	else
		startPlayback()
	end
end)

btnSave.Activated:Connect(function()
	if #recs == 0 then
		setStatus("Nada para salvar")
		return
	end
	persist((selected and recs[selected]) and recs[selected].name or "todas as gravações")
end)

btnClear.Activated:Connect(function()
	if #recs == 0 then
		setStatus("Nada para apagar")
		return
	end
	if not confirmClear then
		confirmClear = true
		btnClear.Text = "?"
		btnClear.BackgroundColor3 = Color3.fromRGB(150, 40, 40)
		setStatus("Toque de novo para apagar TODAS")
		task.delay(2.5, function()
			confirmClear = false
			btnClear.Text = "🗑"
			btnClear.BackgroundColor3 = C.panel
		end)
		return
	end
	confirmClear = false
	btnClear.Text = "🗑"
	btnClear.BackgroundColor3 = C.panel
	deleteAll()
end)

toggleBtn.Activated:Connect(function()
	showLines = not showLines
	lineRoot.Parent = showLines and Workspace or nil
	toggleBtn.Text = showLines and "LIGADO" or "DESLIGADO"
	toggleBtn.BackgroundColor3 = showLines and C.yellow or C.panel
	toggleBtn.TextColor3 = showLines and Color3.fromRGB(20, 20, 20) or C.dim
end)

nameBox.FocusLost:Connect(function()
	local rec = selected and recs[selected]
	if not rec then
		nameBox.Text = ""
		return
	end
	local txt = string.match(nameBox.Text, "^%s*(.-)%s*$") or ""
	if txt == "" then
		nameBox.Text = rec.name
		return
	end
	txt = string.sub(txt, 1, 24)
	if txt ~= rec.name then
		rec.name = txt
		if rec.folder then
			rec.folder.Name = txt
		end
		if rec.label then
			rec.label.Text = labelText(rec)
		end
		refreshList()
		persist(txt)
	end
	nameBox.Text = rec.name
end)

player.CharacterAdded:Connect(function()
	stopPlayback()
end)

------------------------------------------------------------------
-- INÍCIO
------------------------------------------------------------------
loadAll()
if #recs > 0 then
	selectRec(#recs)
	setStatus("Carregadas " .. #recs .. " gravação(ões)")
else
	refreshList()
end
updateUI()

print("[Vits hub] Gravador de rota carregado.")
