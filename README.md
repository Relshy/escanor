# Escanor - Cruel Sun

An object-oriented Roblox Luau implementation of Escanor's Cruel Sun ability,
created for the HiddenDevs Luau Scripter application.

## Submission

- [Direct Luau submission file](CruelSunClient.client.luau)
- [Working Roblox demonstration](https://www.roblox.com/games/105831675964647/)
- Studio path: `game.StarterPlayer.StarterPlayerScripts.CruelSunClient`

The submitted LocalScript contains 673 nonblank, non-comment Luau lines. It
directly implements cast state, movement and axe control, three-stage charge
compression, CFrame placement, animation synchronization, raycast projectile
physics, cooldown state, lifecycle cleanup, and the validated remote protocol.

One focused presentation module owns reusable VFX, audio, and camera feedback,
while a configuration module holds shared immutable tuning. A server companion
validates cast timing, cooldowns, positions, hitbox radius, and damage; clients
cannot securely award damage themselves.

## Author

[@sillyrelshy](https://github.com/Relshy)
