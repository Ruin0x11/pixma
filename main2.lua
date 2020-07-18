local pixma = require("src.pixma")
local inspect = require("thirdparty.inspect")
local socket = require("socket")

local function remove_all_metatables(item, path)
   if path[#path] ~= inspect.METATABLE then return item end
end

local function p(...)
   local t = {...}
   local max = 0

   for k, _ in pairs(t) do
      max = math.max(max, k)
   end

   for i=1,max do
      local v = t[i]
      if v == nil then
         io.write("nil")
      else
         io.write(inspect(v, {process = remove_all_metatables}))
      end
      io.write("\t")
   end
   if #{...} == 0 then
      io.write("nil")
   end
   io.write("\n")
   return ...
end

local PRINTER_IP = "192.168.1.141"

local printer = pixma.new(PRINTER_IP)

local id = printer:get_device_id()
local caps = printer:get_capabilities()
local status = printer:get_status()
p(status)

printer:start_job("test/android/test.jfif", "JPEGPAGE", 2)

repeat
   socket.sleep(1)
   status = printer:get_status()
   p(status)
until status.status == "idle"
