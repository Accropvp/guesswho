GM.Name = "Guess Who"
GM.Author = "Lolleko"
GM.Email = "N/A"
GM.Website = "https://github.com/lolleko/guesswho"

GM.Version = "2.2d (80)"

GM.TeamBased = true

--Teams
GW_TEAM_HIDING = 1
GW_TEAM_SEEKING = 2

--Round states
GW_ROUND_PRE_GAME = 1
GW_ROUND_WAITING_PLAYERS = 2
GW_ROUND_CREATING_NPCS = 3
GW_ROUND_HIDE = 4
GW_ROUND_SEEK = 5
GW_ROUND_POST = 6
GW_ROUND_NAV_GEN = 9

GW_WALKER_CLASS = "gw_npc_walker"

--Shared CVars fallback
-- https://github.com/Facepunch/garrysmod-issues/issues/3323
local cVarFlags = {FCVAR_REPLICATED, FCVAR_ARCHIVE}
if CLIENT then
    cVarFlags = {FCVAR_REPLICATED}
end

CreateConVar("gw_target_finder_threshold", "700", cVarFlags, "The distance before the target finder will display nearby")
CreateConVar("gw_target_finder_enabled", "0", cVarFlags, "Wether target finder is enabled or not")
CreateConVar("gw_abilities_enabled", "1", cVarFlags, "Should hiding have abilities or not.")
CreateConVar("gw_touches_enabled", "1", cVarFlags, "Wether touching for weapons is enabled.")
CreateConVar("gw_touches_required", "3", cVarFlags, "The amount of seeker touches that are required for a hider to receive a new weapon.")
CreateConVar("gw_seeker_walk_speed", "100", cVarFlags, "Seeker Walk Speed")
CreateConVar("gw_seeker_run_speed", "200", cVarFlags, "Seeker Run Speed")
CreateConVar("gw_hiding_walk_speed", "100", cVarFlags, "Hiding Walk Speed")
CreateConVar("gw_hiding_run_speed", "200", cVarFlags, "Hiding Run Speed")
CreateConVar("gw_double_jump_enabled", "0", cVarFlags, "Wether Double Jumps are enabled or not")
CreateConVar("gw_minplayer", "2", cVarFlags, "The minimum amount of players before the game starts.")
CreateConVar("gw_seekercount", "2", cVarFlags, "The number of seekers each round, everyone else who takes part is hiding.")

-- The remaining settings from guesswho.txt, created here for the same reason: a dedicated
-- server that never opened the spawn menu settings still has every cvar the gamemode reads,
-- instead of GetConVar returning nil and the code that reads it erroring.
CreateConVar("gw_maxrounds", "8", cVarFlags, "The Amount of Rounds before a map change.")
CreateConVar("gw_basewalkeramount", "13", cVarFlags, "The base amount (minimum) of NPCs that spawn in a round.")
CreateConVar("gw_walkerperplayer", "1.20", cVarFlags, "The amount of NPCs to add for each player on the server.")
CreateConVar("gw_pregameduration", "20", cVarFlags, "The duration of the pause after a map change in seconds.")
CreateConVar("gw_roundduration", "300", cVarFlags, "The duration of a round (Seeking) in seconds")
CreateConVar("gw_hideduration", "30", cVarFlags, "The time that the hiding team gets to disappear in seconds.")
CreateConVar("gw_postroundduration", "5", cVarFlags, "The duration for the post round in seconds.")
CreateConVar("gw_damageonfailguess", "10", cVarFlags, "The damage a hunter receives if he hits an NPC and not a player.")
CreateConVar("gw_taunt_voice_enabled", "1", cVarFlags, "Sets if voice taunts are enabled.")
CreateConVar("gw_taunt_voice_seeker_enabled", "0", cVarFlags, "Sets if voice taunts for seekers are enabled.")
CreateConVar("gw_taunt_voice_cooldown", "10", cVarFlags, "Sets how long the cooldown on voice taunts should be (prevents spaming).")
CreateConVar("gw_taunt_body_enabled", "1", cVarFlags, "Sets if body taunts are enabled.")
CreateConVar("gw_disguise_seeker", "0", cVarFlags, "Wether seekers should have NPC models or not.")
CreateConVar("gw_changemodel_hiding", "1", cVarFlags, "Wether hiding can change their model or not.")
CreateConVar("gw_propfreeze_enabled", "1", cVarFlags, "Shoud props freeze or not.")

