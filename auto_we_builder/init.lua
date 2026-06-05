-- Auto WE Builder Mod - Complete Fixed Version
-- Fixes: Floating, Instant Build, Wrong Shapes, Entity Registration, Syntax Errors

local mod_name = "auto_we_builder"
local modpath = minetest.get_modpath(mod_name)
local S = minetest.get_translator(mod_name)

-- Configuration
local BUILD_DELAY = 0.5 -- Seconds between blocks
local WALK_SPEED = 2.5

-- Global storage for active builders
local active_builders = {}

-- Helper: Parse .we file (Supports both Text and Lua Serialized formats)
local function parse_we_file(filename)
    local filepath = modpath .. "/schema/" .. filename
    local file = io.open(filepath, "r")
    if not file then
        minetest.log("error", "[Auto WE Builder] Cannot open file: " .. filepath)
        return nil
    end

    local content = file:read("*all")
    file:close()

    if not content or #content == 0 then
        minetest.log("error", "[Auto WE Builder] File empty: " .. filepath)
        return nil
    end

    local blocks = {}
    
    -- Check if it's a serialized Lua format (starts with version number like "5:")
    if string.match(content, "^%d+:") then
        -- Try to load as Lua chunk
        local func, err
        if loadstring then -- Lua 5.1
            func, err = loadstring(content)
        else -- Lua 5.2+
            func, err = load(content, "we_schema", "t", _G)
        end
        
        if func then
            local success, data = pcall(func)
            if success and type(data) == "table" then
                local node_list = data
                if type(data[1]) == "table" then node_list = data[1] end
                if data.nodes then node_list = data.nodes end
                
                if type(node_list) == "table" then
                    for _, entry in ipairs(node_list) do
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

    -- Normalize coordinates
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

    -- Sort by Y (bottom up)
    table.sort(blocks, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        if a.x ~= b.x then return a.x < b.x end
        return a.z < b.z
    end)

    return blocks
end

-- Register the NPC Entity
minetest.register_entity(":" .. mod_name .. ":npc_builder", {
    initial_properties = {
        hp_max = 100,
        physical = true,
        collide_with_objects = true,
        collisionbox = {-0.3, 0.0, -0.3, 0.3, 1.7, 0.3},
        visual = "mesh",
        mesh = "character.b3d",
        textures = {"character.png"},
        animations = {
            stand = {range = {x = 0, y = 79}, speed = 30, loop = true},
            walk = {range = {x = 168, y = 187}, speed = 30, loop = true},
            dig_place = {range = {x = 190, y = 198}, speed = 30, loop = false},
        },
        automatic_rotate = 0,
        make_footstep_sound = true,
        stepheight = 1.1,
        gravity = -9.8,
        max_fall = 3.0,
    },

    _state = "IDLE",
    _build_queue = nil,
    _build_index = 0,
    _last_action_time = 0,
    _owner = nil,

    on_activate = function(self, staticdata, dtime_s)
        self.object:set_armor_groups({immortal = 1})
        self._state = "IDLE"
        self._last_action_time = minetest.get_us_time() / 1000000.0
        self.object:set_animation({x=0, y=79}, {x=0, y=79}, 30, true)
    end,

    on_step = function(self, dtime, moveresult)
        local pos = self.object:get_pos()
        if not pos then return end
        
        local now = minetest.get_us_time() / 1000000.0
        
        if self._state == "IDLE" or self._state == "FOLLOWING" then
            local player = self._owner and minetest.get_player_by_name(self._owner)
            if not player then
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
                local look_dir = player:get_look_horizontal()
                local target_x = p_pos.x - math.sin(look_dir) * 2
                local target_z = p_pos.z + math.cos(look_dir) * 2
                
                local dist = vector.distance(pos, {x=target_x, y=pos.y, z=target_z})
                
                if dist > 0.5 then
                    self._state = "FOLLOWING"
                    local dir = vector.normalize({x=target_x - pos.x, y=0, z=target_z - pos.z})
                    local velocity = self.object:get_velocity()
                    
                    self.object:set_velocity({
                        x = dir.x * WALK_SPEED,
                        y = velocity.y, 
                        z = dir.z * WALK_SPEED
                    })
                    
                    local yaw = math.atan2(dir.z, dir.x) - math.pi/2
                    self.object:set_yaw(yaw)
                    self.object:set_animation({x=168, y=187}, {x=168, y=187}, 30, true)
                else
                    self._state = "IDLE"
                    self.object:set_velocity({x=0, y=0, z=0})
                    self.object:set_animation({x=0, y=79}, {x=0, y=79}, 30, true)
                end
            else
                self._state = "IDLE"
                self.object:set_velocity({x=0, y=0, z=0})
                self.object:set_animation({x=0, y=79}, {x=0, y=79}, 30, true)
            end

        elseif self._state == "BUILDING" then
            if not self._build_queue or self._build_index > #self._build_queue then
                self._state = "IDLE"
                self.object:set_animation({x=0, y=79}, {x=0, y=79}, 30, true)
                minetest.chat_send_all(S("Building complete!"))
                return
            end

            if now - self._last_action_time < BUILD_DELAY then
                return
            end

            local block = self._build_queue[self._build_index]
            if block then
                local yaw = self.object:get_yaw() + math.pi/2
                local cos_a = math.cos(yaw)
                local sin_a = math.sin(yaw)
                
                local rx = block.x * cos_a - block.z * sin_a
                local rz = block.x * sin_a + block.z * cos_a
                
                local place_pos = {
                    x = math.floor(pos.x + rx + 0.5),
                    y = math.floor(pos.y + block.y + 0.5),
                    z = math.floor(pos.z + rz + 0.5)
                }
                
                minetest.set_node(place_pos, {name = block.name})
                
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
                
                if self._build_index <= #self._build_queue then
                    if self._build_queue[self._build_index].y > block.y then
                        self._state = "MOVING_UP"
                        self._target_y = pos.y + 1
                    end
                end
            end

        elseif self._state == "MOVING_UP" then
            local vel = self.object:get_velocity()
            if pos.y >= self._target_y then
                self.object:set_velocity({x=0, y=0, z=0})
                self._state = "BUILDING"
                self._last_action_time = now
            else
                if vel.y <= 0 then
                    self.object:set_velocity({x=0, y=4, z=0})
                end
            end
            self.object:set_animation({x=168, y=187}, {x=168, y=187}, 30, true)
        end
    end,
    
    on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
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
        
        local obj = minetest.add_entity(pos, mod_name .. ":npc_builder")
        if obj then
            minetest.chat_send_player(name, "Auto WE Builder spawned!")
            return true
        else
            minetest.chat_send_player(name, "Failed to spawn NPC.")
            return false
        end
    end,
})

