--[=[

	VPF Replay Module
	© Zack Ovits | boatbomber
	2020
	Version 1.1

	Write up:
	https://devforum.roblox.com/t/open-source-vpf-replay-module/523112/1

	Update Log:
		Version 1.1
			Humanoid and character handling
			Async registering

		Version 1.0
			Initial creation

--------------------------------------------------------------------
API Documentation:
--------------------------------------------------------------------

[function] Replay.new(Settings)
	Returns a new ReplayObject
    @param [table] Settings
		[number] Settings.FPS
			The FPS to record at
			defaults to 20
		[string] Settings.CameraType
			The type of camera for the Replay object playback
			("Recorded", "Track", "Follow", or "Custom")
			defaults to "Recorded"
		[Vector3] Settings.CameraPosition
			Where the camera should sit during playback
			Only relevant when set to "Track"
		[Instance] Settings.CameraSubject
			Not relevant to "Recorded"

[Instance] ReplayObject.VPF
	The ViewportFrame for you to parent to your desired GUI

[Instance] ReplayObject.Camera
	The Camera (use only if CameraType is set to "Custom")

[function] ReplayObject:Register(Object, IgnoreDescendants)
	Adds Object	to be recorded for playback
    @param [Instance] Object
		The object to register for recording
	@param [Boolean] IgnoreDescendants
		Whether or not it should recursively register the entire object (useful for models and folders)
		defaults to false

[function] ReplayObject:RegisterStatic(Object, IgnoreDescendants)
	Adds Object	to be displayed during playback without moving or recording (Useful for map and props)
	@param [Instance] Object
		The object to register for static display
	@param [Boolean] IgnoreDescendants
		Whether or not it should recursively register the entire object (useful for models and folders)
		defaults to false

[function] ReplayObject:StartRecording(MaxRecordingTime)
	Begins recording all registered objects
	@param [number] MaxRecordingTime
		How long the recording can be before automatically stopping
		defaults to 30

[function] ReplayObject:StopRecording()
	Stops the in-progress recording	, and prepares the playback functions

[function] ReplayObject:ClearRecording()
	Clears the stored recording to allow another to be recorded without needing a new ReplayObject and registering everything again

[function] ReplayObject:Destroy()
	Empties the ReplayObject and associated objects for GC

[function] ReplayObject:Play(PlaySpeed,StartTime,Override)
	Plays the stored recording in the ViewportFrame
	@param [number] PlaySpeed
		The time multiplier (useful for slow motion replays or sped up recaps)
		defaults to 1
	@param [number] StartTime
		The time at which playback should begin
		defaults to 0
	@param [Boolean] Override
		Wether or not this playback should override any in-progress playback
		defaults to false

[function] ReplayObject:Stop()
	Halts any in-progress playback

[function] ReplayObject:GoToTime(Time)
	Displays the state in the stored recording in the ViewportFrame at the given Time
	@param [number] Time
		What time in the recording to render

[function] ReplayObject:GoToPercent(Percent)
	Displays the state in the stored recording in the ViewportFrame at the given Percent
	@param [number] Percent
		What percent of the way through the recording to render

[function] ReplayObject:GoToFrame(Frame)
	Displays the state in the stored recording in the ViewportFrame at the given Frame
	@param [number] Percent
		What frame of the recording to render

[event] ReplayObject.RecordingStarted
	Fires when a recording starts

[event] ReplayObject.RecordingStopped
	Fires when a recording stops

[event] ReplayObject.FrameChanged
	Fires when the rendered frame of the recording changes
	@arg [number] Frame
		What frame is now being rendered
	@arg [number] Time
		What time is now being rendered
	@arg [number] Percent
		What percent is now being rendered

[property] ReplayObject.Playing
	Read only boolean of the playing state

[property] ReplayObject.Recording
	Read only boolean of the recording state

[property] ReplayObject.Recorded
	Read only boolean whether there is a stored recording

[property] ReplayObject.FrameCount
	Read only number of how many frames are in the stored recording

[property] ReplayObject.RecordingTime
	Read only number of how long the stored recording is (in seconds)


--]=]