game.AddAmmoType({
    name = "gwDashCharges",
    dmgtype = DMG_GENERIC
})

DeriveGamemode("base")

-- The behaviour tree library the walker nextbot runs on. It is a plain Lua library, so it
-- lives with the other gamemode libraries instead of next to the entity scripts in
-- entities/entities, where GMod would try to load it as an entity definition.
GW_behaviour_tree_lib = include("libs/gw_behaviour_tree_lib.lua")

include("player_ext_shd.lua")
include("sh_config.lua")
include("sh_taunts.lua")
include("player_class/player_guess_who.lua")
include("player_class/player_hiding.lua")
include("player_class/player_seeker.lua")
include("sh_animations.lua")
include("sh_notifications.lua")

function GM:CreateTeams()
    team.SetUp( GW_TEAM_HIDING, "Hiding", self.GWConfig.TeamHidingColor )
    team.SetClass( GW_TEAM_HIDING, { "player_hiding" } )
    team.SetSpawnPoint( GW_TEAM_HIDING, "info_player_start" )
    team.SetSpawnPoint( GW_TEAM_HIDING, "info_player_deathmatch" )
    team.SetSpawnPoint( GW_TEAM_HIDING, "info_player_rebel" )
    team.SetSpawnPoint( GW_TEAM_HIDING, "info_player_combine" )
    team.SetSpawnPoint( GW_TEAM_HIDING, "info_player_counterterrorist" )
    team.SetSpawnPoint( GW_TEAM_HIDING, "info_player_terrorist" )

    team.SetUp( GW_TEAM_SEEKING, "Seekers", self.GWConfig.TeamSeekingColor )
    team.SetClass( GW_TEAM_SEEKING, { "player_seeker" } )
    team.SetSpawnPoint( GW_TEAM_SEEKING, "info_player_start" )
    team.SetSpawnPoint( GW_TEAM_SEEKING, "info_player_deathmatch" )
    team.SetSpawnPoint( GW_TEAM_SEEKING, "info_player_rebel" )
    team.SetSpawnPoint( GW_TEAM_SEEKING, "info_player_combine" )
    team.SetSpawnPoint( GW_TEAM_SEEKING, "info_player_counterterrorist" )
    team.SetSpawnPoint( GW_TEAM_SEEKING, "info_player_terrorist" )

    team.SetSpawnPoint( TEAM_SPECTATOR, "worldspawn" )
end

function GM:PlayerShouldTakeDamage( ply, victim )
    if ply:IsPlayer() and victim:IsPlayer() then
        if ply:Team() == victim:Team() then
            return false
        end
    end

    return true
end

function GM:ShouldCollide( ent1, ent2 )
    -- Players (seekers and hiders alike) pass through NPC walkers instead of bumping into them.
    -- Touch detection for weapons below is distance based, so it keeps working without physical collision.
    if (ent1:IsPlayer() and ent2:GetClass() == GW_WALKER_CLASS) or
       (ent2:IsPlayer() and ent1:GetClass() == GW_WALKER_CLASS) then
        return false
    end

    if GetConVar( "gw_abilities_enabled" ):GetBool() and GetConVar("gw_touches_enabled"):GetBool() and GAMEMODE.GWRound:IsCurrentState(GW_ROUND_SEEK) then
        local hider, seeker
        if ent1:IsPlayer() and ent2:IsPlayer() then
            if ent1:GWIsHiding() and ent2:GWIsSeeking() then
                hider = ent1
                seeker = ent2
            elseif ent2:GWIsHiding() and ent1:GWIsSeeking() then
                hider = ent2
                seeker = ent1
            end

            if hider and hider:GWGetLastSeekerTouch() + 3 < CurTime() and hider:GetPos():Distance(seeker:GetPos()) < 40 then
                hider:GWAddSeekerTouch()
            end
        end
    end

    return true
end

function GM:PlayerFootstep( ply, vPos, iFoot, strSoundName, fVolume, pFilter )

    if ply:GWIsHiding() then

        return true

    end

end
