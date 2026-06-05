-- Auto WE Builder NPC Mod - Main Initialization File
-- This mod creates an NPC that follows the player and builds .we schematic files

local S = minetest.get_translator("auto_we_builder")

-- Global storage for NPC data
auto_we_builder = {
    npcs = {},  -- Table to store all active NPCs
    schema_path = minetest.get_modpath("auto_we_builder") .. "/schema",
}

-- Load dependencies
minetest.register_on_mods_loaded(function()
    -- Check if we have the necessary mods
    if not minetest.get_modpath("default") then
        minetest.log("error", "[Auto WE Builder] default mod not found!")
    end
end)

-- Register the NPC entity
minetest.register_entity("auto_we_builder:npc_builder", {
    hp_max = 1,
    physical = true,
    collide_with_objects = true,
    collisionbox = {-0.3, 0.0, -0.3, 0.3, 1.75, 0.3},
    selectionbox = {-0.3, 0.0, -0.3, 0.3, 1.75, 0.3},
    visual = "mesh",
    mesh = "auto_we_builder.b3d",
    textures = {"auto_we_builder_char.png"},
    makes_footstep_sound = true,
    automatic_rotate = false,
    stepheight = 0.6,
    
    -- Animation definitions
    animations = {
        stand = {range = {1, 20}, speed = 15, loop = true},
        walk = {range = {21, 40}, speed = 30, loop = true},
        build = {range = {41, 60}, speed = 20, loop = true},
    },
    
    -- Custom fields
    _last_anim = "stand",
    _target_pos = nil,
    _building = false,
    _current_schema = nil,
    _build_queue = {},
    _build_layer = 0,
    _player_follow = nil,
    _follow_distance = 3,
    
    on_activate = function(self, staticdata)
        self.object:set_armor_groups({immortal = 1})
        self.object:setpos(self.object:getpos())
        
        -- Set initial animation
        self:_set_animation("stand")
        
        -- Restore state from staticdata if available
        if staticdata and staticdata ~= "" then
            local data = minetest.deserialize(staticdata)
            if data then
                self._current_schema = data.current_schema
                self._build_layer = data.build_layer or 0
                self._building = data.building or false
            end
        end
    end,
    
    on_deactivate = function(self, removal)
        -- Save state before removal
        if not removal then
            local data = {
                current_schema = self._current_schema,
                build_layer = self._build_layer,
                building = self._building,
            }
            return minetest.serialize(data)
        end
    end,
    
    on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
        -- Don't take damage
        return false
    end,
    
    on_rightclick = function(self, clicker)
        -- Only players can interact
        if not clicker:is_player() then
            return
        end
        
        -- Open the building selection formspec
        auto_we_builder.show_building_menu(clicker, self)
    end,
    
    -- Helper function to set animation
    _set_animation = function(self, anim_name)
        if not self.object then
            return
        end
        local anim = self.animations[anim_name]
        if not anim or not anim.range then
            minetest.log("warning", "[Auto WE Builder] Animation not found or invalid: " .. tostring(anim_name))
            return
        end
        -- Ensure range values are numbers
        if type(anim.range) ~= "table" or #anim.range < 2 then
            minetest.log("warning", "[Auto WE Builder] Invalid animation range for: " .. tostring(anim_name))
            return
        end
        local start_frame = tonumber(anim.range[1])
        local end_frame = tonumber(anim.range[2])
        if not start_frame or not end_frame then
            minetest.log("warning", "[Auto WE Builder] Invalid animation frame numbers for: " .. tostring(anim_name))
            return
        end
        if self._last_anim ~= anim_name then
            self.object:set_animation(
                {x = start_frame, y = end_frame},
                anim.speed,
                0,
                anim.loop
            )
            self._last_anim = anim_name
        end
    end,
    
    -- Follow player logic
    _follow_player = function(self, player, dtime)
        if not self.object or not player or not player:is_player() then
            return
        end
        
        -- CRITICAL FIX: Always sync self.pos with actual object position first
        local current_obj_pos = self.object:getpos()
        if not current_obj_pos then
            return -- Object removed
        end
        self.pos = current_obj_pos -- Update internal pos to prevent nil errors
        
        local player_pos = player:getpos()
        if not player_pos then
            return
        end
        
        local player_look = player:get_look_horizontal()
        
        -- Calculate position behind player
        local offset_x = math.sin(player_look) * self._follow_distance
        local offset_z = -math.cos(player_look) * self._follow_distance
        
        local target_x = player_pos.x + offset_x
        local target_z = player_pos.z + offset_z
        
        -- Find ground at target position using raycast
        local start_pos = vector.new(target_x, player_pos.y + 5, target_z)
        local end_pos = vector.new(target_x, player_pos.y - 10, target_z)
        local hit = minetest.raycast(start_pos, end_pos, false, true)
        local pointed = hit:next()
        
        local target_y
        if pointed and pointed.type == "node" then
            target_y = math.floor(pointed.pos.y) + 1
        else
            -- Fallback: search manually
            target_y = player_pos.y
            for y = math.floor(player_pos.y), math.floor(player_pos.y) - 10, -1 do
                local check_pos = vector.new(target_x, y, target_z)
                local node = minetest.get_node_or_nil(check_pos)
                if node and minetest.registered_nodes[node.name] and minetest.registered_nodes[node.name].walkable then
                    target_y = y + 1
                    break
                end
            end
        end
        
        local target_pos = vector.new(target_x, target_y, target_z)
        self._target_pos = target_pos
        
        -- Move towards target
        local current_pos = self.object:getpos()
        if not current_pos then
            return
        end
        
        local dist = vector.distance(current_pos, target_pos)
        
        if dist > 0.5 then
            -- Calculate movement direction
            local dir = vector.normalize(vector.subtract(target_pos, current_pos))
            
            -- Apply gravity and movement
            local velocity = self.object:get_velocity()
            local move_speed = 2
            
            -- Set horizontal movement only
            local new_velocity = vector.new(dir.x * move_speed, 0, dir.z * move_speed)
            
            -- Check if on ground
            local below_pos = vector.new(current_pos.x, current_pos.y - 0.9, current_pos.z)
            local node_below = minetest.get_node_or_nil(below_pos)
            local on_ground = node_below and minetest.registered_nodes[node_below.name] and minetest.registered_nodes[node_below.name].walkable
            
            if not on_ground then
                -- Apply gravity
                new_velocity.y = velocity.y - 9.8 * dtime
            end
            
            self.object:set_velocity(new_velocity)
            
            -- Rotate to face movement direction
            local yaw = math.atan2(dir.x, dir.z)
            self.object:set_yaw(yaw)
            
            -- Set walking animation
            self:_set_animation("walk")
        else
            -- Stop moving
            self.object:set_velocity(vector.new(0, 0, 0))
            
            -- Face the same direction as player
            local player_yaw = player:get_look_horizontal()
            self.object:set_yaw(player_yaw + math.pi)
            
            -- Ensure NPC is on ground when stopped
            local pos = self.object:getpos()
            if pos then
                local ground_check = vector.new(pos.x, pos.y - 0.9, pos.z)
                local node = minetest.get_node_or_nil(ground_check)
                local on_ground = node and minetest.registered_nodes[node.name] and minetest.registered_nodes[node.name].walkable
                
                if not on_ground then
                    -- Find ground
                    for y = math.floor(pos.y), math.floor(pos.y) - 10, -1 do
                        local check_pos = vector.new(pos.x, y, pos.z)
                        local n = minetest.get_node_or_nil(check_pos)
                        if n and minetest.registered_nodes[n.name] and minetest.registered_nodes[n.name].walkable then
                            pos.y = y + 1
                            self.object:setpos(pos)
                            break
                        end
                    end
                end
            end
            
            -- Set standing animation if not building
            if not self._building then
                self:_set_animation("stand")
            end
        end
    end,
    
    -- Building logic
    _build_next_block = function(self)
        if not self.object then
            return
        end
        
        if not self._building or #self._build_queue == 0 then
            self._building = false
            self:_set_animation("stand")
            return
        end
        
        -- Get next block to place
        local block = table.remove(self._build_queue, 1)
        
        if not block then
            self._building = false
            self:_set_animation("stand")
            return
        end
        
        -- Check if we need to move up a layer
        if block.y > self._build_layer then
            -- Move NPC up to the new layer
            local pos = self.object:getpos()
            if pos then
                pos.y = block.y - 1  -- Stand one block below the building layer
                self.object:setpos(pos)
            end
            self._build_layer = block.y
        end
        
        -- Set building animation
        self:_set_animation("build")
        
        -- Place the block
        local current_pos = self.object:getpos()
        if not current_pos then
            return
        end
        
        local build_pos = vector.new(
            math.floor(current_pos.x + 0.5) + block.x,
            block.y,
            math.floor(current_pos.z + 0.5) + block.z
        )
        
        -- Check if the position is valid
        local node = minetest.get_node_or_nil(build_pos)
        if node and node.name ~= "air" then
            -- Position occupied, skip this block
            minetest.after(0.5, function()
                self:_build_next_block()
            end)
            return
        end
        
        -- Place the block
        local node_def = minetest.registered_nodes[block.name]
        if node_def then
            minetest.set_node(build_pos, {
                name = block.name,
                param1 = block.param1 or 0,
                param2 = block.param2 or 0,
            })
            
            -- Handle metadata (for chests, signs, etc.)
            if block.meta then
                local meta = minetest.get_meta(build_pos)
                if block.meta.fields then
                    for key, value in pairs(block.meta.fields) do
                        meta:set_string(key, value)
                    end
                end
                if block.meta.inventory then
                    -- Handle inventory (simplified)
                end
            end
            
            -- Sound effect for placing block
            minetest.sound_play("dig_crack", {pos = build_pos, gain = 0.5})
        end
        
        -- Schedule next block placement
        minetest.after(0.3, function()
            self:_build_next_block()
        end)
    end,
    
    on_step = function(self, dtime)
        if not self.object then
            return
        end
        
        -- Find player to follow
        local player = self._player_follow
        if not player or not player:is_player() then
            -- Find nearest player
            local pos = self.object:getpos()
            if pos then
                local objects = minetest.get_objects_in_area(vector.offset(pos, -20, -10, -20), vector.offset(pos, 20, 10, 20))
                for _, obj in ipairs(objects) do
                    if obj:is_player() then
                        player = obj
                        self._player_follow = player
                        break
                    end
                end
            end
        end
        
        -- Follow player if one exists
        if player and player:is_player() then
            self:_follow_player(player, dtime)
        end
        
        -- Continue building if active
        if self._building then
            self:_build_next_block()
        end
    end,
})

