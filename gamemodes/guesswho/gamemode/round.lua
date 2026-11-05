local GWRound = {}

GM.GWRound = GWRound

-- A round needs at least one seeker and one hider
GW_MIN_PLAYERS = 2
-- Upper bound for one rotation pass: with a big roster C(n, k) explodes, so we cap the
-- number of seeker groups we deal out per pass instead of enumerating all of them
GW_MAX_COMBINATIONS = 512

-- Binomial coefficient C(n, k), cut off as soon as it passes cap so we never build
-- absurdly large numbers
local function Binomial(n, k, cap)
    if n < 1 or k < 1 or k > n then return 0 end

    k = math.min(k, n - k)
    local value = 1

    for i = 1, k do
        value = value * (n - k + i) / i
        if value > cap then return cap + 1 end
    end

    return math.floor(value + 0.5)
end

local function ShuffleList(list)
    for i = #list, 2, -1 do
        local j = math.random(i)
        list[i], list[j] = list[j], list[i]
    end

    return list
end

-- Every k element subset of {1..n}, as sorted lists of 1 based indices, in
-- lexicographic order, never returning more than GW_MAX_COMBINATIONS entries
local function BuildCombinations(n, k)
    local combinations = {}

    if k < 1 or k > n then return combinations end

    local index = {}
    for i = 1, k do index[i] = i end

    while true do
        local combination = {}
        for i = 1, k do combination[i] = index[i] end
        table.insert(combinations, combination)

        if #combinations >= GW_MAX_COMBINATIONS then return combinations end

        -- step to the next combination
        local i = k
        while i > 0 and index[i] == n - k + i do i = i - 1 end
        if i == 0 then return combinations end

        index[i] = index[i] + 1
        for j = i + 1, k do index[j] = index[j - 1] + 1 end
    end
end

-- Fallback for rosters with more possible seeker groups than a pass is worth:
-- GW_MAX_COMBINATIONS unique groups picked at random
local function BuildRandomCombinations(n, k)
    local combinations, seen = {}, {}
    local attempts = 0

    while #combinations < GW_MAX_COMBINATIONS and attempts < GW_MAX_COMBINATIONS * 10 do
        attempts = attempts + 1

        -- k distinct indices, taken with a partial fisher-yates shuffle
        local pool = {}
        for i = 1, n do pool[i] = i end
        for i = 1, k do
            local j = math.random(i, n)
            pool[i], pool[j] = pool[j], pool[i]
        end

        local combination = {}
        for i = 1, k do combination[i] = pool[i] end
        table.sort(combination)

        local key = table.concat(combination, ",")
        if not seen[key] then
            seen[key] = true
            table.insert(combinations, combination)
        end
    end

    return combinations
end

hook.Add("InitPostEntity", "gw_InitPostEntity", function()
    GAMEMODE.GWRound:UpdateSettings()
    GAMEMODE.GWRound:RoundPreGame()
    GAMEMODE.GWRound.GeneratedSpawnPointCount = 0
end)


function GWRound:RoundPreGame()
    self:SetRoundState(GW_ROUND_PRE_GAME)
    hook.Run("GWPreGame")
    self:SetEndTime(CurTime() + self.PreGameDuration)
    timer.Create("gwPreGameTimer", self.PreGameDuration, 1,
                 function() self:RoundWaitForPlayers() end)
    timer.Simple(1, function() self:MeshController() end)
end

function GWRound:RoundWaitForPlayers()
    local roster = self:GetTeamRoster()

    -- do not start a round without enough players: the seeker rotation needs at least
    -- one seeker and one hider, and the configured minimum player count
    if #roster < math.max(self.MinPlayer, GW_MIN_PLAYERS) then
        -- check again after half a second second
        timer.Simple(0.5, function() self:RoundWaitForPlayers() end)
        -- clear remaning npcs to save recources
        for k, v in pairs(ents.FindByClass(GW_WALKER_CLASS)) do v:Remove() end
        self:SetEndTime(CurTime() + 1)
        self:SetRoundState(GW_ROUND_WAITING_PLAYERS)
        return
    end

    -- hand out this round's seekers before anyone can spawn
    self:AssignSeekerRotation()

    self:RoundCreateWalkers()

