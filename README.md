# Escanor - Cruel Sun

A self-contained, object-oriented Roblox Luau implementation of Escanor's
Cruel Sun ability, created for the HiddenDevs Luau Scripter application.

## Submission

- [Direct Luau submission file](CruelSunClient.client.luau)
- [Working Roblox demonstration](https://www.roblox.com/games/105831675964647/)
- Studio path: `game.StarterPlayer.StarterPlayerScripts.CruelSunClient`

The submitted LocalScript contains the complete client ability and has no
ModuleScript requirements. It directly implements charge and compression math,
CFrame placement, animation synchronization, raycast projectile physics, VFX
scaling, cooldown state, lifecycle cleanup, and the validated remote protocol.

The Roblox place also contains assets and supporting presentation scripts. A
server companion validates cast timing, cooldowns, positions, hitbox radius,
and damage; that separation is required because clients cannot securely award
damage themselves.

## Author

[@sillyrelshy](https://github.com/Relshy)
