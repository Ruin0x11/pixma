local multipart = require("thirdparty.multipart_post")
local inspect = require("thirdparty.inspect")
local xml = require("xml")
local ltn12 = require("ltn12")
local http = require("socket.http")
local socket = require("socket")

--- Splits a string `str` on separator `sep`.
---
--- @tparam string str
--- @tparam[opt] string sep defaults to "\n"
--- @treturn {string}
function string.split(str,sep)
   sep = sep or "\n"
   local ret={}
   local n=1
   for w in str:gmatch("([^"..sep.."]*)") do
      ret[n] = ret[n] or w
      if w=="" then
         n = n + 1
      end
   end
   return ret
end

function string.lines(s)
   if string.sub(s, -1) ~= "\n" then s = s .. "\n" end
   return string.gmatch(s, "(.-)\n")
end

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

local function url(path)
   return ("http://%s%s"):format(PRINTER_IP, path)
end

local function build_headers(headers)
   local s = ""
   for k, v in pairs(headers) do
      s = s .. ("%s: %s\r\n"):format(k, v)
   end
   return s
end

local function build_one_request(request)
   request.host = request.host or PRINTER_IP
   request.headers = request.headers or {}
   request.headers["Host"] = request.host
   request.headers["X-CHMP-Version"] = "1.3.0"
   if request.data then
      request.headers["Content-Length"] = request.data:len()
   end
   local headers = build_headers(request.headers)
   return ("%s %s HTTP/1.1\r\n%s\r\n%s")
      :format(request.method, request.path, headers, request.data or "")
end

local function build_request(requests)
   local s = ""
   for _, v in ipairs(requests) do
      s = s .. build_one_request(v)
   end
   return s
end

local function shouldredirect(reqt, code, headers)
   return headers.location and
      string.gsub(headers.location, "%s", "") ~= "" and
      (reqt.redirect ~= false) and
      (code == 301 or code == 302 or code == 303 or code == 307) and
      (not reqt.method or reqt.method == "GET" or reqt.method == "HEAD")
      and headers["content-type"]
      and (not reqt.nredirects or reqt.nredirects < 5)
end

local function shouldreceivebody(reqt, code, headers)
   if reqt.method == "HEAD" then return nil end
   if code == 204 or code == 304 then return nil end
   if code >= 100 and code < 200 then return nil end
   if not headers["content-type"] then return nil end
   return 1
end

local function _request(r, host, port)
   host = host or PRINTER_IP
   port = port or 80

   local s = build_request(r)

   local t = {}
   local nreqt = {
      sink = ltn12.sink.table(t)
   }

   local h = http.open(host, port, nil)

   h.c:settimeout(1)
   for i, v in ipairs(r) do
      -- Oh my fuck,
      --
      -- The response depends on the first POST request first calculating the
      -- data to send back to the client, then being returned in the next GET
      -- request. If you send both requests to soon, the second will return 204
      -- (No Content), presumably because the server has not finished computing
      -- things yet.
      --
      -- This is totally unlike how HTTP should be used as a request/response
      -- protocol.
      if i > 1 then
         socket.sleep(0.5)
      end

      h.c:send(build_one_request(v))
   end

   print("=================")
   local code, status, headers
   for i = 1, #r do
      headers = nil
      -- send request line and headers
      code, status = h:receivestatusline()
      print("status", code, status)
      -- if it is an HTTP/0.9 server, simply get the body and we are done
      if not code then
         h:receive09body(status, nreqt.sink, nreqt.step)
         return 1, 200
      end

      -- ignore any 100-continue messages
      while code == 100 do
         headers = h:receiveheaders()
         code, status = h:receivestatusline()
      end
      headers = h:receiveheaders()
      -- at this point we should have a honest reply from the server
      -- we can't redirect if we already used the source, so we report the error
      if shouldredirect(nreqt, code, headers) and not nreqt.source then
         h:close()
         return 1, code, headers, status, table.concat(t)
      end

      -- here we are finally done
      if shouldreceivebody(nreqt, code, headers) then
         h:receivebody(headers, nreqt.sink, nreqt.step)
      end
   end
   h:close()
   return 1, code, headers, status, table.concat(t)
