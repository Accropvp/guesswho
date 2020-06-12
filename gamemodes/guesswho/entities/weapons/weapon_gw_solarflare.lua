AddCSLuaFile()

SWEP.Base = "weapon_gwbase"
SWEP.Name = "Solarflare"
SWEP.AbilitySound = "ambient/energy/zap1.wav"

SWEP.AbilityRange = 400
SWEP.AbilityShowTargetHalos = true
SWEP.AbilityDuration = 6
SWEP.AbilityCastTime = 1.5

function SWEP:Ability()

	local ply = self.Owner

	local effectdata = EffectData()
	effectdata:SetEntity(ply)
	effectdata:SetRadius(self.AbilityRange)
	effectdata:SetMagnitude(self.AbilityCastTime)
	util.Effect( "gw_solarflare", effectdata, true, true )

	for _, v in pairs( player.GetAll() ) do
		if v:GetPos():Distance( ply:GetPos() ) < self.AbilityRange and v:IsSeeking() then
			local distanceRatio = v:GetPos():Distance(ply:GetPos()) / self.AbilityRange
			timer.Simple(distanceRatio * self.AbilityCastTime, function()
				if IsValid(v) then
					v:SetNWFloat("gw_ability_solarflare_endtime", CurTime() + self.AbilityDuration)
					v:SetNWFloat("gw_ability_solarflare_druation", self.AbilityDuration)
				end
			end)
		end
	end
end

if CLIENT then
	hook.Add( "HUDPaint", "gw_solarflare_hud", function()
		local endTime = LocalPlayer():GetNWFloat("gw_ability_solarflare_endtime")
		if endTime > CurTime() then
			local alpha = 255
			local durationRemaining = endTime - CurTime()
			-- linear fade out
			if durationRemaining <= LocalPlayer():GetNWFloat("gw_ability_solarflare_druation") / 2 then
				alpha = durationRemaining * 110
			end
			surface.SetDrawColor(255, 255, 255, math.Clamp(alpha, 0, 255))
			surface.DrawRect(0, 0, ScrW(), ScrH())
		end
	end )
end
