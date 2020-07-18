# pixma

A Lua library for interfacing with the Canon PIXMA TS8300 series printers. It lets you do things like submit new print jobs and get the status of ink levels.

Tested with a Canon PIXMA TS8320.

## Requirements

- luasocket
- lubyk/xml

## Usage

```lua
local pixma = require("pixma")
local socket = require("socket")

local PRINTER_IP = "192.168.1.141"

local printer = pixma.new(PRINTER_IP)

local id = printer:get_device_id()
local capabilities = printer:get_capabilities()
local status = printer:get_status()

printer:start_job("test.jpg", "JPEGPAGE", 2)

repeat
   socket.sleep(1)
   status = printer:get_status()
   print("Status: " .. status.status)
until status.status == "idle"
```