local UIS = game:GetService("UserInputService")
local RS = game:GetService("RunService")
local Mouse = game:GetService("Players").LocalPlayer:GetMouse()

local DEBUG = false --RS:IsStudio()

local Module = {}

local RenderStepped = RS.RenderStepped

local CleanChildren = { ["Decal"] = true, ["Texture"] = true, ["SpecialMesh"] = true, ["BlockMesh"] = true }
local function CleanClone(Object) -- BasePart
	local CleanObject = Object:Clone()

	for _, c in ipairs(CleanObject:GetChildren()) do
		if not CleanChildren[c.ClassName] then
			c:Destroy()
		end
	end

	CleanObject.Anchored = true
	CleanObject.CanCollide = false
	CleanObject.CanTouch = false
	CleanObject.CanQuery = false

	return CleanObject
end

function Module.new(Settings)
	Settings = Settings or {}

	local RecordingStopped = Instance.new("BindableEvent")
	local RecordingStarted = Instance.new("BindableEvent")
	local FrameChanged = Instance.new("BindableEvent")

	local Replay = {
		-- States
		Playing = false,
		Recording = false,
		Recorded = false,

		-- Main
		Registers = {},
		StaticRegisters = {},
		CloneIndex = {},
		RegisteredObjects = {},

		Frames = {},
		FrameTimes = {},
		FrameCount = 0,
		RecordingTime = 0,

		LastSnapshotTick = 0,
		FPSDelay = 1 / (Settings.FPS or 20),

		-- Objects
		VPF = Instance.new("ViewportFrame"),
		MouseDetector = Instance.new("TextButton"),
		WheelSinker = Instance.new("ScrollingFrame"),
		Camera = Instance.new("Camera"),
		Skybox = script.Skybox:Clone(),

		-- Connections (written for reference and autofill)
		RecordConnection = nil,
		PlayConnection = nil,

		-- Events
		RecordingStarted = RecordingStarted.Event,
		RecordingStopped = RecordingStopped.Event,
		FrameChanged = FrameChanged.Event,

		-- Settings
		CameraType = Settings.CameraType or "Recorded",
		CameraPosition = Settings.CameraPosition or Vector3.new(0, 10, 0),
		CameraSubject = Settings.CameraSubject,

		-- Camera
		CameraAngle = { X = 0, Y = 0 },
		CameraOffset = 20,
	}

	-- Setup
	Replay.VPF.CurrentCamera = Replay.Camera
	Replay.VPF.Size = UDim2.new(1, 0, 1, 0)
	Replay.VPF.BorderSizePixel = 0
	Replay.Skybox.Parent = Replay.VPF
	Replay.MouseDetector.Text = ""
	Replay.MouseDetector.Size = UDim2.new(1, 0, 1, 0)
	Replay.MouseDetector.BackgroundTransparency = 1
	Replay.MouseDetector.Parent = Replay.VPF
	Replay.WheelSinker.Size = UDim2.new(1, 0, 1, 0)
	Replay.WheelSinker.BackgroundTransparency = 1
	Replay.WheelSinker.ScrollBarImageTransparency = 1
	Replay.WheelSinker.BorderSizePixel = 0
	Replay.WheelSinker.Parent = Replay.VPF

	local MouseHovering = false
	Replay.VPF.MouseEnter:Connect(function()
		MouseHovering = true
	end)
	Replay.VPF.MouseLeave:Connect(function()
		MouseHovering = false
	end)

	local CameraDrag
	Replay.MouseDetector.MouseButton2Down:Connect(function()
		local LastX, LastY = Mouse.X, Mouse.Y
		CameraDrag = RS.Heartbeat:Connect(function()
			if Replay.CameraType == "Follow" then
				Replay.CameraAngle = {
					X = Replay.CameraAngle.X - math.rad(((Mouse.X - LastX) / Replay.VPF.AbsoluteSize.X) * 100),
					Y = Replay.CameraAngle.Y - math.rad(((Mouse.Y - LastY) / Replay.VPF.AbsoluteSize.Y) * 100),
				}

				Replay.Camera.CFrame = (
						CFrame.new(Replay.CamSubClone.Position)
						* (CFrame.Angles(0, Replay.CameraAngle.X or 0, 0))
						* CFrame.Angles(Replay.CameraAngle.Y or 0, 0, 0)
					) * CFrame.new(0, 0, Replay.CameraOffset or 20)
			elseif Replay.CameraType == "Free" then
				Replay.Camera.CFrame = (
						Replay.Camera.CFrame:ToWorldSpace(
							CFrame.Angles(math.rad(((Mouse.Y - LastY) / Replay.VPF.AbsoluteSize.Y) * 100), 0, 0)
						)
					) * (CFrame.Angles(0, math.rad(((Mouse.X - LastX) / Replay.VPF.AbsoluteSize.X) * 100), 0))
			end
			LastX, LastY = Mouse.X, Mouse.Y
		end)
	end)
	UIS.InputEnded:Connect(function(Input)
		if Input.UserInputType == Enum.UserInputType.MouseButton2 then
			if CameraDrag then
				CameraDrag:Disconnect()
				CameraDrag = nil
			end
		end
	end)
	UIS.InputChanged:Connect(function(Input, GP)
		if MouseHovering and GP and Input.UserInputType == Enum.UserInputType.MouseWheel then
			if Replay.CameraType == "Free" then
				Replay.Camera.CFrame = Replay.Camera.CFrame * CFrame.new(0, 0, Input.Position.Z * -4)
			elseif Replay.CameraType == "Follow" then
				Replay.CameraOffset = math.clamp(Replay.CameraOffset - (Input.Position.Z * 4), 0.5, 100)
				Replay.Camera.CFrame = (
						CFrame.new(Replay.CamSubClone.Position)
						* (CFrame.Angles(0, Replay.CameraAngle.X or 0, 0))
						* CFrame.Angles(Replay.CameraAngle.Y or 0, 0, 0)
					) * CFrame.new(0, 0, Replay.CameraOffset or 20)
			end
		end
	end)

	-- Primary functions

	function Replay:Register(Object: Instance, IgnoreDescendants: boolean)
		task.spawn(function() -- Run async due to possible yielding
			if Replay.Recording then
				warn("Cannot register new objects while recording is in progress")
				return
			end

			if typeof(Object) ~= "Instance" then
				return
			end

			if DEBUG then
				print("Register:", Object)
			end

			local IsHumanoid = false

			if Object:IsA("Model") and Object:FindFirstChildWhichIsA("Humanoid") then
				IsHumanoid = true

				if DEBUG then
					print("Character detected:", Object)
				end

				while Object:FindFirstChildWhichIsA("BasePart") == nil do
					task.wait(0.05) -- .CharacterAdded is fired before the character loads, so this wait is needed or the model has no basepart children yet
				end

				local CharClone = Instance.new("Model")
				CharClone.Name = Object.Name

				for _, Child in ipairs(Object:GetDescendants()) do
					if Child:IsA("BasePart") then
						if not Replay.RegisteredObjects[Child] then -- Avoid duplication
							if DEBUG then
								print("   Valid character part:", Child)
							end

							Replay.RegisteredObjects[Child] = true

							local Clone = CleanClone(Child)
							Replay.CloneIndex[Child] = Clone

							Replay.Registers[#Replay.Registers + 1] = { Mirror = Clone, Original = Child }
							Clone.Parent = CharClone
						end
					elseif Child:IsA("CharacterMesh") then
						Child:Clone().Parent = CharClone
					end
				end

				local Shirt, Pants, Tee =
					Object:FindFirstChildWhichIsA("Shirt"),
					Object:FindFirstChildWhichIsA("Pants"),
					Object:FindFirstChildWhichIsA("ShirtGraphic")
				do -- Handles clothing in a `do end` just for easy code folding, not really about scope or anything
					if Shirt then
						if DEBUG then
							print("   Shirt registered:")
						end

						local ShirtClone = Shirt:Clone()
						ShirtClone.Parent = CharClone

						Shirt.Changed:Connect(function(Prop)
							ShirtClone[Prop] = Shirt[Prop]
						end)
					end

					if Pants then
						if DEBUG then
							print("   Pants registered:")
						end

						local PantsClone = Pants:Clone()
						PantsClone.Parent = CharClone

						Pants.Changed:Connect(function(Prop)
							PantsClone[Prop] = Pants[Prop]
						end)
					end

					if Tee then
						if DEBUG then
							print("   Tee registered:")
						end

						local TeeClone = Tee:Clone()
						TeeClone.Parent = CharClone

						Tee.Changed:Connect(function(Prop)
							TeeClone[Prop] = Tee[Prop]
						end)
					end
				end

				local StatelessHumanoid = Instance.new("Humanoid")
				do -- Again, the `do end` block is just so I can fold the code
					StatelessHumanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
					for _, enum in next, Enum.HumanoidStateType:GetEnumItems() do
						if enum ~= Enum.HumanoidStateType.None then
							StatelessHumanoid:SetStateEnabled(enum, false)
						end
					end
					StatelessHumanoid:SetStateEnabled(Enum.HumanoidStateType.RunningNoPhysics, true)

					StatelessHumanoid.RigType = Object:FindFirstChildWhichIsA("Humanoid").RigType
				end
				StatelessHumanoid.Parent = CharClone

				CharClone.Parent = Replay.VPF
			end

			if Object:IsA("BasePart") and Object.ClassName ~= "Terrain" and Object.Archivable then
				if not Replay.RegisteredObjects[Object] then -- Avoid duplication
					if DEBUG then
						print("   Valid register")
					end

					Replay.RegisteredObjects[Object] = true

					local Clone = CleanClone(Object)
					Replay.CloneIndex[Object] = Clone

					Replay.Registers[#Replay.Registers + 1] = { Mirror = Clone, Original = Object }
					Clone.Parent = Replay.VPF
				end
			end

			if not IsHumanoid then
				if not IgnoreDescendants then
					for _, Child in ipairs(Object:GetChildren()) do
						Replay:Register(Child)
					end
				end
			end
		end)
	end

	function Replay:RegisterStatic(Object: Instance, IgnoreDescendants: boolean)
		task.spawn(function() -- Run async due to possible yielding
			if Replay.Recording then
				warn("Cannot register new objects while recording is in progress")
				return
			end

			if typeof(Object) ~= "Instance" then
				return
			end

			if DEBUG then
				print("Register Static:", Object)
			end

			local IsHumanoid = false

			if Object:IsA("Model") and Object:FindFirstChildWhichIsA("Humanoid") then
				IsHumanoid = true

				if DEBUG then
					print("Character detected:", Object)
				end

				while Object:FindFirstChildWhichIsA("BasePart") == nil do
					task.wait(0.05) -- .CharacterAdded is fired before the character loads, so this wait is needed or the model has no basepart children yet
				end

				local CharClone = Instance.new("Model")
				CharClone.Name = Object.Name

				for _, Child in ipairs(Object:GetDescendants()) do
					if Child:IsA("BasePart") then
						if not Replay.StaticRegisters[Child] then -- Avoid duplication
							if DEBUG then
								print("   Valid character part:", Child)
							end

							Replay.StaticRegisters[Child] = true

							local Clone = CleanClone(Child)
							Replay.CloneIndex[Child] = Clone

							Clone.Parent = CharClone
						elseif Child:IsA("CharacterMesh") then
							Child:Clone().Parent = CharClone
						end
					end
				end

				local Shirt, Pants, Tee =
					Object:FindFirstChildWhichIsA("Shirt"),
					Object:FindFirstChildWhichIsA("Pants"),
					Object:FindFirstChildWhichIsA("ShirtGraphic")
				do -- Handles clothing in a `do end` just for easy code folding, not really about scope or anything
					if Shirt then
						if DEBUG then
							print("   Shirt registered:")
						end

						local ShirtClone = Shirt:Clone()
						ShirtClone.Parent = CharClone

						Shirt.Changed:Connect(function(Prop)
							ShirtClone[Prop] = Shirt[Prop]
						end)
					end

					if Pants then
						if DEBUG then
							print("   Pants registered:")
						end

						local PantsClone = Pants:Clone()
						PantsClone.Parent = CharClone

						Pants.Changed:Connect(function(Prop)
							PantsClone[Prop] = Pants[Prop]
						end)
					end

					if Tee then
						if DEBUG then
							print("   Tee registered:")
						end

						local TeeClone = Tee:Clone()
						TeeClone.Parent = CharClone

						Tee.Changed:Connect(function(Prop)
							TeeClone[Prop] = Tee[Prop]
						end)
					end
				end

				local StatelessHumanoid = Instance.new("Humanoid")
				do -- Again, the `do end` block is just so I can fold the code
					StatelessHumanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
					for _, enum in next, Enum.HumanoidStateType:GetEnumItems() do
						if enum ~= Enum.HumanoidStateType.None then
							StatelessHumanoid:SetStateEnabled(enum, false)
						end
					end
					StatelessHumanoid:SetStateEnabled(Enum.HumanoidStateType.RunningNoPhysics, true)

					StatelessHumanoid.RigType = Object:FindFirstChildWhichIsA("Humanoid").RigType
				end
				StatelessHumanoid.Parent = CharClone

				CharClone.Parent = Replay.VPF
			end

			if Object:IsA("BasePart") and Object.ClassName ~= "Terrain" and Object.Archivable then
				if not Replay.StaticRegisters[Object] then -- Avoid duplication
					Replay.StaticRegisters[Object] = true

					if DEBUG then
						print("   Valid static register")
					end

					local Clone = CleanClone(Object)
					Replay.CloneIndex[Object] = Clone

					Clone.Parent = Replay.VPF
				end
			end

			if not IsHumanoid then
				if not IgnoreDescendants then
					for _, Child in ipairs(Object:GetChildren()) do
						Replay:RegisterStatic(Child, IgnoreDescendants)
					end
				end
			end
		end)
	end

	function Replay:StartRecording(MaxRecordingTime: number?)
		if Replay.Recorded then
			warn("Cannot start recording until previous recording is cleared")
			return
		end

		if Replay.Recording then
			warn("Cannot start recording since recording is already in progress")
			return
		end

		MaxRecordingTime = MaxRecordingTime or 30

		if DEBUG then
			print("Start Recording")
		end

		RecordingStarted:Fire()

		Replay.Recording = true

		Replay.RecordConnection = RenderStepped:Connect(function(DeltaTime)
			if Replay.RecordingTime + DeltaTime > MaxRecordingTime then
				Replay:StopRecording()
				return
			end

			Replay.RecordingTime = Replay.RecordingTime + DeltaTime
			local FrameDelta = os.clock() - Replay.LastSnapshotTick
			if FrameDelta >= Replay.FPSDelay then
				if DEBUG then
					print("Snapshotting")
				end

				Replay.FrameCount = Replay.FrameCount + 1
				Replay.LastSnapshotTick = os.clock()

				Replay.FrameTimes[Replay.FrameCount] = Replay.RecordingTime

				local ObjectData = {}

				for _, Object in ipairs(Replay.Registers) do
					local mir, og = Object.Mirror, Object.Original

					if og and og:IsDescendantOf(game) then
						ObjectData[Object.Mirror] = {
							["CFrame"] = og.CFrame,
							["Color"] = og.Color,
							["Transparency"] = og.Transparency,
						}
					else
						ObjectData[Object.Mirror] = {
							["Destroyed"] = true,
						}
					end
				end

				if Replay.Frames[Replay.FrameCount - 1] then
					Replay.Frames[Replay.FrameCount - 1].FrameLength = FrameDelta
				end

				Replay.Frames[Replay.FrameCount] = {
					ID = Replay.FrameCount,
					Time = Replay.RecordingTime,
					CameraCF = workspace.CurrentCamera.CFrame,
					ObjectData = ObjectData,
				}
			end
		end)

		local Sky = game.Lighting:FindFirstChildWhichIsA("Sky")
		if Sky then
			Replay.Skybox.Bk.Decal.Texture = Sky.SkyboxBk
			Replay.Skybox.Dn.Decal.Texture = Sky.SkyboxDn
			Replay.Skybox.Ft.Decal.Texture = Sky.SkyboxFt
			Replay.Skybox.Lf.Decal.Texture = Sky.SkyboxLf
			Replay.Skybox.Rt.Decal.Texture = Sky.SkyboxRt
			Replay.Skybox.Up.Decal.Texture = Sky.SkyboxUp
		end
	end

	function Replay:StopRecording()
		if Replay.Recorded then
			warn("Cannot stop recording since it has already stopped")
			return
		end

		if not Replay.Recording then
			warn("Cannot stop recording since no recording is in progress")
			return
		end

		if DEBUG then
			print("Stop Recording")
		end

		RecordingStopped:Fire()

		Replay.RecordConnection:Disconnect()

		Replay.Recording = false
		Replay.Recorded = true

		if Replay.CameraSubject and Replay.CloneIndex[Replay.CameraSubject] then
			Replay.CamSubClone = Replay.CloneIndex[Replay.CameraSubject]
		end

		Replay:GoToFrame(1)
	end

	function Replay:ClearRecording()
		if not Replay.Recorded then
			warn("Cannot clear nonexistent recording")
			return
		end

		if Replay.RecordConnection then
			Replay.RecordConnection:Disconnect()
		end
		if Replay.PlayConnection then
			Replay.PlayConnection:Disconnect()
		end

		Replay.FrameCount = 0
		Replay.Frames = {}
		Replay.FrameTimes = {}
		Replay.RecordingTime = 0

		Replay.Recorded = false
		Replay.Recording = false
		Replay.Playing = false
	end

	function Replay:Destroy()
		RecordingStopped:Destroy()
		RecordingStarted:Destroy()
		FrameChanged:Destroy()

		Replay.VPF:Destroy()
		Replay.MouseDetector:Destroy()
		Replay.WheelSinker:Destroy()
		Replay.Camera:Destroy()
		Replay.Skybox:Destroy()

		if Replay.RecordConnection then
			Replay.RecordConnection:Disconnect()
		end
		if Replay.PlayConnection then
			Replay.PlayConnection:Disconnect()
		end

		for _, Object in pairs(Replay.CloneIndex) do
			Object:Destroy()
		end

		Replay = nil
	end

	local function FindFrame(f, t)
		if not f then
			return
		end

		t = t or 0

		local FrameDepth = t - (f.Time or 0)

		if (FrameDepth or 0) <= (f.FrameLength or 0) then
			return Replay:GoToFrame(f.ID + (FrameDepth / (f.FrameLength or 0)))
		else
			return FindFrame(Replay.Frames[f.ID + 1], t)
		end
	end

	function Replay:Play(PlaySpeed: number?, StartTime: number?, Override: boolean?)
		if not Replay.Recorded then
			warn("Cannot play nonexistent recording")
			return
		end
		if Replay.Playing and not Override then
			warn("Cannot play recording since playback is already in progress")
			return
		end

		if Replay.PlayConnection then
			Replay.PlayConnection:Disconnect()
		end

		PlaySpeed = math.clamp(PlaySpeed or 1, 0.02, 999)

		Replay.Playing = true

		local Timer = math.clamp(StartTime or 0, 0, Replay.RecordingTime)
		local Frame = Replay:GoToTime(Timer)

		Replay.PlayConnection = RenderStepped:Connect(function(DeltaTime)
			Timer = Timer + (DeltaTime * PlaySpeed)

			Frame = FindFrame(Frame, Timer)

			if Timer > Replay.RecordingTime or not Frame then
				Replay:Stop()
				return
			end
		end)
	end

	function Replay:Stop()
		if not Replay.Playing then
			warn("Cannot stop playback since playback isn't in progress")
			return
		end

		Replay.Playing = false
		Replay.PlayConnection:Disconnect()
	end

	function Replay:GoToPercent(Percent: number)
		if not Replay.Recorded then
			warn("Cannot go to percent since there is no recording")
			return
		end

		if DEBUG then
			print("GoToPercent:", Percent)
		end

		return Replay:GoToTime(Replay.RecordingTime * math.clamp(Percent, 0, 1))
	end

	function Replay:GoToTime(Time: number)
		if not Replay.Recorded then
			warn("Cannot go to time since there is no recording")
			return
		end

		if DEBUG then
			print("GoToTime:", Time)
		end

		-- Find frame
		for f, t in ipairs(Replay.FrameTimes) do
			if t == Time then
				return Replay:GoToFrame(f)
			else
				local FrameLength = Replay.Frames[f].FrameLength or 0
				if t + FrameLength >= Time then
					return Replay:GoToFrame(f + ((Time - t) / FrameLength))
				end
			end
		end
	end

	function Replay:GoToFrame(Frame: number)
		if not Replay.Recorded then
			warn("Cannot go to frame since there is no recording")
			return
		end

		if DEBUG then
			print("GoToFrame:", Frame)
		end

		Frame = math.clamp(Frame, 1, Replay.FrameCount)

		local StartFrameData = Replay.Frames[math.floor(Frame)]
		local EndFrameData = Replay.Frames[math.ceil(Frame)]
		local FrameDelta = Frame - math.floor(Frame)
		local Time = StartFrameData.Time + (FrameDelta * (StartFrameData.FrameLength or 0))

		FrameChanged:Fire(Frame, Time, Time / Replay.RecordingTime)

		for Object, Data in pairs(StartFrameData.ObjectData) do
			local NextData = EndFrameData.ObjectData[Object]

			if Data.Destroyed then
				Object.Transparency = 1
			else
				if NextData.Destroyed then
					Object.CFrame = Data.CFrame
					Object.Color = Data.Color
					Object.Transparency = Data.Transparency
				else
					Object.CFrame = Data.CFrame:lerp(NextData.CFrame, FrameDelta)
					Object.Color = Data.Color:lerp(NextData.Color, FrameDelta)
					Object.Transparency = Data.Transparency + ((NextData.Transparency - Data.Transparency) * FrameDelta)
				end
			end
		end

		if Replay.CameraType == "Recorded" then
			Replay.Camera.CFrame = StartFrameData.CameraCF:lerp(EndFrameData.CameraCF, FrameDelta)
		elseif Replay.CameraType == "Track" then
			Replay.Camera.CFrame = CFrame.new(
				Replay.CameraPosition or Vector3.new(0, 10, 0),
				Replay.CamSubClone.Position or Vector3.new()
			)
		elseif Replay.CameraType == "Follow" then
			Replay.Camera.CFrame = (
					CFrame.new(Replay.CamSubClone.Position)
					* (CFrame.Angles(0, Replay.CameraAngle.X or 0, 0))
					* CFrame.Angles(Replay.CameraAngle.Y or 0, 0, 0)
				) * CFrame.new(0, 0, Replay.CameraOffset or 20)
		end

		return StartFrameData
	end

	return Replay
end

return Module