end

local request = socket.protect(_request)

local function get_device_id()
   local r = {
      {
         method = "GET",
         path = "/canon/ij/command1/port1",
         headers = {
            ["X-CHMP-Property"] = "DeviceID(Print)",
         },
      },
   }

   local ok, code, headers, status, text = assert(request(r))
   local id = {}
   if code == 200 then
      local parsed = text:sub(3):split(";")
      for i, v in ipairs(parsed) do
         local pair = v:split(":")
         id[pair[1]] = pair[2]
      end
   end
   return id
end

local function get_capabilities()
   local capability_xml = "<?xml version=\"1.0\" encoding=\"utf-8\" ?><cmd xmlns:ivec=\"http://www.canon.com/ns/cmd/2008/07/common/\"><ivec:contents><ivec:operation>GetCapability</ivec:operation><ivec:param_set servicetype=\"print\"></ivec:param_set></ivec:contents></cmd>"

   local r ={
      {
         method = "POST",
         path = "/canon/ij/command2/port1",
         headers = {
            ["Connection"] = "Keep-Alive",
            ["Content-Type"] = "application/octet-stream",
         },
         data = capability_xml
      },
      {
         method = "GET",
         path = "/canon/ij/command2/port1",
         headers = {
            ["Connection"] = "Keep-Alive",
         },
      },
   }

   local ok, code, headers, status, text = assert(request(r))
   local parsed
   if code == 200 then
      parsed = xml.load(text)
   end
   return parsed
end

local function get_status()
   local status_xml = "<?xml version=\"1.0\" encoding=\"utf-8\" ?><cmd xmlns:ivec=\"http://www.canon.com/ns/cmd/2008/07/common/\"><ivec:contents><ivec:operation>GetStatus</ivec:operation><ivec:param_set servicetype=\"print\"></ivec:param_set></ivec:contents></cmd>"

   local r ={
      {
         method = "POST",
         path = "/canon/ij/command2/port1",
         headers = {
            ["Connection"] = "Keep-Alive",
            ["Content-Type"] = "application/octet-stream",
         },
         data = status_xml
      },
      {
         method = "GET",
         path = "/canon/ij/command2/port1",
         headers = {
            ["Connection"] = "Keep-Alive",
         },
      },
   }

   local ok, code, headers, status, text = assert(request(r))
   local parsed
   if code == 200 then
      print(text)
      parsed = xml.load(text)
   end
   return parsed
end

local function uuid()
  local fn = function(x)
    local r = math.random(16) - 1
    r = (x == "x") and (r + 1) or (r % 4) + 9
    return ("0123456789abcdef"):sub(r, r)
  end
  return (("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", fn))
end

local function cdata(data)
   return ("<![CDATA[%s]]>"):format(data)
end

local ivec = {}

