Auto WE Builder NPC Mod
========================

A Minetest/Luanti mod that spawns an NPC builder that follows the player and builds .we schematic files.

Features:
- NPC follows behind the player
- Right-click to open building selection menu
- Selects from .we files in the schema folder
- Builds layer by layer, moving upward as needed
- Realistic player-like appearance with walking and building animations
- Uses character.b3d model and agent_char.png texture

Installation:
1. Copy this folder to your mods directory
2. Enable the mod in your world's mod configuration

Usage:
1. Spawn the NPC with /spawn_auto_builder command
2. Follow behind you automatically
3. Right-click to select a building to construct
4. Watch it build layer by layer!

Dependencies:
- default (required for basic nodes)
- formspec (built-in)
- schematics (for .we file support)

License: MIT
