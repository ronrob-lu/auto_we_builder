-- Auto WE Builder Mod - Fixed Version
-- Features: Smooth movement, Realistic building delay, Correct shape parsing

local modpath = minetest.get_modpath("auto_we_builder")
local S = minetest.get_translator("auto_we_builder")

-- Configuration
local BUILD_DELAY = 0.5 -- Seconds between each block placement (Fixes instant build)
local WALK_SPEED = 2.5

-- Helper: Parse .we file format
local function parse_we_file(filename)
    local filepath = modpath .. "/schema/" .. filename
    local file = io.open(filepath, "r")
    if not file then
        minetest.log("error", "[Auto WE Builder] Cannot open file: " .. filepath)
        return nil
    end

    local content = file:read("*all")
    file:close()

    -- Remove version header if present (e.g., "5:..." or "2:...")
    local header_end = content:find("\n")
    if header_end and content:sub(1, 2):match("%d+:") then
        content = content:sub(header_end + 1)
    end

    local blocks = {}
    local min_x, min_y, min_z = math.huge, math.huge, math.huge
    local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

    -- Simple parser for node lines: "x y z nodename param1 param2 ..."
    for line in content:gmatch("[^\n]+") do
        -- Skip comments or empty lines
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

    if #blocks == 0 then return nil end

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
        automatic_rotate = false, -- Fixed: must be boolean or number depending on MT version, false is safe for most
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
        self.base_y = nil -- Ground level lock
        self.object:set_animation({x=0, y=79}, 30, 0)
        
        if self.base_y then
            local pos = self.object:get_pos()
            if pos then
                pos.y = self.base_y
                self.object:set_pos(pos)
            end
        end
    end,

    on_step = function(self, dtime, moveresult)
        local pos = self.object:get_pos()
        if not pos then return end
        
        local vel = self.object:get_velocity()
        
        -- 1. Ground Detection & Floating Fix
        -- Raycast down to find ground
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

        -- 2. State Machine Logic
        
        -- STATE: BUILDING (With Delay)
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
                 if vel.x == 0 and vel.z == 0 and vel.y == 0 then
                     self.object:set_animation({x=0, y=79}, 30, 0)
                 end
            end
        end
        
        -- STATE: FINISH_LAYER
        if self.state == "FINISH_LAYER" then
            self.timer_finish = self.timer_finish - dtime
            if self.timer_finish <= 0 then
                self.state = "MOVING_UP"
            end
            self.object:set_animation({x=0, y=79}, 30, 0)
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

minetest.register_craft_item("auto_we_builder:spawn_egg", {
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