-- Get schema files
local function get_schema_files()
    local schema_path = modpath .. "/schema"
    local files = {}
    
    local list = minetest.list_dir(schema_path)
    if list then
        for _, fname in ipairs(list) do
            if string.match(fname, "%.we$") then
                table.insert(files, fname)
            end
        end
    end
    
    return files
end

-- Formspec Menu
minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname == mod_name .. ":select_building" then
        if fields.quit then return end
        
        local selected = nil
        for key, _ in pairs(fields) do
            if string.startswith(key, "select_") then
                selected = string.sub(key, 8)
                break
            end
        end
        
        if selected then
            local pos = player:get_pos()
            local look_dir = player:get_look_horizontal()
            local search_pos = {
                x = pos.x - math.sin(look_dir) * 3,
                y = pos.y,
                z = pos.z + math.cos(look_dir) * 3
            }
            
            local objects = minetest.get_objects_in_area(
                {x=search_pos.x-2, y=search_pos.y-1, z=search_pos.z-2},
                {x=search_pos.x+2, y=search_pos.y+2, z=search_pos.z+2}
            )
            
            local npc = nil
            for _, obj in ipairs(objects) do
                local ent = obj:get_luaentity()
                if ent and ent.name == mod_name .. ":npc_builder" then
                    npc = ent
                    break
                end
            end
            
            if npc then
                local blocks = parse_we_file(selected)
                if blocks then
                    npc._state = "BUILDING"
                    npc._build_queue = blocks
                    npc._build_index = 1
                    npc._last_action_time = minetest.get_us_time() / 1000000.0
                    minetest.chat_send_player(player:get_player_name(), "Starting to build: " .. selected .. " (" .. #blocks .. " blocks)")
                else
                    minetest.chat_send_player(player:get_player_name(), "Error: Could not parse schema file")
                end
            else
                minetest.chat_send_player(player:get_player_name(), "No builder found nearby!")
            end
        end
    end
end)

minetest.register_on_player_rightclick(function(player, pointed_thing)
    if pointed_thing.type ~= "object" then return end
    local ent = pointed_thing.ref:get_luaentity()
    if not ent or ent.name ~= mod_name .. ":npc_builder" then return end
    
    local files = get_schema_files()
    if #files == 0 then
        minetest.show_formspec(player:get_player_name(), mod_name .. ":no_files", "size[8,3]label[1,1;No .we files found!\nPlace files in mod/schema folder]button[2,2;2,1;close;Close]")
        return
    end
    
    local formspec = "size[10,8;]label[1,0;Select Building]"
    local y = 1
    for i, fname in ipairs(files) do
        local display_name = fname:gsub("%.we$", "")
        formspec = formspec .. "button[0," .. y .. ";9,1;select_" .. fname .. ";" .. display_name .. "]"
        y = y + 1
        if y > 7 then break end
    end
    formspec = formspec .. "button[3,7;3,1;quit;Cancel]"
    
    minetest.show_formspec(player:get_player_name(), mod_name .. ":select_building", formspec)
end)

-- Spawn Egg Item
minetest.register_craftitem(mod_name .. ":spawn_egg", {
    description = "Spawn Auto WE Builder",
    inventory_image = "default_chest.png^[colorize:#aaaaaa",
    stack_max = 1,
    on_use = function(itemstack, user, pointed_thing)
        if pointed_thing.type == "node" then
            local pos = pointed_thing.above
            minetest.add_entity(pos, mod_name .. ":npc_builder")
            itemstack:take_item()
            return itemstack
        end
        return itemstack
    end,
})

minetest.register_craft({
    output = mod_name .. ":spawn_egg",
    recipe = {
        {"default:stone", "default:steel_ingot", "default:stone"},
        {"default:steel_ingot", "default:diamond", "default:steel_ingot"},
        {"default:stone", "default:steel_ingot", "default:stone"},
    }
})
