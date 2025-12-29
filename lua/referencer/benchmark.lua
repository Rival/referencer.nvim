-- LuaJIT-specific optimizations
local ffi = require("ffi")  -- Only available in LuaJIT

-- Define C structure for better performance
ffi.cdef[[
typedef struct {
    double x, y, z;
} point3d_t;
]]

ffi.cdef[[
typedef struct {
    int x, y;
} point2int_t;
]]

print(type(ffi.new("point2int_t[?]", 1)))

local function luajit_optimization_demo()
    -- Regular Lua table approach
    local function create_points_lua(n)
        local points = {}
        for i = 1, n do
            points[i] = {x = i, y = i * 2, z = i * 3}
        end
        return points
    end

    -- LuaJIT FFI approach (much faster)
    local function create_points_ffi(n)
        local points = ffi.new("point3d_t[?]", n)
        for i = 0, n - 1 do
            points[i].x = i + 1
            points[i].y = (i + 1) * 2
            points[i].z = (i + 1) * 3
        end
        return points
    end

    -- LuaJIT FFI approach (much faster)
    local function create_points_2_ffi(n)
        local points = ffi.new("point2int_t[?]", n)
        for i = 0, n - 1 do
            points[i].x = i + 1
            points[i].y = (i + 1) * 2
        end
        return points
    end

    -- Vector operations - LuaJIT optimizable
    local function vector_operations(points, n)
        local sum = 0
        for i = 1, n do
            local p = points[i]
            sum = sum + p.x * p.x + p.y * p.y + p.z * p.z
        end
        return sum
    end

    local function vector_operations_ffi(points, n)
        local sum = 0
        for i = 0, n - 1 do
            local p = points[i]
            sum = sum + p.x * p.x + p.y * p.y + p.z * p.z
        end
        return sum
    end

    local function vector_operations_2_ffi(points, n)
        local sum = 0
        for i = 0, n - 1 do
            local p = points[i]
            sum = sum + p.x * p.x + p.y * p.y + i
        end
        return sum
    end
    local n = 100000

    -- Benchmark Lua tables
    local start_time = os.clock()
    local lua_points = create_points_lua(n)
    local lua_result = vector_operations(lua_points, n)
    local lua_time = os.clock() - start_time

    -- Benchmark FFI structures (LuaJIT only)
    if ffi then
        start_time = os.clock()
        local ffi_points = create_points_ffi(n)
        local ffi_result = vector_operations_ffi(ffi_points, n)
        local ffi_time = os.clock() - start_time

        start_time = os.clock()
        local ffi_points_2 = create_points_2_ffi(n)
        local ffi_result_2 = vector_operations_2_ffi(ffi_points_2, n)
        local ffi_time_2 = os.clock() - start_time


        print(string.format("Lua tables: %.4f seconds", lua_time))
        print(string.format("FFI structs: %.4f seconds", ffi_time))
        print(string.format("FFI structs 2: %.4f seconds", ffi_time_2))
        print(string.format("FFI is %.2fx faster", lua_time / ffi_time))
    end
end

-- Only run LuaJIT demo if FFI is available
if pcall(require, "ffi") then
    luajit_optimization_demo()
else
    print("FFI not available (not running LuaJIT)")
end

-- Array part vs hash part performance
local function test_array_vs_hash()
    local iterations = 1000000

    -- Array part (sequential integer keys starting from 1)
    local array = {}
    local start_time = os.clock()
    for i = 1, iterations do
        array[i] = i * 2
    end
    local array_time = os.clock() - start_time

    -- Hash part (non-sequential or non-integer keys)
    local hash = {}
    start_time = os.clock()
    for i = 1, iterations do
        hash["key" .. i] = i * 2
    end
    local hash_time = os.clock() - start_time

    print(string.format("\nArray insertion: %.4f seconds", array_time))
    print(string.format("Hash insertion: %.4f seconds", hash_time))
    print(string.format("Array is %.2fx faster", hash_time / array_time))
end

test_array_vs_hash()

;-- Function call overhead
local function compare_function_calls()
    local iterations = 1000000

    -- Regular function calls
    local function add(a, b)
        return a + b
    end

    local start_time = os.clock()
    local result = 0
    for i = 1, iterations do
        result = add(result, i)
    end
    local func_time = os.clock() - start_time

    -- Inlined operations
    start_time = os.clock()
    result = 0
    for i = 1, iterations do
        result = result + i  -- Inlined
    end
    local inline_time = os.clock() - start_time

    print(string.format("\nFunction calls: %.4f seconds", func_time))
    print(string.format("Inlined code: %.4f seconds", inline_time))
    print(string.format("Inline is %.2fx faster", func_time / inline_time))
