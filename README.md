# Escanor — Cruel Sun

A modular, object-oriented Roblox Luau implementation of Escanor's Cruel Sun
ability, created for the HiddenDevs Luau Scripter application.

## Submission

- [Direct Luau submission file](CruelSunClient.client.luau)
- [Working Roblox demonstration](https://www.roblox.com/games/105831675964647/)
- Studio path: `game.StarterPlayer.StarterPlayerScripts.CruelSunClient`

The submission file is the 447-line client orchestrator. It preserves the
required `-- Connected Discord-GitHub` verification comment on its first line
and delegates focused responsibilities to strict-typed controllers.

## Architecture

```text
ReplicatedStorage
├── CooldownController
└── CruelSun
    ├── Assets
    ├── Configuration
    ├── Remotes
    └── Signals

StarterPlayer
├── StarterCharacterScripts
│   └── EscanorM1Combo
└── StarterPlayerScripts
    ├── CruelSunClient
    ├── CruelSunImpactRocks
    ├── CruelSunSubtitle
    └── CruelSunModules
        ├── CharacterController
        ├── CompressionController
        ├── EffectsController
        ├── ImpactController
        └── ProjectileController

ServerScriptService
├── CruelSunServer
└── EscanorAxeServer
```

The repository contains the Luau source hierarchy. Visual assets, keyframe
sequences, sounds, BindableEvents, and RemoteEvents remain authored in the
linked Roblox place.

## Author

[@sillyrelshy](https://github.com/Relshy)
