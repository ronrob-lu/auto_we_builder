-- Auto WE Builder Mod - Complete Fixed Version
-- Fixes: Floating, Instant Build, Wrong Shapes, Entity Registration

local mod_name = "auto_we_builder"
local S = minetest.get_translator(mod_name)

-- Configuration
local BUILD_DELAY = 0.5 -- Seconds between blocks
local WALK_SPEED = 2.5
local BUILD_HEIGHT_OFFSET = 1.5 -- Height of eyes relative to feet

-- Global storage for active builders
local active_builders = {}

-- Helper: Parse .we file (Supports both Text and Lua Serialized formats)
local function parse_we_file(filepath)
    local file = io.open(filepath, "r")
    if not file then
        minetest.log("error", "[Auto WE Builder] Cannot open file: " .. filepath)
        return nil
    end

    local content = file.read(file, "*a")
    file:close()

    if not content or #content == 0 then
        minetest.log("error", "[Auto WE Builder] File empty: " .. filepath)
        return nil
    end

    local blocks = {}
    
    -- Check if it's a serialized Lua format (starts with "return" or version number like "5:")
    if string.sub(content, 1, 6) == "return" or string.match(content, "^%d+:") then
        -- Try to load as Lua chunk
        local func, err
        if loadstring then -- Lua 5.1 (Minetest < 5.8 approx)
            func, err = loadstring(content)
        else -- Lua 5.2+
            func, err = load(content, "we_schema", "t", _G)
        end
        
        if func then
            local success, data = pcall(func)
            if success and type(data) == "table" then
                -- Extract nodes from serialized data structure
                -- Structure varies, usually data[1] or data.nodes contains the list
                local node_list = data
                if type(data[1]) == "table" then node_list = data[1] end
                if data.nodes then node_list = data.nodes end
                
                if type(node_list) == "table" then
                    for _, entry in ipairs(node_list) do
                        -- Format: {x, y, z, nodename} or similar
                        if type(entry) == "table" and #entry >= 4 then
                            table.insert(blocks, {
                                x = tonumber(entry[1]) or 0,
                                y = tonumber(entry[2]) or 0,
                                z = tonumber(entry[3]) or 0,
                                name = entry[4]
                            })
                        end
                    end
                end
            else
                minetest.log("error", "[Auto WE Builder] Failed to execute Lua schema: " .. tostring(err))
            end
        else
            minetest.log("error", "[Auto WE Builder] Lua parse error: " .. tostring(err))
        end
    else
        -- Plain text format: x y z nodename
        for line in content:gmatch("[^\n]+") do
            -- Skip comments and version lines if any
            if not string.match(line, "^#") and not string.match(line, "^%d+:") then
                local x, y, z, name = line:match("^%s*(-?%d+)%s+(-?%d+)%s+(-?%d+)%s+(%S+)")
                if x and y and z and name then
                    table.insert(blocks, {
                        x = tonumber(x),
                        y = tonumber(y),
                        z = tonumber(z),
                        name = name
                    })
                end
            end
        end
    end

    if #blocks == 0 then
        minetest.log("error", "[Auto WE Builder] No blocks parsed from " .. filepath)
        return nil
    end

    -- Normalize coordinates (shift so min x,y,z is 0,0,0)
    local min_x, min_y, min_z = blocks[1].x, blocks[1].y, blocks[1].z
    for _, b in ipairs(blocks) do
        if b.x < min_x then min_x = b.x end
        if b.y < min_y then min_y = b.y end
        if b.z < min_z then min_z = b.z end
    end

    for _, b in ipairs(blocks) do
        b.x = b.x - min_x
        b.y = b.y - min_y
        b.z = b.z - min_z
    end

    -- Sort by Y (bottom up), then X, then Z for logical building order
    table.sort(blocks, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        if a.x ~= b.x then return a.x < b.x end
        return a.z < b.z
    end)

    return blocks
end