end

compare_function_calls()

-- Avoiding closures in loops
local function closure_performance()
    local iterations = 100000
    local functions = {}

    -- Inefficient: Creating closures in loop
    local start_time = os.clock()
    for i = 1, iterations do
        functions[i] = function() return i * 2 end
    end
    local closure_time = os.clock() - start_time

    -- Efficient: Reuse function with parameter
    local function multiplier(x)
        return x * 2
    end

    start_time = os.clock()
    local values = {}
    for i = 1, iterations do
        values[i] = multiplier(i)
    end
    local reuse_time = os.clock() - start_time

    print(string.format("\nClosures: %.4f seconds", closure_time))
    print(string.format("Reused function: %.4f seconds", reuse_time))
    print(string.format("Reuse is %.2fx faster", closure_time/reuse_time))
end

closure_performance()


local function indexing_comparison()
    local iterations = 100000
    local data_size = 1000

    -- Setup test data
    local array_data = {}
    local hash_data = {}
    local objects = {}

    for i = 1, data_size do
        array_data[i] = i * 10
        local obj = {int_index = i, value = i * 10}
        objects[i] = obj
        hash_data[obj] = i * 10  -- Using object as key
    end

    -- Test 1: someData[someObject.int_index] - Integer field access
    local sum = 0
    local start_time = os.clock()
    for _ = 1, iterations do
        for i = 1, data_size do
            local obj = objects[i]
            sum = sum + array_data[obj.int_index]  -- Field then array index
        end
    end
    local field_index_time = os.clock() - start_time

    -- Test 2: someData[someObject] - Object as key
    sum = 0
    start_time = os.clock()
    for _ = 1, iterations do
        for i = 1, data_size do
            local obj = objects[i]
            sum = sum + hash_data[obj]  -- Object as hash key
        end
    end
    local object_key_time = os.clock() - start_time

    print(string.format("\nInteger field indexing: %.4f seconds", field_index_time))
    print(string.format("Object as key:          %.4f seconds", object_key_time))
    print(string.format("Field indexing is %.2fx faster", object_key_time / field_index_time))
end

indexing_comparison()


local function test_array_vs_hash()
    local iterations = 1000000

    -- Test 1: Consecutive from 1 (array part)
    local array_table = {}
    local start = os.clock()
    for _ = 1, iterations do
        array_table[1] = "data1"
        array_table[2] = "data2"
        array_table[3] = "data3"
        local sum = array_table[1] .. array_table[2] .. array_table[3]
    end
    local array_time = os.clock() - start

    -- Test 2: Starting from 2 (hash part)
    local hash_table = {}
    start = os.clock()
    for _ = 1, iterations do
        hash_table[2] = "data1"
        hash_table[3] = "data2"
        hash_table[4] = "data3"
        local sum = hash_table[2] .. hash_table[3] .. hash_table[4]
    end
    local hash_time = os.clock() - start

    print(string.format("\nConsecutive from 1: %.4f seconds", array_time))
    print(string.format("Starting from 2:    %.4f seconds", hash_time))
    print(string.format("Difference: %.2fx", hash_time / array_time))
end

test_array_vs_hash()

-- Avoiding closures in loops
local function show_optimization_benefit()
    local SymbolInfo = {MARK_CORE = 1}
    
    -- Create test data
    local symbols = {}
    for i = 1, 1000 do
        local core = {line = i, col = i * 2}
        symbols[i] = {core, {}, {}, {}}
    end
    
    local iterations = 10000
    
    -- Test 1: Repeated nested lookup
    local sum = 0
    local start = os.clock()
    for _ = 1, iterations do
        for i = 1, #symbols do
            sum = sum + symbols[i][SymbolInfo.MARK_CORE].line
        end
    end
    local nested_time = os.clock() - start
    
    -- Test 2: Cached core
    sum = 0
    start = os.clock()
    for _ = 1, iterations do
        for i = 1, #symbols do
            local core = symbols[i][SymbolInfo.MARK_CORE]
            sum = sum + core.line
        end
    end
    local cached_time = os.clock() - start
    
    -- Test 3: Cached index constant
    local MARK_CORE = SymbolInfo.MARK_CORE
    sum = 0
    start = os.clock()
    for _ = 1, iterations do
        for i = 1, #symbols do
            local core = symbols[i][MARK_CORE]
            sum = sum + core.line
        end
    end
    local constant_time = os.clock() - start
    
    print(string.format("\nNested lookup:    %.4f seconds", nested_time))
    print(string.format("Cached core:      %.4f seconds", cached_time))
    print(string.format("Cached constant:  %.4f seconds", constant_time))
    print(string.format("Improvement: %.2fx", nested_time / constant_time))