function ivec.make(operation, job_id, params, ns)
   local param_set = { xml = "ivec:param_set", servicetype = "print",
                       { xml = "ivec:jobID", job_id },
   }

   for _, elem in ipairs(params) do
      param_set[#param_set+1] = elem
   end

   local t = { xml = "cmd", ["xmlns:ivec"] = "http://www.canon.com/ns/cmd/2008/07/common/",
      { xml = "ivec:contents",
               { xml = "ivec:operation", operation },
               param_set,
      }
   }

   ns = ns or {}
   for k, v in ipairs(ns) do
      t[k] = v
   end

   local raw = xml.dump(t)

   -- the server doesn't like newlines or whitespace
   local formatted = "<?xml version=\"1.0\" encoding=\"utf-8\" ?>"
   for line in string.lines(raw) do
      formatted = formatted .. line:gsub("^ *", "")
   end

   return formatted
end

function ivec.start_job(job_id)
   local params = {
      { xml = "ivec:bidi", 1 },
      { xml = "vcn:forcepmdetection", "OFF" },
      { xml = "vcn:jobname" },
      { xml = "vcn:username" },
      { xml = "vcn:computername" },
      { xml = "vcn:job_description", cdata(uuid()) },
      { xml = "vcn:host_environment", "android" },
      { xml = "vcn:host_application_id", 2020 },
   }
   local ns = {
      ["xmlns:vcn"] = "http://www.canon.com/ns/cmd/2008/07/canon/"
   }
   return ivec.make("StartJob", job_id, params, ns)
end

function ivec.set_job_configuration(job_id)
   local params = {
      { xml = "ivec:mismatch_mode", "none" },
      { xml = "ivec:datetime", os.date("%Y%m%d%H%M%S") },
   }
   return ivec.make("SetJobConfiguration", job_id, params)
end

local DEFAULT_OPTS = {
   papersize = "na_index-4x6_4x6in",
   papertype = "custom-media-type-canon-15",
   borderlessprint = true,
   printcolormode = "color",
   printcolormode_intent = "correct",
   duplexprint = false,
   printquality = "auto",
   inputbin = "auto"
}

local function merge_default_config(opts)
   opts = opts or {}

   for k, v in pairs(DEFAULT_OPTS) do
      if not opts[k] then
         opts[k] = v
      end
   end

   return opts
end

local function on_off(v) if v then return "ON" else return "OFF" end end

function ivec.set_configuration(job_id, opts)
   opts = merge_default_config(opts)
   local params = {
      { xml = "ivec:mismatch_mode", "none" },
      { xml = "ivec:papersize", opts.papersize },
      { xml = "ivec:papertype", opts.papertype },
      { xml = "ivec:borderlessprint", on_off(opts.borderlessprint) },
      { xml = "ivec:printcolormode", opts.printcolormode },
      { xml = "ivec:printcolormode_intent", opts.printcolormode_intent },
      { xml = "ivec:duplexprint", on_off(opts.duplexprint) },
      { xml = "ivec:printquality", opts.printquality },
      { xml = "ivec:inputbin", opts.inputbin },
   }
   return ivec.make("SetJobConfiguration", job_id, params)
end

function ivec.send_data(job_id, format, datasize)
   local params = {
      { xml = "ivec:format", format },
      { xml = "ivec:datasize", datasize },
   }
   return ivec.make("SendData", job_id, params)
end

function ivec.end_job(job_id)
   return ivec.make("EndJob", job_id, {})
end

local function read_file(file)
   local f = assert(io.open(file, "rb"))
   local content = f:read("*all")
   f:close()
   return content
end

local function start_job(file, job_id)
   local file_data = read_file(file)

   local job_id = string.format("%08d", job_id)
   local dat = ""

   dat = dat .. ivec.start_job(job_id)
   dat = dat .. ivec.set_job_configuration(job_id)
   dat = dat .. ivec.set_configuration(job_id)
   dat = dat .. ivec.send_data(job_id, "JPEGPAGE", file_data:len())
   --dat = dat .. file_data
   dat = dat .. ivec.end_job(job_id)

   -- Printers tend to have what is called "raw 9100" printing, where the all
   -- the data needed for printing something is blasted to the printer all at
   -- once over TCP port 9100. The actual data you send varies by manufacturer.
   -- In Canon's case, you send some XML configuration concatted with the image
   -- data. Then, you can use the separate HTTP interface on port 80 to check
   -- the progress of the print job.
   local c = assert(socket.connect(PRINTER_IP, 9100))

   print("= send")
   c:send(dat)
   print("= recv")
   --print(c:receive("*a"))
   print("= close")
   c:close()
   print(dat)
end

local id = get_device_id()
local caps = get_capabilities()
local status = get_status()

print(start_job("test/android/test.jfif", 2))
--p(status)