-- Register the NPC Entity
minetest.register_entity("auto_we_builder:npc_builder", {
    initial_properties = {
        hp_max = 100,
        physical = true,
        collide_with_objects = true,
        collisionbox = {-0.3, 0.0, -0.3, 0.3, 1.7, 0.3},
        visual = "mesh",
        mesh = "character.b3d",
        textures = {"character.png"}, -- Uses default player texture
        animations = {
            stand = {range = {x = 0, y = 79}, speed = 30, loop = true},
            walk = {range = {x = 168, y = 187}, speed = 30, loop = true},
            mine = {range = {x = 189, y = 198}, speed = 30, loop = false},
            dig_place = {range = {x = 190, y = 198}, speed = 30, loop = false},
        },
        automatic_rotate = false, -- Important: prevents spinning
        make_footstep_sound = true,
        stepheight = 1.1,
        gravity = -9.8,
        max_fall = 3.0,
    },

    staticdata = "",
    
    -- Custom fields for our logic
    _state = "IDLE", -- IDLE, FOLLOWING, BUILDING, MOVING_UP
    _target_pos = nil,
    _build_queue = nil,
    _build_index = 0,
    _last_action_time = 0,
    _owner = nil,
    _ground_y = nil,

    on_activate = function(self, staticdata, dtime_s)
        self.object:set_armor_groups({immortal = 1})
        self._state = "IDLE"
        self._last_action_time = minetest.get_us_time()
        -- Initialize animation
        self.object:set_animation({x=0, y=79}, {x=0, y=79}, 30, true)
    end,

    on_step = function(self, dtime, moveresult)
        local pos = self.object:get_pos()
        if not pos then return end
        
        local now = minetest.get_us_time() / 1000000.0 -- seconds
        
        -- State Machine
        if self._state == "IDLE" or self._state == "FOLLOWING" then
            -- Find owner/player to follow
            local player = self._owner and minetest.get_player_by_name(self._owner)
            if not player then
                -- Find nearest player if owner lost
                local players = minetest.get_connected_players()
                local min_dist = 5
                for _, p in ipairs(players) do
                    local dist = vector.distance(pos, p:get_pos())
                    if dist < min_dist then
                        player = p
                        min_dist = dist
                    end
                end
            end

            if player then
                self._owner = player:get_player_name()
                local p_pos = player:get_pos()
                -- Calculate target: 2 nodes behind player
                local look_dir = player:get_look_horizontal()
                local target_x = p_pos.x - math.sin(look_dir) * 2
                local target_z = p_pos.z + math.cos(look_dir) * 2
                
                local dist = vector.distance(pos, {x=target_x, y=pos.y, z=target_z})
                
                if dist > 0.5 then
                    self._state = "FOLLOWING"
                    self._target_pos = {x=target_x, y=pos.y, z=target_z}
                    
                    -- Move towards target
                    local dir = vector.normalize({x=target_x - pos.x, y=0, z=target_z - pos.z})
                    local velocity = self.object:get_velocity()
                    
                    -- Only apply horizontal movement, let gravity handle Y
                    self.object:set_velocity({
                        x = dir.x * WALK_SPEED,
                        y = velocity.y, 
                        z = dir.z * WALK_SPEED
                    })
                    
                    -- Set look direction
                    local yaw = math.atan2(dir.z, dir.x) - math.pi/2
                    self.object:set_yaw(yaw)
                    
                    -- Animation: Walk
                    self.object:set_animation({x=168, y=187}, {x=168, y=187}, 30, true)
                else
                    self._state = "IDLE"
                    self.object:set_velocity({x=0, y=0, z=0})
                    -- Animation: Stand
                    self.object:set_animation({x=0, y=79}, {x=0, y=79}, 30, true)
                end
            else
                self._state = "IDLE"
                self.object:set_velocity({x=0, y=0, z=0})
                self.object:set_animation({x=0, y=79}, {x=0, y=79}, 30, true)
            end
            
            -- Ground detection ONLY when IDLE/FOLLOWING (prevents nervous floating while building)
            -- Raycast down to find ground
            local start_pos = {x=pos.x, y=pos.y + 1, z=pos.z}
            local end_pos = {x=pos.x, y=pos.y - 2, z=pos.z}
            local ray = minetest.raycast(start_pos, end_pos, false, true)
            local pointed = ray:next()
            
            if pointed and pointed.type == "node" then
                local ground_h = pointed.pos.y + 1 -- Surface is top of this node
                -- If we are floating above ground, snap down (simple stabilization)
                if pos.y > ground_h + 0.1 then
                    -- Let gravity do its work, but ensure we aren't stuck in air
                    -- The physics engine handles the fall, we just don't interfere
                end
                self._ground_y = ground_h
            else
                self._ground_y = nil
            end

        elseif self._state == "BUILDING" then
            if not self._build_queue or self._build_index > #self._build_queue then
                -- Building finished
                self._state = "IDLE"
                self.object:set_animation({x=0, y=79}, {x=0, y=79}, 30, true)
                minetest.chat_send_all(S("Building complete!"))
                return
            end

            -- Check delay
            if now - self._last_action_time < BUILD_DELAY then
                -- Keep playing build animation or idle if waiting
                if self.object:get_animation().x ~= 190 then
                     self.object:set_animation({x=190, y=198}, {x=190, y=198}, 30, false)
                end
                return
            end

            -- Place next block
            local block = self._build_queue[self._build_index]
            if block then
                -- Calculate world position based on NPC pos and rotation
                local yaw = self.object:get_yaw() + math.pi/2 -- Adjust for model facing
                local cos_a = math.cos(yaw)
                local sin_a = math.sin(yaw)
                
                -- Rotate offset
                local rx = block.x * cos_a - block.z * sin_a
                local rz = block.x * sin_a + block.z * cos_a
                
                local place_pos = {
                    x = math.floor(pos.x + rx + 0.5),
                    y = math.floor(pos.y + block.y + 0.5), -- Relative to feet
                    z = math.floor(pos.z + rz + 0.5)
                }
                
                -- Place node
                minetest.set_node(place_pos, {name = block.name})
                
                -- Particles
                minetest.add_particlespawner({
                    amount = 5,
                    time = 0.1,
                    minpos = place_pos,
                    maxpos = place_pos,
                    minvel = {x=-1, y=1, z=-1},
                    maxvel = {x=1, y=2, z=1},
                    minacc = {x=0, y=-9.8, z=0},
                    maxacc = {x=0, y=-9.8, z=0},
                    minexptime = 0.5,
                    maxexptime = 1.0,
                    minsize = 2,
                    maxsize = 4,
                    texture = "default_stone.png",
                })
                
                self._build_index = self._build_index + 1
                self._last_action_time = now
                
                -- Check if layer finished (next block has higher Y)
                if self._build_index <= #self._build_queue then
                    if self._build_queue[self._build_index].y > block.y then
                        self._state = "MOVING_UP"
                        self._target_y = pos.y + 1
                    end
                end
            end

        elseif self._state == "MOVING_UP" then
            -- Simple hop up
            local vel = self.object:get_velocity()
            if pos.y >= self._target_y then
                self.object:set_velocity({x=0, y=0, z=0})
                self._state = "BUILDING"
                self._last_action_time = now -- Reset delay for next block
            else
                -- Hop
                if vel.y <= 0 then
                    self.object:set_velocity({x=0, y=4, z=0})
                end
            end
            self.object:set_animation({x=168, y=187}, {x=168, y=187}, 30, true)
        end
    end,
    
    on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
        -- Knockback disabled for stability
        return false
    end,
})