end

show_optimization_benefit()

-- Loop optimization techniques
local function loop_optimizations()
    local data = {}
    for i = 1, 10000 do
        data[i] = i
    end

    -- Inefficient: Length calculation in loop
    local start_time = os.clock()
    local sum = 0
    for i = 1, #data do  -- #data calculated each iteration
        sum = sum + data[i]
    end
    local slow_time = os.clock() - start_time

    -- Efficient: Cache length
    start_time = os.clock()
    sum = 0
    local n = #data  -- Calculate once
    for i = 1, n do
        sum = sum + data[i]
    end
    local fast_time = os.clock() - start_time

    -- Most efficient: Use ipairs for arrays
    start_time = os.clock()
    sum = 0
    for i, value in ipairs(data) do
        sum = sum + value
    end
    local ipairs_time = os.clock() - start_time

    print(string.format("\nLength in loop: %.6f seconds", slow_time))
    print(string.format("Cached length: %.6f seconds", fast_time))
    print(string.format("Using ipairs: %.6f seconds", ipairs_time))
end

loop_optimizations()

-- String concatenation optimization
local function string_concat_optimization()
    local pieces = {}
    for i = 1, 1000 do
        pieces[i] = "part" .. i
    end

    -- Inefficient: String concatenation in loop
    local start_time = os.clock()
    local result = ""
    for i = 1, #pieces do
        result = result .. pieces[i]  -- Creates new string each time
    end
    local concat_time = os.clock() - start_time

    -- Efficient: table.concat
    start_time = os.clock()
    result = table.concat(pieces)  -- Single operation
    local table_concat_time = os.clock() - start_time

    print(string.format("\nString concat: %.6f seconds", concat_time))
    print(string.format("table.concat: %.6f seconds", table_concat_time))
    print(string.format("table.concat is %.0fx faster",
        concat_time / table_concat_time))
end

string_concat_optimization()

-- Memory usage optimization
local function memory_optimization_demo()
    -- Inefficient: Storing unnecessary data
    local inefficient_data = {}
    for i = 1, 1000 do
        inefficient_data[i] = {
            id = i,
            name = "Item " .. i,
            description = "This is item number " .. i,
            timestamp = os.time(),
            metadata = {
                created_by = "system",
                version = 1.0,
                tags = {"tag1", "tag2", "tag3"}
            }
        }
    end

    -- Efficient: Store only necessary data
    local efficient_data = {}
    for i = 1, 1000 do
        efficient_data[i] = {
            i,  -- id (position 1)
            "Item " .. i,  -- name (position 2)
            os.time()  -- timestamp (position 3)
            -- Store metadata separately if needed
        }
    end

    -- Even more efficient: Use string interning for repeated values
    local cached_strings = {}
    local function intern_string(str)
        if not cached_strings[str] then
            cached_strings[str] = str
        end
        return cached_strings[str]
    end

    local interned_data = {}
    for i = 1, 1000 do
        interned_data[i] = {
            i,
            intern_string("Item " .. (i % 10)),  -- Reuse similar strings
            os.time()
        }
    end

    print("\nMemory optimization examples created")
    print("Inefficient data uses more memory per record")
    print("Interned strings reduce memory for repeated values")
end

memory_optimization_demo()

-- Garbage collection hints
local function gc_optimization()
    print("Before optimization:", collectgarbage("count"), "KB")

    -- Create some temporary data
    local temp_data = {}
    for i = 1, 100000 do
        temp_data[i] = "temporary data " .. i
    end

    print("After creating data:", collectgarbage("count"), "KB")

    -- Clear references
    temp_data = nil

    -- Suggest garbage collection (don't force it frequently)
    collectgarbage("collect")

    print("After cleanup:", collectgarbage("count"), "KB")
end

gc_optimization()






