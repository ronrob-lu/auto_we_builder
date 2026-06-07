-- Auto WE Builder Mod - Complete Functional Version
-- Fixes: Schematic parsing, Y-shift building bug, NPC physics, animations, formspec error, and positioning

local modname = "auto_we_builder"
local modpath = minetest.get_modpath(modname)

-- Configuration
local BUILD_DELAY = 0.5 -- Seconds between each block placement
local WALK_SPEED = 2.5

-- Active builder mapping (for formspec callbacks)
local active_builders = {}

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
        -- Strip the version prefix (e.g. "5:")
        local lua_code = string.match(content, "^%d+:(.*)")
        if not lua_code or lua_code == "" then
            minetest.log("error", "[Auto WE Builder] Empty Lua code block after version in: " .. filepath)
            return nil
        end

        -- Try to load as Lua chunk
        local func, err
        if loadstring then
            func, err = loadstring(lua_code)
        else
            func, err = load(lua_code, "we_schema", "t", _G)
        end
        
        if func then
            local success, data = pcall(func)
            if success and type(data) == "table" then
                -- Extract nodes from the data structure
                local node_list = data
                if type(data[1]) == "table" and not data[1].x and not data[1].y and not data[1].name then
                    node_list = data[1]
                end
                if data.nodes then
                    node_list = data.nodes
                end

                if type(node_list) == "table" then
                    for _, entry in ipairs(node_list) do
                        if type(entry) == "table" then
                            local bx = tonumber(entry.x or entry[1])
                            local by = tonumber(entry.y or entry[2])
                            local bz = tonumber(entry.z or entry[3])
                            local name = entry.name or entry[4]
                            if bx and by and bz and name then
                                table.insert(blocks, {
                                    x = bx,
                                    y = by,
                                    z = bz,
                                    name = name,
                                    param1 = entry.param1,
                                    param2 = entry.param2,
                                    meta = entry.meta
                                })
                            end
                        end
                    end
                end
            else
                minetest.log("error", "[Auto WE Builder] Failed to execute Lua schema code: " .. (data or "unknown error"))
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