-- Spawn Command
minetest.register_chatcommand("spawn_auto_builder", {
    params = "",
    description = "Spawns an Auto WE Builder NPC",
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if not player then return false end
        
        local pos = player:get_pos()
        pos.y = pos.y + 1
        
        local obj = minetest.add_entity(pos, "auto_we_builder:npc_builder")
        if obj then
            minetest.chat_send_player(name, "Auto WE Builder spawned!")
            return true
        else
            minetest.chat_send_player(name, "Failed to spawn NPC.")
            return false
        end
    end,
})

-- Formspec Menu
local function get_schema_files()
    local mod_path = minetest.get_mod_storage():get_string("mod_path") -- Not reliable directly
    -- Fallback to known path logic or iterate
    local paths = {
        minetest.get_modpath("auto_we_builder") .. "/schema",
        minetest.get_worldpath() .. "/schematics",
    }
    
    local files = {}
    for _, path in ipairs(paths) do
        if minetest.request_insecure_environment then
            local env = minetest.request_insecure_environment()
            if env and env.io then
                local h = env.io.popen("ls \"" .. path .. "\" 2>/dev/null") -- Unix
                if h then
                    for line in h:lines() do
                        if string.match(line, "%.we$") then
                            table.insert(files, {name=line, path=path})
                        end
                    end
                    h:close()
                end
            end
        else
            -- Secure fallback using minetest.list_dir if available
            local list = minetest.list_dir(path)
            if list then
                for _, fname in ipairs(list) do
                    if string.match(fname, "%.we$") then
                        table.insert(files, {name=fname, path=path})
                    end
                end
            end
        end
    end
    return files
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname == "auto_we_builder:select_building" then
        if fields.quit then return end
        
        local selected = nil
        for key, _ in pairs(fields) do
            if string.startswith(key, "select_") then
                selected = string.sub(key, 8) -- Remove "select_"
                break
            end
        end
        
        if selected then
            local pname = player:get_player_name()
            local pos = player:get_pos()
            -- Find nearest NPC in front of player
            local look_dir = player:get_look_horizontal()
            local search_pos = {
                x = pos.x - math.sin(look_dir) * 3,
                y = pos.y,
                z = pos.z + math.cos(look_dir) * 3
            }
            
            local found_obj = nil
            local objects = minetest.get_objects_in_area(
                {x=search_pos.x-2, y=search_pos.y-1, z=search_pos.z-2},
                {x=search_pos.x+2, y=search_pos.y+2, z=search_pos.z+2}
            )
            
            for _, obj in ipairs(objects) do
                local ent = obj:get_luaentity()
                if ent and ent.name == "auto_we_builder:npc_builder" then
                    found_obj = obj
                    break
                end
            end
            
            if found_obj then
                local ent = found_obj:get_luaentity()
                local file_data = nil
                
                -- We need the full path, re-scan or store globally? 
                -- For simplicity, assume standard mod path for now or pass path in field
                -- Re-implementing quick scan for the specific file
                local modpath = minetest.get_modpath("auto_we_builder")
                local full_path = modpath .. "/schema/" .. selected
                
                local blocks = parse_we_file(full_path)
                if blocks then
                    ent._state = "BUILDING"
                    ent._build_queue = blocks
                    ent._build_index = 1
                    ent._last_action_time = minetest.get_us_time() / 1000000.0
                    minetest.chat_send_player(pname, "Started building: " .. selected)
                else
                    minetest.chat_send_player(pname, "Error parsing file: " .. selected)
                end
            else
                minetest.chat_send_player(pname, "No builder found nearby!")
            end
        end
    end
