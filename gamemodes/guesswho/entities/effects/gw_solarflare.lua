AddCSLuaFile()

function EFFECT:Init(data)
    self.Entity = data:GetEntity()
    self.Radius = 0
    self.FinalRadius = data:GetRadius()
    self.Duration = data:GetMagnitude()
    self.Center = self.Entity:OBBCenter()
    self:SetPos(self.Entity:GetPos())
end

function EFFECT:Think()
    self:SetPos(self.Entity:GetPos())
    self.Center = self.Entity:OBBCenter()
    if self.Radius < self.FinalRadius then
        self.Radius = self.Radius + FrameTime() * (self.FinalRadius / self.Duration)
        return true
    end

    return false
end

function EFFECT:Render()
    local pos = self:GetPos() + self.Center

    render.SetColorMaterial()
    render.DrawSphere(pos, self.Radius, 20, 20, Color(255, 255, 255, 255))
end