-- Function to show building selection menu
function auto_we_builder.show_building_menu(player, npc_entity)
    local schema_files = {}
    
    -- Look for .we files in multiple locations
    local search_paths = {
        minetest.get_modpath("auto_we_builder") .. "/schema",
        minetest.get_worldpath() .. "/schematics",
        minetest.get_worldpath() .. "/schema",
    }
    
    -- Add schematics mod path if it exists
    if minetest.get_modpath("schematics") then
        table.insert(search_paths, minetest.get_modpath("schematics") .. "/schematics")
    end
    
    for _, path in ipairs(search_paths) do
        if path then
            -- Use pcall to safely call list_dir
            local success, files = pcall(minetest.list_dir, path)
            if success and files and type(files) == "table" then
                minetest.log("action", "[Auto WE Builder] Found path: " .. path .. " with " .. #files .. " files")
                for _, file in ipairs(files) do
                    if type(file) == "string" and file:match("%.we$") then
                        -- Avoid duplicates
                        local already_added = false
                        for _, existing in ipairs(schema_files) do
                            if existing == file then
                                already_added = true
                                break
                            end
                        end
                        if not already_added then
                            table.insert(schema_files, file)
                            minetest.log("action", "[Auto WE Builder] Added schema: " .. file)
                        end
                    end
                end
            else
                minetest.log("warning", "[Auto WE Builder] Could not read path: " .. tostring(path) .. " - Success: " .. tostring(success))
            end
        end
    end
    
    -- Build formspec
    local formspec = "size[8,6]" ..
        "label[2,0;Select Building]" ..
        "button_exit[1,1;6,0.5;cancel;Cancel]"
    
    if #schema_files == 0 then
        formspec = formspec .. "label[1,2;No .we files found!]"
        formspec = formspec .. "label[1,3;Place files in world/schematics or mod/schema folder]"
        -- List available paths for debugging
        local y_debug = 4
        for _, path in ipairs(search_paths) do
            if path then
                formspec = formspec .. "label[1," .. y_debug .. ";Checked: " .. path .. "]"
                y_debug = y_debug + 0.4
            end
        end
    else
        local y_pos = 1.5
        local count = 0
        for _, file in ipairs(schema_files) do
            if count < 8 then  -- Limit visible buttons
                local display_name = file:gsub("%.we$", "")
                -- Truncate long names
                if #display_name > 20 then
                    display_name = display_name:sub(1, 17) .. "..."
                end
                formspec = formspec .. 
                    "button[0," .. y_pos .. ";8,0.6;build_" .. file .. ";" .. display_name .. "]"
                y_pos = y_pos + 0.7
                count = count + 1
            end
        end
        
        if #schema_files > 8 then
            formspec = formspec .. "label[1,5.5;+ " .. (#schema_files - 8) .. " more files in folder]"
        end
    end
    
    -- Store NPC reference for callback
    local npc_ref = npc_entity.object
    
    minetest.show_formspec(player:get_player_name(), "auto_we_builder:select_building", formspec)
    
    -- Store the NPC object for the callback
    auto_we_builder.npcs[player:get_player_name()] = npc_ref
end

-- Handle formspec input
minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "auto_we_builder:select_building" then
        return
    end
    
    local npc_object = auto_we_builder.npcs[player:get_player_name()]
    if not npc_object or not npc_object:get_luaentity() then
        return
    end
    
    local npc = npc_object:get_luaentity()
    
    -- Check which building was selected
    for field, value in pairs(fields) do
        if field:match("^build_") and value then
            local schema_file = field:match("^build_(.+)$")
            if schema_file then
                -- Start building process
                auto_we_builder.start_building(npc, schema_file)
            end
        end
    end
    
    -- Clear stored reference
    auto_we_builder.npcs[player:get_player_name()] = nil
end)

-- Function to parse .we file and start building
function auto_we_builder.start_building(npc, schema_file)
    -- Find the schema file
    local schema_path = nil
    local search_paths = {
        auto_we_builder.schema_path,
        minetest.get_modpath("auto_we_builder") .. "/schema",
    }
    
    for _, path in ipairs(search_paths) do
        if path then
            local full_path = path .. "/" .. schema_file
            local f = io.open(full_path, "r")
            if f then
                schema_path = full_path
                f:close()
                break
            end
        end
    end
    
    if not schema_path then
        minetest.chat_send_player(npc._player_follow and npc._player_follow:get_player_name() or "singleplayer", 
            "Error: Schema file not found: " .. schema_file)
        return
    end
    
    -- Parse the .we file
    local blocks = auto_we_builder.parse_we_file(schema_path)
    
    if not blocks or #blocks == 0 then
        minetest.chat_send_player(npc._player_follow and npc._player_follow:get_player_name() or "singleplayer", 
            "Error: Could not parse schema file")
        return
    end
    
    -- Sort blocks by Y coordinate for layer-by-layer building
    table.sort(blocks, function(a, b)
        return a.y < b.y
    end)
    
    -- Set NPC state
    npc._current_schema = schema_file
    npc._build_queue = blocks
    npc._build_layer = blocks[1].y or 0
    npc._building = true
    
    -- Move NPC to starting position
    local pos = npc.object:getpos()
    pos.y = blocks[1].y
    npc.object:setpos(pos)
    
    minetest.chat_send_player(npc._player_follow and npc._player_follow:get_player_name() or "singleplayer", 
        "Starting to build: " .. schema_file:gsub("%.we$", "") .. " (" .. #blocks .. " blocks)")
end

-- Function to parse .we file format
function auto_we_builder.parse_we_file(filepath)
    local f = io.open(filepath, "r")
    if not f then
        return nil
    end
    
    local content = f:read("*all")
    f:close()
    
    -- Execute the Lua code in the .we file safely
    local func, err = load(content, "schema", "t", {})
    if not func then
        minetest.log("error", "[Auto WE Builder] Failed to load schema: " .. err)
        return nil
    end
    
    local ok, result = pcall(func)
    if not ok then
        minetest.log("error", "[Auto WE Builder] Failed to execute schema: " .. result)
        return nil
    end
    
    -- Convert relative coordinates to absolute offsets
    local blocks = {}
    if type(result) == "table" then
        for _, block in ipairs(result) do
            table.insert(blocks, {
                x = block.x or 0,
                y = block.y or 0,
                z = block.z or 0,
                name = block.name,
                param1 = block.param1,
                param2 = block.param2,
                meta = block.meta,
            })
        end
    end
    
    return blocks
end

-- Register spawn command
minetest.register_chatcommand("spawn_auto_builder", {
    params = "",
    description = "Spawn an Auto WE Builder NPC",
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then
            return false, "Player not found"
        end
        
        local pos = player:getpos()
        -- Position NPC behind player
        local look = player:get_look_horizontal()
        local offset_x = math.sin(look) * 2
        local offset_z = -math.cos(look) * 2
        
        pos.x = pos.x + offset_x
        pos.z = pos.z + offset_z
        
        -- Create the NPC
        local obj = minetest.add_entity(pos, "auto_we_builder:npc_builder")
        if obj then
            obj:set_yaw(look + math.pi)  -- Face opposite direction of player
            minetest.chat_send_player(name, "Auto WE Builder NPC spawned!")
            return true
        else
            minetest.chat_send_player(name, "Failed to spawn NPC")
            return false
        end
    end,
})

-- Register spawn egg item
minetest.register_craftitem("auto_we_builder:spawn_egg", {
    description = "Auto WE Builder Spawn Egg",
    inventory_image = "auto_we_builder_char.png^[resize:32x32",
    stack_max = 16,
    
    on_place = function(itemstack, user, pointed_thing)
        if pointed_thing.type ~= "node" then
            return itemstack
        end
        
        local pos = pointed_thing.above
        pos.y = pos.y + 0.5
        
        local obj = minetest.add_entity(pos, "auto_we_builder:npc_builder")
        if obj then
            obj:set_yaw(user:get_look_horizontal() + math.pi)
            if not minetest.is_creative_enabled(user:get_player_name()) then
                itemstack:take_item()
            end
            minetest.chat_send_player(user:get_player_name(), "Auto WE Builder NPC spawned!")
        end
        
        return itemstack
    end,
})

-- Craft recipe for spawn egg
minetest.register_craft({
    output = "auto_we_builder:spawn_egg 2",
    recipe = {
        {"default:gold_ingot", "default:stick", "default:gold_ingot"},
        {"default:stick", "default:cobble", "default:stick"},
        {"default:gold_ingot", "default:stick", "default:gold_ingot"},
    },
})

minetest.log("action", "[Auto WE Builder] Mod loaded successfully!")