end)

minetest.register_globalstep(function(dtime)
    -- Periodic check to refresh menu list if needed, or handle timeouts
    -- Not strictly necessary for this simple implementation
end)

-- Register item to spawn
minetest.register_craftitem("auto_we_builder:spawn_egg", {
    description = "Spawn Auto WE Builder",
    inventory_image = "default_chest.png^[colorize:#aaaaaa",
    stack_max = 1,
    on_use = function(itemstack, user, pointed_thing)
        if pointed_thing.type == "node" then
            local pos = pointed_thing.above
            minetest.add_entity(pos, "auto_we_builder:npc_builder")
            itemstack:take_item()
            return itemstack
        end
        return itemstack
    end,
})

minetest.register_craft({
    output = "auto_we_builder:spawn_egg",
    recipe = {
        {"default:stone", "default:steel_ingot", "default:stone"},
        {"default:steel_ingot", "default:diamond", "default:steel_ingot"},
        {"default:stone", "default:steel_ingot", "default:stone"},
    }
}) - Complete Fixed Version
-- Features: No floating, Realistic building delay (0.5s per block), Correct .we file parsing

local modpath = minetest.get_modpath("auto_we_builder")
local S = minetest.get_translator("auto_we_builder")

-- Configuration
local BUILD_DELAY = 0.5 -- Seconds between each block placement
local WALK_SPEED = 2.5

