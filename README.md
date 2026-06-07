# Auto WE Builder NPC Mod
========================

A Minetest/Luanti mod that spawns an NPC builder that follows the player and builds `.we` WorldEdit schematic files.

## Features
- NPC follows behind the player with realistic walking physics (gravity, ground collision)
- Right-click to open building selection menu
- Selects from `.we` files in the `schema/` folder
- Builds layer by layer, moving upward as needed
- Realistic player-like appearance with walking and building animations
- Uses custom `auto_we_builder.b3d` model and texture

## Installation
1. Copy this folder to your mods directory
2. Enable the mod in your world's mod configuration

## Usage
1. Spawn the NPC with `/spawn_auto_builder` command OR craft a spawn egg
2. NPC follows behind you automatically with realistic player movement
3. Right-click the NPC to select a building to construct
4. Watch it build layer by layer!

## Custom Schematics
Place your `.we` schematic files in:
- `<modpath>/schema/`

## Dependencies
- `default` (required for basic nodes)
- `formspec` (built-in)

## License
MIT
