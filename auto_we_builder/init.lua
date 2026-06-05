-- Auto WE Builder Mod - Complete Fixed Version
-- Fixes: Floating NPC, Instant Building, Wrong Shapes, Syntax Errors

local modname = "auto_we_builder"
local modpath = minetest.get_modpath(modname)

-- Configuration
local BUILD_DELAY = 0.5 -- Seconds between each block placement
local WALK_SPEED = 2.5

-- Helper: Parse .we schematic file
local function parse_we_file(filepath)
    local file = io.open(filepath, "r")
    if not file then
        minetest.log("error", "[Auto WE Builder] Cannot open file: " .. filepath)
        return nil
    end

    local content = file:read("*all")
    file:close()

    if not content or content == "" then
        return nil
    end

    local blocks = {}
    
    -- Check if it's a serialized Lua format (starts with version number like "5:")
    if string.match(content, "^%d+:") then
        -- Try to load as Lua chunk
        local func, err
        if loadstring then
            func, err = loadstring(content)
        else
            func, err = load(content, "we_schema", "t", _G)
        end
        
        if func then
            local success, data = pcall(func)
            if success and type(data) == "table" then
                -- Extract nodes from the data structure
                local node_list = data
                if type(data[1]) == "table" then node_list = data[1] end
                if data.nodes then node_list = data.nodes end

                if type(node_list) == "table" then
                    for _, entry in ipairs(node_list) do
                        if type(entry) == "table" and #entry >= 4 then
                            local bx, by, bz = tonumber(entry[1]), tonumber(entry[2]), tonumber(entry[3])
                            local name = entry[4]
                            if bx and by and bz and name then
                                table.insert(blocks, {x=bx, y=by, z=bz, name=name})
                            end
                        end
                    end
                end
            end
        else
            minetest.log("error", "[Auto WE Builder] Failed to load Lua schema: " .. (err or "unknown error"))
        end
    else
        -- Plain text format: x y z nodename
        for line in content:gmatch("[^\r\n]+") do
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

    if #blocks == 0 then
        minetest.log("error", "[Auto WE Builder] No blocks found in schema: " .. filepath)
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

    -- Sort by Y (bottom up), then X, then Z
    table.sort(blocks, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        if a.x ~= b.x then return a.x < b.x end
        return a.z < b.z
    end)

    return blocks
end