-- Helper: Parse .we file format (handles both binary Lua and text formats)
local function parse_we_file(filename)
    local filepath = modpath .. "/schema/" .. filename
    local file = io.open(filepath, "r")
    if not file then
        minetest.log("error", "[Auto WE Builder] Cannot open file: " .. filepath)
        return nil
    end

    local content = file:read("*all")
    file:close()

    local blocks = {}
    local min_x, min_y, min_z = math.huge, math.huge, math.huge
    local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

    -- Try to detect format: if starts with number followed by colon, it's serialized Lua
    if content:match("^%d+:") then
        -- This is a serialized Lua format (WorldEdit export)
        -- Use loadstring/load to safely execute and get the data
        local func
        if loadstring then
            func = loadstring(content)
        else
            func = load(content, filename, "t", {})
        end
        
        if not func then
            minetest.log("error", "[Auto WE Builder] Failed to load schema: " .. filename)
            return nil
        end
        
        local success, data = pcall(func)
        if not success or not data then
            minetest.log("error", "[Auto WE Builder] Schema returned no data: " .. filename)
            return nil
        end
        
        -- Data is now a table of block objects
        for _, b in ipairs(data) do
            if b.x and b.y and b.z and b.name then
                table.insert(blocks, {x=b.x, y=b.y, z=b.z, name=b.name})
                if b.x < min_x then min_x = b.x end
                if b.y < min_y then min_y = b.y end
                if b.z < min_z then min_z = b.z end
                if b.x > max_x then max_x = b.x end
                if b.y > max_y then max_y = b.y end
                if b.z > max_z then max_z = b.z end
            end
        end
    else
        -- Plain text format: "x y z nodename ..."
        for line in content:gmatch("[^\n]+") do
            if not line:match("^#") and line:trim() ~= "" then
                local parts = {}
                for part in line:gmatch("%S+") do
                    table.insert(parts, part)
                end

                if #parts >= 4 then
                    local x = tonumber(parts[1])
                    local y = tonumber(parts[2])
                    local z = tonumber(parts[3])
                    local nodename = parts[4]

                    if x and y and z then
                        table.insert(blocks, {x=x, y=y, z=z, name=nodename})
                        if x < min_x then min_x = x end
                        if y < min_y then min_y = y end
                        if z < min_z then min_z = z end
                        if x > max_x then max_x = x end
                        if y > max_y then max_y = y end
                        if z > max_z then max_z = z end
                    end
                end
            end
        end
    end

    if #blocks == 0 then 
        minetest.log("error", "[Auto WE Builder] No blocks found in: " .. filename)
        return nil 
    end

    -- Normalize coordinates to start at 0,0,0 relative to the structure
    for _, b in ipairs(blocks) do
        b.x = b.x - min_x
        b.y = b.y - min_y
        b.z = b.z - min_z
    end

    -- Sort blocks: Bottom to Top (Y), then X, then Z for logical building order
    table.sort(blocks, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        if a.x ~= b.x then return a.x < b.x end
        return a.z < b.z
    end)

    return {
        blocks = blocks,
        size = {
            x = max_x - min_x + 1,
            y = max_y - min_y + 1,
            z = max_z - min_z + 1
        }
    }
end

-- Rotate coordinates based on direction
local function rotate_block(x, z, dir)
    -- 0: North, 1: East, 2: South, 3: West
    if dir == 0 then return x, z end
    if dir == 1 then return -z, x end
    if dir == 2 then return -x, -z end
    if dir == 3 then return z, -x end
    return x, z
end