end

function GWRound:RoundCreateWalkers()

    self:SetRoundState(GW_ROUND_CREATING_NPCS)
    hook.Run("GWCreating")

    self:UpdateSpawnPoints()

    local wave = 1
    local playerCount = player.GetCount()

    self.WalkerCount = 0
    self.MaxWalkers = self.BaseWalkers + (playerCount * self.WalkerPerPly)

    if #self.SpawnPoints > self.MaxWalkers then
        self:SpawnNPCWave()
        MsgN("GW Spawned ", self.WalkerCount, " NPCs in 1 wave.")
    else
        local wpw
        for w = 0, math.ceil(self.MaxWalkers / #self.SpawnPoints) - 1, 1 do
            wave = wave + 1
            timer.Simple(w * 5, function()
                wpw = self.WalkerCount
                self:SpawnNPCWave()
                MsgN("GW Spawned ", self.WalkerCount - wpw, " NPCs in wave ",
                     w + 1, ".")
            end)
        end
        wave = wave - 1
    end

    timer.Simple(5 * wave, function()
        self:SetRoundState(GW_ROUND_HIDE)
        hook.Run("GWHide")
        for _, v in pairs(team.GetPlayers(GW_TEAM_HIDING)) do v:Spawn() end
    end)

    timer.Simple(5 + (5 * wave), function()
        for _, v in pairs(team.GetPlayers(GW_TEAM_SEEKING)) do
            v:Spawn()
            v:SetPos(v:GetPos() + Vector(2, 2, 2)) -- move them a little bit to make avoid players work
            v:Freeze(true)
            v:GodEnable()
            v:SetAvoidPlayers(true)
        end
    end)
    timer.Simple(self.HideDuration + (5 * wave),
                 function() self:RoundStart() end)
    self:SetEndTime(CurTime() + self.HideDuration + (5 * wave))

    PrintMessage(HUD_PRINTTALK,
                 "Map will change in " .. self.MaxRounds -
                     GetGlobalInt("RoundNumber", 0) .. " rounds.")
end

function GWRound:RoundStart()
    for _, v in pairs(team.GetPlayers(GW_TEAM_SEEKING)) do
        v:Freeze(false)
        v:SetAvoidPlayers(false)
        v:GodDisable()
    end

    timer.Create("RoundThink", 1, self.RoundDuration,
                 function() self:RoundThink() end)
    self.RoundTime = 1
    self:SetEndTime(CurTime() + self.RoundDuration)
    SetGlobalInt("RoundNumber", GetGlobalInt("RoundNumber", 0) + 1)

    self:SetRoundState(GW_ROUND_SEEK)
    hook.Run("GWSeek")
end

-- will be called every second
function GWRound:RoundThink()
    -- end conditions
    self.RoundTime = self.RoundTime + 1

    if self.RoundTime == self.RoundDuration then self:RoundEnd(false) end

    if team.NumPlayers(GW_TEAM_HIDING) < self.MinHiding or
        team.NumPlayers(GW_TEAM_SEEKING) < self.MinSeeking then self:RoundEnd() end

    local seekersWin = true
    for k, v in pairs(team.GetPlayers(GW_TEAM_HIDING)) do
        if v:Alive() then seekersWin = false end
    end

    local hidingWin = true
    for k, v in pairs(team.GetPlayers(GW_TEAM_SEEKING)) do
        if v:Alive() then hidingWin = false end
    end

    if seekersWin then self:RoundEnd(true) end

    if hidingWin then self:RoundEnd(false) end
end

function GWRound:RoundEnd(caught)
    hook.Run("GWOnRoundEnd", caught)

    if timer.Exists("RoundThink") then timer.Remove("RoundThink") end
    -- choose winner and stuff

    local postRoundDelay = 8

    if caught then
        GWNotifications:Add("gwVictory" .. team.GetName(GW_TEAM_SEEKING), "<font=gw_font_normal>" .. team.GetName(GW_TEAM_SEEKING) .. " Victory" .. "</font>", "", postRoundDelay)
        for _, v in pairs(team.GetPlayers(GW_TEAM_SEEKING)) do
            v:GWPlayTauntOnClients(ACT_GMOD_TAUNT_CHEER)
        end
        team.AddScore(GW_TEAM_SEEKING, 1)
    else
        GWNotifications:Add("gwVictory" .. team.GetName(GW_TEAM_HIDING), "<font=gw_font_normal>" .. team.GetName(GW_TEAM_HIDING) .. " Victory" .. "</font>", "", postRoundDelay)
        for _, v in pairs(team.GetPlayers(GW_TEAM_HIDING)) do
            v:GWPlayTauntOnClients(ACT_GMOD_TAUNT_CHEER)
            if v:Alive() then v:AddFrags(1) end -- if still alive as hiding after round give them one point (frag)
        end
        team.AddScore(GW_TEAM_HIDING, 1)
    end

    -- reset reroll protections and funcs
    for _, v in pairs(team.GetPlayers(GW_TEAM_HIDING)) do
        v:SetGWDiedInPrep(false)
        v:SetGWReRolledAbility(false)
    end

    timer.Create("gwPostRoundDelayTimer", postRoundDelay, 1, function() self:PostRound() end)
end

function GWRound:PostRound()

    if GetGlobalInt("RoundNumber", 0) >= self.MaxRounds then
        MsgN("GW Round cap reached changing map..")
        if MapVote then
            MsgN("GW Mapvote detected starting vote!")
            MapVote.Start()
            return
        end
        game.LoadNextMap()
    end

    -- cleanup everythiung except generated spawn points
    game.CleanUpMap(false, {"info_player_start"})

    for _, walker in pairs(ents.FindByClass(GW_WALKER_CLASS)) do walker:Remove() end

    -- Remove some HL2 entities
    local hl2EntClasses = {
        "weapon_357",
        "weapon_pistol",
        "weapon_bugbait",
        "weapon_crossbow",
        "weapon_crowbar",
        "weapon_frag",
        "weapon_physcannon",
        "weapon_ar2",
        "weapon_rpg",
        "weapon_slam",
        "weapon_shotgun",
        "weapon_smg1",
        "weapon_stunstick"
    }

    for _, hl2EntClass in pairs(hl2EntClasses) do
        for _, hl2Ent in pairs(ents.FindByClass(hl2EntClass)) do hl2Ent:Remove() end
    end

    timer.Simple(self.PostRoundDuration,
                 function() self:RoundWaitForPlayers() end)
    self:SetEndTime(CurTime() + self.PostRoundDuration)
    self:SetRoundState(GW_ROUND_POST)
    hook.Run("GWPostRound")

    self:UpdateSettings()
    -- teams are not swapped here any more: the seeker rotation assigns them when the
    -- next round starts (see AssignSeekerRotation)

end

-- Players currently taking part in the game, ordered by a stable key so the rotation
-- is not at the mercy of join order
function GWRound:GetTeamRoster()
    local roster = {}

    for _, ply in pairs(player.GetAll()) do
        local plyTeam = ply:Team()
        if plyTeam == GW_TEAM_HIDING or plyTeam == GW_TEAM_SEEKING then
            table.insert(roster, ply)
        end
    end

    table.sort(roster, function(a, b)
        return GWRound:GetPlayerRosterKey(a) < GWRound:GetPlayerRosterKey(b)
    end)

    return roster
end

-- Unique, stable per connected player. Bots share a SteamID so their entity index is
-- part of their key, a human keeps the same key over a reconnect.
function GWRound:GetPlayerRosterKey(ply)
    if ply:IsBot() then return "bot:" .. ply:EntIndex() end
    return "sid:" .. tostring(ply:SteamID64())
end

function GWRound:GetRosterKeys(roster)
    local keys = {}
    for _, ply in pairs(roster) do table.insert(keys, self:GetPlayerRosterKey(ply)) end
    return keys
end

function GWRound:RosterChanged(roster)
    if not self.SeekerRosterKeys then return true end

    local keys = self:GetRosterKeys(roster)
    if #keys ~= #self.SeekerRosterKeys then return true end

    for i = 1, #keys do
        if keys[i] ~= self.SeekerRosterKeys[i] then return true end
    end

    return false
end

-- Start a fresh pass over the possible seeker groups for the current roster
function GWRound:BuildSeekerCycle(roster, seekerCount)
    local playerCount = #roster
    local possible = Binomial(playerCount, seekerCount, GW_MAX_COMBINATIONS)

    if possible <= GW_MAX_COMBINATIONS then
        -- full binomial cycle: every possible seeker group exactly once
        self.SeekerCycle = ShuffleList(BuildCombinations(playerCount, seekerCount))
    else
        -- too many possible groups to play them all, sample a pass instead
        self.SeekerCycle = ShuffleList(BuildRandomCombinations(playerCount, seekerCount))
    end

    self.SeekerRosterKeys = self:GetRosterKeys(roster)
    self.SeekerCycleSeekers = seekerCount
    self.SeekerCycleIndex = 0
    self.SeekerCyclePass = (self.SeekerCyclePass or 0) + 1

    local possibleText = possible > GW_MAX_COMBINATIONS and
                             (GW_MAX_COMBINATIONS .. "+") or tostring(possible)

    MsgN("GW Seeker rotation, pass ", self.SeekerCyclePass, ": ", playerCount, " players, ",
         seekerCount, " seekers, ", possibleText, " possible seeker groups, dealing ",
         #self.SeekerCycle, " of them.")
end

-- Pick this round's seekers out of the rotating list of seeker groups and put every
-- other player on the hiding team
function GWRound:AssignSeekerRotation()
    local roster = self:GetTeamRoster()
    local playerCount = #roster

    if playerCount < GW_MIN_PLAYERS then
        MsgN("GW Seeker rotation skipped, not enough players taking part.")
        return false
    end

    -- someone always has to hide, so the seeker slots can never take the whole server
    local seekerCount = math.Clamp(self.SeekerCount, 1, playerCount - 1)
    if seekerCount < self.SeekerCount then
        PrintMessage(HUD_PRINTTALK, "Not enough players for " .. self.SeekerCount ..
                                       " seekers, using " .. seekerCount .. ".")
    end

    if self:RosterChanged(roster) or not self.SeekerCycle or #self.SeekerCycle == 0 or
        self.SeekerCycleSeekers ~= seekerCount then
        -- the old pass refers to players that are not here any more (or the seeker
        -- count changed), so it has to be rebuilt
        self:BuildSeekerCycle(roster, seekerCount)
    elseif self.SeekerCycleIndex >= #self.SeekerCycle then
        -- pass dealt out completely, start the next one
        self:BuildSeekerCycle(roster, seekerCount)

        -- do not deal the same seeker group twice in a row
        if #self.SeekerCycle > 1 and
            self.LastSeekerGroupKey == table.concat(self.SeekerCycle[1], ",") then
            self.SeekerCycle[1], self.SeekerCycle[2] = self.SeekerCycle[2], self.SeekerCycle[1]
        end
    end

    self.SeekerCycleIndex = self.SeekerCycleIndex + 1
    local seekerGroup = self.SeekerCycle[self.SeekerCycleIndex]

    if not seekerGroup then
        MsgN("GW Seeker rotation failed, empty seeker cycle.")
        return false
    end

    self.LastSeekerGroupKey = table.concat(seekerGroup, ",")

    local seekers = {}
    for _, rosterIndex in pairs(seekerGroup) do
        local seeker = roster[rosterIndex]
        if IsValid(seeker) then seekers[seeker] = true end
    end

    local seekerNames = {}

    for _, ply in pairs(player.GetAll()) do
        local plyTeam = ply:Team()
        if plyTeam == GW_TEAM_HIDING or plyTeam == GW_TEAM_SEEKING then
            local isSeeker = seekers[ply] ~= nil
            if isSeeker then table.insert(seekerNames, ply:Nick()) end
            ply:SetTeam(isSeeker and GW_TEAM_SEEKING or GW_TEAM_HIDING)
            ply:KillSilent()
        end
    end

    if #seekerNames > 0 then
        PrintMessage(HUD_PRINTTALK, "Seekers this round: " .. table.concat(seekerNames, ", "))
    end

    MsgN("GW Seeker rotation, pass ", (self.SeekerCyclePass or 0), ", group ",
         self.SeekerCycleIndex, "/", #self.SeekerCycle, ": ", table.concat(seekerNames, ", "))

    return true
end

function GWRound:IsRoundActive()
    return self:IsCurrentState(GW_ROUND_CREATING_NPCS) or self:IsCurrentState(GW_ROUND_HIDE) or
               self:IsCurrentState(GW_ROUND_SEEK)
end

function GWRound:SpawnNPCWave()

    for _, v in pairs(self.SpawnPoints) do
        if self.WalkerCount >= self.MaxWalkers then break end

        local occupied = false
        for _, ent in pairs(ents.FindInBox(v:GetPos() + Vector(-16, -16, 0),
                                           v:GetPos() + Vector(16, 16, 72))) do
            if ent:GetClass() == GW_WALKER_CLASS then occupied = true end
        end

        if not occupied then
            local walker = ents.Create(GW_WALKER_CLASS)
            if not IsValid(walker) then break end
            walker:SetPos(v:GetPos())
            walker:Spawn()
            walker:Activate()
            self.WalkerCount = self.WalkerCount + 1
        end

    end

end

function GWRound:UpdateSettings()

    self.BaseWalkers = GetConVar("gw_basewalkeramount"):GetInt()
    self.WalkerPerPly = GetConVar("gw_walkerperplayer"):GetFloat()
    self.PreGameDuration = GetConVar("gw_pregameduration"):GetInt()
    self.RoundDuration = GetConVar("gw_roundduration"):GetInt()
    self.HideDuration = GetConVar("gw_hideduration"):GetInt()
    self.PostRoundDuration = GetConVar("gw_postroundduration"):GetInt()
    self.MaxRounds = GetConVar("gw_maxrounds"):GetInt()
    self.MinPlayer = GetConVar("gw_minplayer"):GetInt()
    self.SeekerCount = math.max(1, GetConVar("gw_seekercount"):GetInt())

    -- the seeker slots per round are fixed by gw_seekercount and handed out by the
    -- rotation, so a playable round just needs one player left on each team
    self.MinHiding = 1
    self.MinSeeking = 1

end

function GWRound:MeshController()
    if navmesh.IsLoaded() then
        MsgN("GW Navmesh loaded waiting for game to start.")
    else
        timer.Remove("gwPreGameTimer")
        self:SetRoundState(GW_ROUND_NAV_GEN)
        navmesh.BeginGeneration()
        -- force generate
        if not navmesh.IsGenerating() then
            self:UpdateSpawnPoints()

            local tr = util.TraceLine({
                start = self.SpawnPoints[1]:GetPos(),
                endpos = self.SpawnPoints[1]:GetPos() - Vector(0, 0, 100),
                filter = self.SpawnPoints[1]
            })

            local ent = ents.Create("info_player_start")
            ent:SetPos(tr.HitPos)
            ent:Spawn()
            navmesh.BeginGeneration()
        end

        if not navmesh.IsGenerating() then
            PrintMessage(HUD_PRINTCENTER,
                         "Guess Who Navmesh generation failed, try to reload the map a few times.\nIf it still fails try a diffrent map!")
        else
            timer.Create("gwNavmeshGen", 1, 0, function()
                PrintMessage(HUD_PRINTCENTER,
                             "Generating navmesh, this will take some time!\nUp to 10min (worst case) depending on map size and your system.\nYou will only need to do this once.")
            end)
        end
    end
end

function GWRound:UpdateSpawnPoints()
    self.SpawnPoints = ents.FindByClass("info_player_start")
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("info_player_deathmatch"))
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("info_player_combine"))
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("info_player_rebel"))

    -- CS Maps
    self.SpawnPoints = table.Add(self.SpawnPoints, ents.FindByClass(
                                        "info_player_counterterrorist"))
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("info_player_terrorist"))

    -- DOD Maps
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("info_player_axis"))
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("info_player_allies"))

    -- (Old) GMod Maps
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("gmod_player_start"))

    -- TF Maps
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("info_player_teamspawn"))

    -- INS Maps
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("ins_spawnpoint"))

    -- AOC Maps
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("aoc_spawnpoint"))

    -- Dystopia Maps
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("dys_spawn_point"))

    -- PVKII Maps
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("info_player_pirate"))
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("info_player_viking"))
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("info_player_knight"))

    -- DIPRIP Maps
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("diprip_start_team_blue"))
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("diprip_start_team_red"))

    -- OB Maps
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("info_player_red"))
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("info_player_blue"))

    -- SYN Maps
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("info_player_coop"))

    -- ZPS Maps
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("info_player_human"))
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("info_player_zombie"))

    -- ZM Maps
    self.SpawnPoints = table.Add(self.SpawnPoints,
                                    ents.FindByClass("info_player_deathmatch"))
    self.SpawnPoints = table.Add(self.SpawnPoints, ents.FindByClass(
                                        "info_player_zombiemaster"))

    -- FOF Maps
    self.SpawnPoints = table.Add( self.SpawnPoints, ents.FindByClass("info_player_fof"))
    self.SpawnPoints = table.Add( self.SpawnPoints, ents.FindByClass("info_player_desperado"))
    self.SpawnPoints = table.Add( self.SpawnPoints, ents.FindByClass("info_player_vigilante"))

    -- L4D Maps
    self.SpawnPoints = table.Add( self.SpawnPoints, ents.FindByClass("info_survivor_rescue"))

    -- try to create more spawnpoints if we dont have enough
    if #self.SpawnPoints < 5 then
        local locations = {
            Vector(48, 0, 2),
            Vector(-48, 0, 2),
            Vector(0, 48, 2),
            Vector(0, -48, 2),
            Vector(48, 48, 2),
            Vector(48, -48, 2),
            Vector(-48, 48, 2),
            Vector(-48, -48, 2),
            Vector(96, 0, 2),
            Vector(-96, 0, 2),
            Vector(0, 96, 2),
            Vector(0, -96, 2),
            Vector(96, 96, 2),
            Vector(96, -96, 2),
            Vector(-96, 96, 2),
            Vector(-96, -96, 2),
        }

        for _, spawnPoint in pairs(self.SpawnPoints) do
            for _, locationOffset in pairs(locations) do
                local location = spawnPoint:GetPos() + locationOffset

                local tr = util.TraceHull({
                    start = location,
                    endpos = location,
                    maxs = Vector(16, 16, 72),
                    mins = Vector(-16, -16, 0),
                })

                if self.GeneratedSpawnPointCount < 16 and not tr.Hit then
                    local newSpawnPoint = ents.Create("info_player_start")
                    if not IsValid(newSpawnPoint) then break end
                    newSpawnPoint:SetPos(location)
                    newSpawnPoint:Spawn()
                    newSpawnPoint:Activate()
                    table.insert(self.SpawnPoints, newSpawnPoint)
                    self.GeneratedSpawnPointCount = self.GeneratedSpawnPointCount + 1
                end

            end
        end
    end

    local rand = math.random
    local n = #self.SpawnPoints

    while n > 2 do

        local k = rand(n) -- 1 <= k <= n

        self.SpawnPoints[n], self.SpawnPoints[k] = self.SpawnPoints[k],
                                                   self.SpawnPoints[n]
        n = n - 1
    end
end

function GWRound:SetRoundState(state)

    self.RoundState = state

    self:SendRoundState(state)

end

function GWRound:GetRoundState() return self.RoundState end

function GWRound:IsCurrentState(state) return self.RoundState == state end

function GWRound:SendRoundState(state, ply)

    net.Start("gwRoundState")
    net.WriteUInt(state, 8)
    return ply and net.Send(ply) or net.Broadcast()

end

function GWRound:SetEndTime(time) SetGlobalFloat("gwEndTime", time) end