-- Helper: Rotate param2 for facedir and wallmounted nodes
local function rotate_param2(param2, paramtype2, rot)
    if not param2 or param2 == 0 then return 0 end
    if paramtype2 == "facedir" then
        local dir = param2 % 4
        local axis = math.floor(param2 / 4)
        local new_dir = (dir - rot) % 4
        return axis * 4 + new_dir
    elseif paramtype2 == "wallmounted" then
        if param2 >= 2 and param2 <= 5 then
            local wallmounted_rot = {
                [0] = {2, 3, 4, 5},
                [1] = {4, 5, 3, 2},
                [2] = {3, 2, 5, 4},
                [3] = {5, 4, 2, 3},
            }
            local mapping = wallmounted_rot[rot]
            if mapping then
                if param2 == 2 then return mapping[1] end
                if param2 == 3 then return mapping[2] end
                if param2 == 4 then return mapping[3] end
                if param2 == 5 then return mapping[4] end
            end
        end
    end
    return param2
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
        mesh = "auto_we_builder.b3d",
        textures = {"auto_we_builder_char.png"},
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
    build_substate = nil,
    last_build_time = 0,
    base_pos = nil,
    build_yaw = 0,
    temp_file_list = nil,
    selected_schematic_idx = 1,
    speed_multiplier = 1,
    build_delay = 0.5,
    hp = 5,

    on_activate = function(self, staticdata, dtime_s)
        self.object:set_armor_groups({immortal = 1})
        self.object:set_animation({x=0, y=79}, 15, 0.2, true)
        self.state = "IDLE"
        self.object:set_acceleration({x=0, y=-9.8, z=0}) -- Enable gravity
        self.last_build_time = minetest.get_us_time() / 1000000.0
    end,

    on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir)
        if puncher and puncher:is_player() then
            self.hp = (self.hp or 5) - 1
            local pos = self.object:get_pos()
            if not pos then return end

            if self.hp <= 0 then
                minetest.sound_play("default_death", {pos = pos, gain = 0.5}, true)
                local pname = puncher:get_player_name()
                if active_builders[pname] == self then
                    active_builders[pname] = nil
                end
                self.object:remove()
            else
                -- Play hurt sound
                minetest.sound_play("default_hurt", {pos = pos, gain = 0.5}, true)
                
                -- Spawn red damage particles
                minetest.add_particlespawner({
                    amount = 6,
                    time = 0.1,
                    minpos = {x=pos.x-0.2, y=pos.y+0.5, z=pos.z-0.2},
                    maxpos = {x=pos.x+0.2, y=pos.y+1.5, z=pos.z+0.2},
                    minvel = {x=-1.5, y=1, z=-1.5},
                    maxvel = {x=1.5, y=3, z=1.5},
                    minacc = {x=0, y=-9.8, z=0},
                    maxacc = {x=0, y=-9.8, z=0},
                    minexptime = 0.3,
                    maxexptime = 0.5,
                    minsize = 1,
                    maxsize = 2.5,
                    texture = "default_stone.png^[colorize:#FF0000:180",
                })
            end
        end
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
        end
    end,

    handle_following = function(self, pos, dtime)
        local player = self.owner and minetest.get_player_by_name(self.owner)
        if not player then
            -- Find nearest player
            local players = minetest.get_connected_players()
            local min_dist = 6
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
            self.object:set_animation({x=0, y=79}, 15, 0.2, true)
            return 
        end

        self.owner = player:get_player_name()
        local p_pos = player:get_pos()
        local look_dir = player:get_look_horizontal()
        
        -- Target: 2.5 blocks behind the player
        local target_x = p_pos.x + math.sin(look_dir) * 2.5
        local target_z = p_pos.z - math.cos(look_dir) * 2.5
        local target_y = p_pos.y

        local target_pos = {x=target_x, y=target_y, z=target_z}

        -- Find ground at target
        local ground_pos = self:find_ground(target_pos)
        if ground_pos then
            target_pos.y = ground_pos.y
        end

        local dist = vector.distance(pos, target_pos)

        -- Teleport back if way too far (e.g. player teleported)
        if dist > 15.0 then
            self.object:set_pos({x=p_pos.x, y=p_pos.y + 0.5, z=p_pos.z})
            self.object:set_velocity({x=0, y=0, z=0})
            self.state = "IDLE"
            self.object:set_animation({x=0, y=79}, 15, 0.2, true)
            return
        end

        -- Move towards target
        if dist > 1.5 then
            self.state = "FOLLOWING"
            
            local dir = vector.normalize({x=target_pos.x - pos.x, y=0, z=target_pos.z - pos.z})
            local velocity = self.object:get_velocity() or {x=0, y=0, z=0}
            
            self.object:set_velocity({
                x = dir.x * WALK_SPEED,
                y = velocity.y, -- Keep vertical velocity for gravity
                z = dir.z * WALK_SPEED
            })
            
            self.object:set_yaw(minetest.dir_to_yaw(dir))
            self.object:set_animation({x=168, y=187}, 30, 0.2, true)
        else
            self.state = "IDLE"
            self.object:set_velocity({x=0, y=0, z=0})
            self.object:set_animation({x=0, y=79}, 15, 0.2, true)
            
            -- Snap to ground if idle
            local my_ground = self:find_ground(pos)
            if my_ground and math.abs(pos.y - my_ground.y) > 0.2 then
                self.object:set_pos(my_ground)
            end
        end
    end,

    calculate_block_positions = function(self, block)
        local yaw = self.build_yaw or 0
        local cos_a = math.cos(yaw)
        local sin_a = math.sin(yaw)
        
        -- Rotate the local block coordinates relative to base_pos
        local rx = block.x * cos_a - block.z * sin_a
        local rz = block.x * sin_a + block.z * cos_a
        
        local place_pos = {
            x = math.floor(self.base_pos.x + rx + 0.5),
            y = math.floor(self.base_pos.y + block.y + 0.5),
            z = math.floor(self.base_pos.z + rz + 0.5)
        }
        
        -- The stand_pos is offset from place_pos: 1.5 blocks back along the building's orientation
        local stand_pos = {
            x = place_pos.x + 1.5 * sin_a,
            y = place_pos.y,
            z = place_pos.z - 1.5 * cos_a
        }
        
        -- Find ground/floor at the standing position so the NPC doesn't float!
        local ground_pos = self:find_ground(stand_pos)
        if ground_pos then
            stand_pos.y = ground_pos.y
        end
        
        return place_pos, stand_pos
    end,

    handle_building = function(self, pos, now, dtime)
        local block = self.build_queue[self.current_block_index]
        if not block then
            self:finish_building()
            return
        end

        local place_pos, stand_pos = self:calculate_block_positions(block)

        local speed_mult = self.speed_multiplier or 1
        if self.build_substate == "MOVE_TO_BLOCK" then
            local dist = vector.distance(pos, stand_pos)
            if dist > 0.2 then
                -- Move towards stand_pos
                local dir = vector.direction(pos, stand_pos)
                self.object:set_velocity(vector.multiply(dir, WALK_SPEED * 1.5 * speed_mult))
                self.object:set_yaw(minetest.dir_to_yaw(dir))
                self.object:set_animation({x=168, y=187}, 30 * speed_mult, 0.2, true)
            else
                -- Arrived!
                self.object:set_velocity({x=0, y=0, z=0})
                self.object:set_pos(stand_pos)
                
                -- Look at block
                local look_dir = vector.direction(stand_pos, place_pos)
                self.object:set_yaw(minetest.dir_to_yaw(look_dir))
                
                -- Transition to placing
                self.build_substate = "PLACE_BLOCK"
                self.last_build_time = now
                self.object:set_animation({x=189, y=198}, 30 * speed_mult, 0.2, true)
            end
        elseif self.build_substate == "PLACE_BLOCK" then
            if (now - self.last_build_time) >= (self.build_delay or 0.5) then
                -- Place the block!
                self:place_block(place_pos, block)
                
                -- Move to next block
                self.current_block_index = self.current_block_index + 1
                self.build_substate = "MOVE_TO_BLOCK"
            end
        end
    end,

    place_block = function(self, place_pos, block)
        -- Rotate param2 for facedir/wallmounted nodes to match building orientation
        local rot = math.floor((self.build_yaw + math.pi/4) / (math.pi/2)) % 4
        local node_def = minetest.registered_nodes[block.name]
        local paramtype2 = node_def and node_def.paramtype2
        local new_param2 = rotate_param2(block.param2 or 0, paramtype2, rot)

        -- Place the node with rotated param2
        minetest.set_node(place_pos, {
            name = block.name,
            param1 = block.param1 or 0,
            param2 = new_param2
        })

        -- Restore metadata if it exists
        if block.meta then
            local meta = minetest.get_meta(place_pos)
            if meta then
                meta:from_table(block.meta)
            end
        end

        -- Sound effect (build sound)
        minetest.sound_play("default_place_node", {
            pos = place_pos,
            gain = 0.5,
            max_hear_distance = 15,
        }, true)

        -- Particle effects (using node's texture or a default fallback)
        local node_def = minetest.registered_nodes[block.name]
        local particle_texture = "default_stone.png"
        if node_def and node_def.tiles and type(node_def.tiles) == "table" and type(node_def.tiles[1]) == "string" then
            particle_texture = node_def.tiles[1]
        elseif node_def and type(node_def.tiles) == "string" then
            particle_texture = node_def.tiles
        end

        minetest.add_particlespawner({
            amount = 8,
            time = 0.15,
            minpos = vector.subtract(place_pos, 0.35),
            maxpos = vector.add(place_pos, 0.35),
            minvel = {x=-0.8, y=1.0, z=-0.8},
            maxvel = {x=0.8, y=2.0, z=0.8},
            minacc = {x=0, y=-9.8, z=0},
            maxacc = {x=0, y=-9.8, z=0},
            minexptime = 0.3,
            maxexptime = 0.6,
            minsize = 0.5,
            maxsize = 1.5,
            texture = particle_texture,
        })
    end,

    finish_building = function(self)
        self.state = "IDLE"
        self.build_queue = {}
        self.current_block_index = 0
        self.build_substate = nil
        
        -- Restore physical properties
        self.object:set_properties({
            physical = true,
            collisionbox = {-0.3, 0.0, -0.3, 0.3, 1.75, 0.3}
        })
        self.object:set_acceleration({x=0, y=-9.8, z=0}) -- Restore gravity
        self.object:set_velocity({x=0, y=0, z=0})
        self.object:set_animation({x=0, y=79}, 15, 0.2, true)
        
        if self.owner then
            minetest.chat_send_player(self.owner, "[Auto WE Builder] Finished building successfully!")
        else
            minetest.chat_send_all("[Auto WE Builder] Finished building successfully!")
        end
    end,

    find_ground = function(self, start_pos)
        local base_y = self.base_pos and self.base_pos.y or start_pos.y
        local ray_start = {x=start_pos.x, y=start_pos.y + 2, z=start_pos.z}
        -- Raycast down to the bottom base of the building, or 10 blocks down if following
        local ray_end_y = self.base_pos and (base_y - 3) or (start_pos.y - 10)
        local ray_end = {x=start_pos.x, y=ray_end_y, z=start_pos.z}
        
        local hit = minetest.raycast(ray_start, ray_end, false, false)
        for pointed in hit do
            if pointed.type == "node" then
                local node_name = minetest.get_node(pointed.under).name
                local node_def = minetest.registered_nodes[node_name]
                if node_def and node_def.walkable then
                    return {
                        x = start_pos.x,
                        y = pointed.above.y,
                        z = start_pos.z
                    }
                end
            end
        end
        return start_pos
    end,

    on_rightclick = function(self, clicker)
        if not clicker:is_player() then return end
        local player_name = clicker:get_player_name()
        self.owner = player_name
        active_builders[player_name] = self
        self:show_building_menu(clicker)
    end,

    show_building_menu = function(self, player)
        if self.state == "BUILDING" then
            local formspec = "size[6,3]" ..
                "label[0.5,0.5;The NPC is currently building...]" ..
                "button[0.5,1.5;2.3,1;cancel_build;Cancel Build]" ..
                "button_exit[3.2,1.5;2.3,1;quit;Close]"
            minetest.show_formspec(player:get_player_name(), "auto_we_builder:menu", formspec)
            return
        end

        local schema_path = modpath .. "/schema/"
        local all_files = minetest.get_dir_list(schema_path, false) or {}
        local files = {}
        for _, fname in ipairs(all_files) do
            if fname:sub(-3):lower() == ".we" then
                table.insert(files, fname:sub(1, -4))
            end
        end

        if #files == 0 then
            local formspec = "size[6,3]" ..
                "label[0.5,1;No schematic (.we) files found!]" ..
                "button_exit[2,2;2,1;quit;Close]"
            minetest.show_formspec(player:get_player_name(), "auto_we_builder:menu", formspec)
            return
        end

        self.temp_file_list = files

        local current_sel = self.selected_schematic_idx or 1
        local speed_text = (self.speed_multiplier or 1) .. "x"
        local file_list_str = table.concat(files, ",")
        local formspec = "size[8,7.5]" ..
            "position[0.5,0.5]" ..
            "anchor[0.5,0.5]" ..
            "label[0.5,0.5;Select a schematic to build:]" ..
            "textlist[0.5,1;7,4.5;schematic_list;" .. file_list_str .. ";" .. current_sel .. ";false]" ..
            "label[0.5,5.8;Build Speed (Current: " .. speed_text .. "):]" ..
            "button[2.8,5.5;1.5,0.8;speed_1;1x]" ..
            "button[4.4,5.5;1.5,0.8;speed_2;2x]" ..
            "button[6.0,5.5;1.5,0.8;speed_3;3x]" ..
            "button[0.5,6.6;3,0.8;build;Build Schematic]" ..
            "button_exit[4.5,6.6;3,0.8;quit;Cancel]"
            
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
        self.build_substate = "MOVE_TO_BLOCK"
        
        local pos = self.object:get_pos()
        local ground = self:find_ground(pos)
        local ground_y = ground and ground.y or pos.y
        
        self.base_pos = {
            x = math.floor(pos.x + 0.5),
            y = math.floor(ground_y + 0.5) - 1, -- Flush with ground (under NPC's feet)
            z = math.floor(pos.z + 0.5)
        }
        
        -- Set delay based on selected speed multiplier
        local mult = self.speed_multiplier or 1
        local delay = 0.5
        if mult == 2 then
            delay = 0.25
        elseif mult == 3 then
            delay = 0.1
        end
        self.build_delay = delay
        
        -- Store the yaw angle the NPC is currently facing, snapped to nearest 90 degrees (pi/2 radians)
        local raw_yaw = self.object:get_yaw() or 0
        self.build_yaw = math.floor((raw_yaw + math.pi/4) / (math.pi/2)) * (math.pi/2)
        self.state = "BUILDING"
        
        -- Align the NPC's rotation to the snapped yaw
        self.object:set_yaw(self.build_yaw)
        
        -- Disable physical properties during construction to avoid getting stuck in blocks
        self.object:set_properties({
            physical = false,
            collisionbox = {0,0,0,0,0,0}
        })
        self.object:set_acceleration({x=0, y=0, z=0}) -- Disable gravity during build
        self.object:set_velocity({x=0, y=0, z=0})
        
        minetest.chat_send_player(self.owner, "Starting to build: " .. schema_name .. " (" .. #blocks .. " blocks)")
    end
})

-- Register Spawn Egg
minetest.register_craftitem("auto_we_builder:spawn_egg", {
    description = "Spawn Auto Builder NPC",
    inventory_image = "auto_we_builder_spawn_egg.png",
    on_use = function(itemstack, user, pointed_thing)
        if pointed_thing.type ~= "node" then return itemstack end
        local pos = vector.add(pointed_thing.above, {x=0, y=0.5, z=0})
        local ent = minetest.add_entity(pos, "auto_we_builder:npc_builder")
        if ent then
            local luaent = ent:get_luaentity()
            if luaent and user then
                luaent.owner = user:get_player_name()
            end
        end
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
        pos.y = pos.y + 0.5
        local ent = minetest.add_entity(pos, "auto_we_builder:npc_builder")
        if ent then
            local luaent = ent:get_luaentity()
            if luaent then
                luaent.owner = name
            end
        end
        return true, "NPC spawned!"
    end
})

-- Handle Formspec Input
minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "auto_we_builder:menu" then return end
    
    local player_name = player:get_player_name()
    local entity = active_builders[player_name]
    if not entity then return end

    if fields.quit or fields.cancel then
        return true
    end

    if fields.cancel_build then
        entity:finish_building()
        minetest.close_formspec(player_name, "auto_we_builder:menu")
        return true
    end

    if fields.speed_1 then
        entity.speed_multiplier = 1
        entity:show_building_menu(player)
        return true
    elseif fields.speed_2 then
        entity.speed_multiplier = 2
        entity:show_building_menu(player)
        return true
    elseif fields.speed_3 then
        entity.speed_multiplier = 3
        entity:show_building_menu(player)
        return true
    end

    local selected_idx = nil
    if fields.schematic_list then
        local event = minetest.explode_textlist_event(fields.schematic_list)
        if event.type == "CHG" or event.type == "DCL" then
            selected_idx = event.index
            entity.selected_schematic_idx = selected_idx
        end
    end

    local double_clicked = false
    if fields.schematic_list then
        local event = minetest.explode_textlist_event(fields.schematic_list)
        if event.type == "DCL" then
            double_clicked = true
        end
    end

    if fields.build or double_clicked then
        local idx = entity.selected_schematic_idx or 1
        local files = entity.temp_file_list
        if files and files[idx] then
            local schema_name = files[idx]
            entity:start_building(schema_name)
            minetest.close_formspec(player_name, "auto_we_builder:menu")
        end
        return true
    end
    
    return true
end)

minetest.log("action", "[Auto WE Builder] Mod loaded successfully.")