minetest.register_entity("auto_we_builder:npc", {
    initial_properties = {
        hp_max = 100,
        armor_groups = {fleshy = 100},
        collisionbox = {-0.3, 0.0, -0.3, 0.3, 1.7, 0.3},
        visual = "mesh",
        mesh = "character.b3d",
        textures = {"auto_we_builder_char.png"},
        makes_footstep_sound = true,
        automatic_rotate = 0,
        animations = {
            stand = {range = {x=0, y=79}, speed=30, loop=true},
            walk = {range = {x=168, y=187}, speed=30, loop=true},
            dig_place = {range = {x=190, y=210}, speed=15, loop=false}
        },
        stepheight = 0.6,
    },
    
    physical_state = true,
    collide_with_objects = true,
    weight = 50,
    
    on_activate = function(self, staticdata, dtime_s)
        self.state = "IDLE"
        self.build_queue = {}
        self.last_build_time = 0
        self.base_y = nil
        self.object:set_animation({x=0, y=79}, 30, 0)
        
        -- Ensure we start on ground
        local pos = self.object:get_pos()
        if pos then
            local ground = minetest.raycast(pos, {x=pos.x, y=pos.y-2, z=pos.z}, false, true):next()
            if ground then
                self.base_y = ground.pos.y + 1
                pos.y = self.base_y
                self.object:set_pos(pos)
            end
        end
    end,

    on_step = function(self, dtime, moveresult)
        local pos = self.object:get_pos()
        if not pos then return end
        
        local vel = self.object:get_velocity()
        
        -- STATE: BUILDING (With Delay) - NO GROUND CHECK WHILE BUILDING
        if self.state == "BUILDING" then
            local now = minetest.get_us_time() / 1000000
            
            if #self.build_queue > 0 and (now - self.last_build_time) >= BUILD_DELAY then
                local block = self.build_queue[1]
                table.remove(self.build_queue, 1)
                
                -- Place Block
                local node_def = minetest.registered_nodes[block.name]
                if node_def then
                    minetest.set_node(block.world_pos, {name=block.name})
                    -- Particle effect
                    minetest.add_particlespawner({
                        amount=3, time=0.1,
                        minpos={x=block.world_pos.x-0.2, y=block.world_pos.y-0.2, z=block.world_pos.z-0.2},
                        maxpos={x=block.world_pos.x+0.2, y=block.world_pos.y+0.2, z=block.world_pos.z+0.2},
                        texture="bubble.png",
                        velocity={x=0,y=1,z=0}, acceleration={x=0,y=-2,z=0}
                    })
                end
                
                self.last_build_time = now
                
                -- Play Build Animation
                self.object:set_animation({x=190, y=210}, 15, 0)
                
                if #self.build_queue == 0 then
                     self.state = "FINISH_LAYER"
                     self.timer_finish = 0.5
                end
            else
                 -- Waiting for delay, stand still
                 self.object:set_animation({x=0, y=79}, 30, 0)
            end
            return -- Skip ground detection while building
        end
        
        -- STATE: FINISH_LAYER
        if self.state == "FINISH_LAYER" then
            self.timer_finish = self.timer_finish - dtime
            if self.timer_finish <= 0 then
                self.state = "MOVING_UP"
            end
            self.object:set_animation({x=0, y=79}, 30, 0)
            return
        end
        
        -- STATE: MOVING_UP
        if self.state == "MOVING_UP" then
            local target_y = (self.base_y or pos.y) + 1
            if pos.y < target_y - 0.5 then
                vel.y = 5
                self.object:set_velocity(vel)
                self.object:set_animation({x=168, y=187}, 30, 1)
            else
                pos.y = target_y
                self.object:set_pos(pos)
                vel.y = 0
                self.object:set_velocity(vel)
                self.base_y = target_y
                self.state = "IDLE"
                minetest.chat_send_all("Layer completed!")
            end
            return
        end
        
        -- IDLE STATE: Ground Detection & Floating Fix
        local ground_pos = minetest.raycast(pos, {x=pos.x, y=pos.y-2, z=pos.z}, false, true):next()
        local on_ground = false
        local current_ground_y = pos.y
        
        if ground_pos then
            local node = minetest.get_node(ground_pos.pos)
            local node_def = minetest.registered_nodes[node.name]
            local walkable = node_def and node_def.walkable
            
            if walkable then
                 if math.abs(ground_pos.pos.y - pos.y) < 1.6 then
                     on_ground = true
                     current_ground_y = ground_pos.pos.y + 1
                 end
            end
        end
        
        -- Apply Gravity if not on ground
        if not on_ground then
            vel.y = vel.y - (9.8 * dtime)
            self.object:set_velocity(vel)
            self.base_y = nil
        else
            -- Snap to ground if close to prevent floating/sinking
            if math.abs(pos.y - current_ground_y) > 0.1 then
                pos.y = current_ground_y
                self.object:set_pos(pos)
                vel.y = 0
                self.object:set_velocity(vel)
            elseif math.abs(vel.y) < 0.1 then
                vel.y = 0
                self.object:set_velocity(vel)
            end
            if not self.base_y then self.base_y = current_ground_y end
        end
        
        -- Safety reset
        if pos.y < -100 then
            self.object:remove()
        end
    end,

    on_rightclick = function(self, clicker)
        if not clicker:is_player() then return end
        local player_name = clicker:get_player_name()
        
        local files = {}
        local schema_path = modpath .. "/schema"
        
        local list_func = minetest.list_dir or minetest.get_dir_list
        if list_func then
            local success, result = pcall(list_func, schema_path)
            if success and result then
                for _, fname in ipairs(result) do
                    if fname:match("%.we$") then
                        table.insert(files, fname)
                    end
                end
            end
        end
        
        local file_list = ""
        if #files == 0 then
            file_list = "No .we files found!"
        else
            for i, f in ipairs(files) do
                file_list = file_list .. f .. "\n"
            end
        end
        
        local formspec = "size[8,9]" ..
            "label[0.5,0.5;Select Building Schema]" ..
            "textlist[0.5,1.5;7,5;filelist;" .. file_list .. ";false]" ..
            "button[0.5,7;3,1;build;Build Here]" ..
            "button[4,7;3,1;cancel;Cancel]"
            
        minetest.show_formspec(player_name, "auto_we_builder:select", formspec)
    end,
    
    on_receive_fields = function(self, player_name, formname, fields)
        if formname ~= "auto_we_builder:select" then return end
        if fields.cancel then return end
        
        if fields.build then
            local list_type = fields.filelist
            if not list_type then return end
            
            local selected_idx = nil
            if type(list_type) == "string" then
                local s = list_type:match("CHANGED:(%d+)")
                if s then selected_idx = tonumber(s) end
                if not selected_idx then selected_idx = tonumber(list_type) end
            end

            if selected_idx then
                local files = {}
                local list_func = minetest.list_dir or minetest.get_dir_list
                if list_func then
                    local success, result = pcall(list_func, modpath .. "/schema")
                    if success and result then
                        for _, fname in ipairs(result) do
                            if fname:match("%.we$") then table.insert(files, fname) end
                        end
                    end
                end
                
                if files[selected_idx] then
                    self:start_building(files[selected_idx])
                end
            end
        end
    end,

    start_building = function(self, filename)
        local data = parse_we_file(filename)
        if not data then
            minetest.chat_send_all("Error parsing file: " .. filename)
            return
        end
        
        local pos = self.object:get_pos()
        if not pos then return end
        
        local yaw = self.object:get_yaw() or 0
        local dir = math.floor((yaw / (math.pi * 2)) * 4 + 0.5) % 4
        
        minetest.chat_send_all("Starting to build: " .. filename .. " (" .. #data.blocks .. " blocks)")
        
        self.build_queue = {}
        
        for _, b in ipairs(data.blocks) do
            local rx, rz = rotate_block(b.x, b.z, dir)
            
            local forward_x = 0
            local forward_z = 0
            if dir == 0 then forward_z = -2
            elseif dir == 1 then forward_x = 2
            elseif dir == 2 then forward_z = 2
            elseif dir == 3 then forward_x = -2
            end
            
            local world_x = math.floor(pos.x + forward_x + rx)
            local world_y = math.floor((self.base_y or pos.y) + b.y)
            local world_z = math.floor(pos.z + forward_z + rz)
            
            table.insert(self.build_queue, {
                name = b.name,
                world_pos = {x=world_x, y=world_y, z=world_z}
            })
        end
        
        self.state = "BUILDING"
        self.last_build_time = 0
    end
})

minetest.register_chatcommand("spawn_auto_builder", {
    description = "Spawn the Auto WE Builder NPC",
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if not player then return false end
        local pos = player:get_pos()
        pos.y = pos.y + 1
        
        local obj = minetest.add_entity(pos, "auto_we_builder:npc")
        if obj then
            minetest.chat_send_all("Auto WE Builder NPC spawned!")
            return true
        end
        return false
    end
})

minetest.register_craftitem("auto_we_builder:spawn_egg", {
    description = "Auto WE Builder Spawn Egg",
    inventory_image = "auto_we_builder_char.png^[colorize:#ffffffaa",
    on_use = function(itemstack, user, pointed_thing)
        if pointed_thing.type ~= "node" then return end
        local pos = pointed_thing.above
        minetest.add_entity(pos, "auto_we_builder:npc")
        itemstack:take_item()
        return itemstack
    end
})

minetest.register_craft({
    output = "auto_we_builder:spawn_egg",
    recipe = {
        {"default:stick", "default:paper", "default:stick"},
        {"default:paper", "default:diamond", "default:paper"},
        {"default:stick", "default:paper", "default:stick"},
    }
})