-- Register Entity
minetest.register_entity("auto_we_builder:npc_builder", {
    initial_properties = {
        hp_max = 1,
        physical = true,
        collide_with_objects = true,
        weight = 70,
        collisionbox = {-0.3, 0.0, -0.3, 0.3, 1.75, 0.3},
        visual = "mesh",
        mesh = "character.b3d",
        textures = {"character.png"},
        automatic_rotate = 0,
        gravity = -9.8,
        stepheight = 1.1,
    },

    staticdata = "",
    
    -- Custom fields
    owner = "",
    state = "IDLE",
    build_queue = {},
    current_block_index = 0,
    last_build_time = 0,
    base_pos = nil,
    facing_direction = 0,

    on_activate = function(self, staticdata, dtime_s)
        self.object:set_armor_groups({immortal = 1})
        -- Fix: Use separate arguments for start/end frames instead of tables
        self.object:set_animation(0, 45, 15, true)
        self.state = "IDLE"
        self.last_build_time = minetest.get_us_time() / 1000000.0
    end,

    on_step = function(self, dtime, moveresult)
        local pos = self.object:get_pos()
        if not pos then return end
        
        local now = minetest.get_us_time() / 1000000.0

        -- State Machine
        if self.state == "IDLE" or self.state == "FOLLOWING" then
            self:handle_following(pos, dtime)
        elseif self.state == "BUILDING" then
            self:handle_building(pos, now, dtime)
        elseif self.state == "MOVING_UP" then
            self:handle_moving_up(pos, dtime)
        end
    end,

    handle_following = function(self, pos, dtime)
        local player = self.owner and minetest.get_player_by_name(self.owner)
        if not player then
            -- Find nearest player
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
        
        if not player then 
            self.state = "IDLE"
            self.object:set_velocity({x=0, y=0, z=0})
            -- Fix: Use separate arguments for start/end frames
            self.object:set_animation(0, 45, 15, true)
            return 
        end

        self.owner = player:get_player_name()
        local p_pos = player:get_pos()
        local look_dir = player:get_look_horizontal()
        
        -- Target: 2.5 blocks behind player
        local target_x = p_pos.x - math.sin(look_dir) * 2.5
        local target_z = p_pos.z + math.cos(look_dir) * 2.5
        local target_y = p_pos.y

        local target_pos = {x=target_x, y=target_y, z=target_z}

        -- Find ground at target
        local ground_pos = self:find_ground(target_pos)
        if ground_pos then
            target_pos.y = ground_pos.y
        end

        -- Move towards target
        local dist = vector.distance(pos, target_pos)
        if dist > 1.0 then
            self.state = "FOLLOWING"
            
            local dir = vector.normalize({x=target_x - pos.x, y=0, z=target_z - pos.z})
            local velocity = self.object:get_velocity()
            
            self.object:set_velocity({
                x = dir.x * WALK_SPEED,
                y = velocity.y, -- Keep vertical velocity for gravity
                z = dir.z * WALK_SPEED
            })
            
            local yaw = math.atan2(dir.z, dir.x) - math.pi/2
            self.object:set_yaw(yaw)
            self.facing_direction = (math.deg(math.atan2(dir.z, dir.x)) + 90) % 360
            
            -- Fix: Use separate arguments for start/end frames
            self.object:set_animation(160, 180, 30, true)
        else
            self.state = "IDLE"
            self.object:set_velocity({x=0, y=0, z=0})
            -- Fix: Use separate arguments for start/end frames
            self.object:set_animation(0, 45, 15, true)
            
            -- Snap to ground if idle
            local my_ground = self:find_ground(pos)
            if my_ground and math.abs(pos.y - my_ground.y) > 0.2 then
                self.object:set_pos(my_ground)
            end
        end
    end,

    handle_building = function(self, pos, now, dtime)
        if (now - self.last_build_time) < BUILD_DELAY then
            return
        end

        if self.current_block_index > #self.build_queue then
            self.state = "IDLE"
            minetest.chat_send_all("[Auto WE Builder] Finished building!")
            -- Fix: Use separate arguments for start/end frames
            self.object:set_animation(0, 45, 15, true)
            return
        end

        -- Place next block
        local block = self.build_queue[self.current_block_index]
        if block then
            -- Calculate world position with rotation
            local rad = math.rad(self.facing_direction)
            local cos_a = math.cos(rad)
            local sin_a = math.sin(rad)
            
            local rx = block.x * cos_a - block.z * sin_a
            local rz = block.x * sin_a + block.z * cos_a
            
            local place_pos = {
                x = math.floor(self.base_pos.x + rx + 0.5),
                y = math.floor(self.base_pos.y + block.y + 0.5),
                z = math.floor(self.base_pos.z + rz + 0.5)
            }

            -- Place node
            minetest.set_node(place_pos, {name = block.name})
            
            -- Particles
            minetest.add_particlespawner({
                amount = 5,
                time = 0.1,
                minpos = vector.subtract(place_pos, 0.2),
                maxpos = vector.add(place_pos, 0.2),
                minvel = {x=-0.5, y=0.5, z=-0.5},
                maxvel = {x=0.5, y=1, z=0.5},
                minacc = {x=0, y=-9.8, z=0},
                maxacc = {x=0, y=-9.8, z=0},
                minexptime = 0.5,
                maxexptime = 1.0,
                minsize = 0.2,
                maxsize = 0.4,
                texture = "default_stone.png",
            })

            self.object:set_animation(185, 205, 30, false)
            self.last_build_time = now
            self.current_block_index = self.current_block_index + 1
            
            -- Check if next block is on higher layer
            if self.current_block_index <= #self.build_queue then
                local next_block = self.build_queue[self.current_block_index]
                if next_block.y > block.y then
                    self.state = "MOVING_UP"
                end
            end
        end
    end,

    handle_moving_up = function(self, pos, dtime)
        -- Move NPC up by 1 block
        local target_y = self.base_pos.y + 1
        
        -- Simple lift
        local new_pos = {x=pos.x, y=target_y, z=pos.z}
        self.object:set_pos(new_pos)
        
        self.base_pos.y = self.base_pos.y + 1
        self.state = "BUILDING"
        -- Fix: Use separate arguments for start/end frames
        self.object:set_animation(0, 45, 15, true)
    end,

    -- Helpers
    find_ground = function(self, start_pos)
        local ray_start = {x=start_pos.x, y=start_pos.y + 5, z=start_pos.z}
        local ray_end = {x=start_pos.x, y=start_pos.y - 5, z=start_pos.z}
        
        local hit = minetest.raycast(ray_start, ray_end, false, true)
        local pointed = hit:next()
        
        if pointed and pointed.type == "node" then
            return {
                x = start_pos.x,
                y = pointed.above.y,
                z = start_pos.z
            }
        end
        
        return {x=start_pos.x, y=start_pos.y, z=start_pos.z}
    end,

    on_rightclick = function(self, clicker)
        if not clicker:is_player() then return end
        self.owner = clicker:get_player_name()
        self:show_building_menu(clicker)
    end,

    show_building_menu = function(self, player)
        local schema_path = modpath .. "/schema/"
        local files = {}
        
        -- Safe directory listing
        local list_func = minetest.list_dir or minetest.get_dir_list
        if list_func then
            local success, result = pcall(list_func, schema_path)
            if success and result then
                for _, fname in ipairs(result) do
                    if string.endswith(fname, ".we") then
                        table.insert(files, fname)
                    end
                end
            end
        end

        local item_list = ""
        if #files == 0 then
            item_list = "label[0,2;No .we files found in mod/schema/]"
        else
            local i = 0
            for _, f in ipairs(files) do
                local name = f:sub(1, -4) -- Remove .we
                item_list = item_list .. "image_button[0," .. i .. ";4,1;schema_" .. i .. ";" .. name .. ";" .. name .. "]"
                i = i + 1
            end
        end

        local formspec = "size[8,6]" ..
            "label[0,0;Select Building to Construct:]" ..
            item_list ..
            "button[0,5,2,1;cancel;Cancel]"
            
        minetest.show_formspec(player:get_player_name(), "auto_we_builder:menu", formspec)
    end,

    start_building = function(self, schema_name)
        local schema_path = modpath .. "/schema/" .. schema_name .. ".we"
        local blocks = parse_we_file(schema_path)
        
        if not blocks or #blocks == 0 then
            minetest.chat_send_player(self.owner, "Failed to load schema: " .. schema_name)
            return
        end

        self.build_queue = blocks
        self.current_block_index = 1
        
        -- Set base position
        local pos = self.object:get_pos()
        local ground = self:find_ground(pos)
        local ground_y = ground and ground.y or pos.y
        
        self.base_pos = {
            x = math.floor(pos.x + 0.5),
            y = math.floor(ground_y + 0.5),
            z = math.floor(pos.z + 0.5)
        }
        
        self.state = "BUILDING"
        minetest.chat_send_player(self.owner, "Starting to build: " .. schema_name .. " (" .. #blocks .. " blocks)")
    end
})

-- Register Spawn Egg
minetest.register_craftitem("auto_we_builder:spawn_egg", {
    description = "Spawn Auto Builder NPC",
    inventory_image = "default_egg.png",
    on_use = function(itemstack, user, pointed_thing)
        if pointed_thing.type ~= "node" then return itemstack end
        local pos = vector.add(pointed_thing.above, {x=0, y=1, z=0})
        minetest.add_entity(pos, "auto_we_builder:npc_builder")
        itemstack:take_item()
        return itemstack
    end
})

minetest.register_craft({
    output = "auto_we_builder:spawn_egg",
    recipe = {
        {"default:stick", "default:paper", "default:stick"},
        {"default:paper", "default:diamond", "default:paper"},
        {"default:stick", "default:paper", "default:stick"}
    }
})

-- Register Command
minetest.register_chatcommand("spawn_auto_builder", {
    params = "",
    description = "Spawn an Auto WE Builder NPC",
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then return false end
        local pos = player:get_pos()
        pos.y = pos.y + 1
        minetest.add_entity(pos, "auto_we_builder:npc_builder")
        return true, "NPC spawned!"
    end
})

-- Handle Formspec Input
minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "auto_we_builder:menu" then return end
    
    local entity = nil
    -- Find the NPC that opened the menu
    local pos = player:get_pos()
    local objs = minetest.get_objects_in_area(vector.subtract(pos, 5), vector.add(pos, 5))
    for _, obj in ipairs(objs) do
        local ent = obj:get_luaentity()
        if ent and ent.name == "auto_we_builder:npc_builder" and ent.owner == player:get_player_name() then
            entity = ent
            break
        end
    end

    if not entity then return end

    if fields.cancel or fields.quit then
        return true
    end

    for key, _ in pairs(fields) do
        if string.find(key, "schema_") then
            local idx = tonumber(string.sub(key, 8))
            -- Re-get file list to match index
            local schema_path = modpath .. "/schema/"
            local files = {}
            local list_func = minetest.list_dir or minetest.get_dir_list
            if list_func then
                local success, result = pcall(list_func, schema_path)
                if success and result then
                    for _, fname in ipairs(result) do
                        if string.endswith(fname, ".we") then
                            table.insert(files, fname)
                        end
                    end
                end
            end
            
            if files[idx+1] then
                local schema_name = files[idx+1]:sub(1, -4)
                entity:start_building(schema_name)
            end
        end
    end
    return true
end)

minetest.log("action", "[Auto WE Builder] Mod loaded successfully.")
