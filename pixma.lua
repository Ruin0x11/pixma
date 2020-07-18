local multipart = require("thirdparty.multipart_post")
local inspect = require("thirdparty.inspect")
local xml = require("xml")
local ltn12 = require("ltn12")
local http = require("socket.http")
local socket = require("socket")
local ivec = require("src.ivec")

local pixma = {}
local pixma_mt = { __index = pixma }

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

local function build_headers(headers)
   local s = ""
   for k, v in pairs(headers) do
      s = s .. ("%s: %s\r\n"):format(k, v)
   end
   return s
end

local function build_one_request(request, host)
   request.headers = request.headers or {}
   request.headers["Host"] = host
   request.headers["X-CHMP-Version"] = "1.3.0"
   if request.data then
      request.headers["Content-Length"] = request.data:len()
   end
   local headers = build_headers(request.headers)
   return ("%s %s HTTP/1.1\r\n%s\r\n%s")
      :format(request.method, request.path, headers, request.data or "")
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

function pixma:_request(r)
   local host = self.host
   local port = 80

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

      h.c:send(build_one_request(v, host))
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

pixma.request = socket.protect(pixma._request)

function pixma.new(host)
   return setmetatable({ host = host }, pixma_mt)
end

function pixma:get_device_id()
   local r = {
      {
         method = "GET",
         path = "/canon/ij/command1/port1",
         headers = {
            ["X-CHMP-Property"] = "DeviceID(Print)",
         },
      },
   }

   local ok, code, headers, status, text = assert(self:request(r))
   local id = {}
   if code == 200 then
      local parsed = text:sub(3):split(";")
      for i, v in ipairs(parsed) do
         local pair = v:split(":")
         id[pair[1]] = pair[2]
      end
   end
   return id, code
end

function pixma:get_capabilities()
   local capability_xml = ivec.get_capability()

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

   local ok, code, headers, status, text = assert(self:request(r))
   local parsed
   if code == 200 then
      parsed = xml.load(text)
   end
   return parsed, code
end

local function parse_ink(node)
   return {
      model = xml.find(node, "ivec:model")[1],
      color = xml.find(node, "ivec:color")[1],
      icon = xml.find(node, "ivec:icon")[1],
      level = xml.find(node, "ivec:level")[1],
      tca = xml.find(node, "vcn:tca")[1],
      order = xml.find(node, "ivec:order")[1]
   }
end

local function parse_msi(node)
   if not node then
      return nil
   end

   local msi = {}
   for _, v in ipairs(node) do
      msi[#msi+1] = { type = v.type, value = v[1] }
   end
   return msi
end

local function parse_jobinfo(node)
   if not node then
      return nil
   end

   local jobprogress_detail_node = xml.find(node, "ivec:jobprogress_detail")[1]
   local jobprogress_detail = {
      state = xml.find(jobprogress_detail_node , "ivec:state")[1],
      reason = xml.find(jobprogress_detail_node , "ivec:reason")[1]
   }

   return {
      jobprogress = xml.find(node, "ivec:jobprogress")[1],
      jobprogress_detail = jobprogress_detail,
      sheet_status = xml.find(node, "ivec:sheet_status")[1],
      complete_impression = xml.find(node, "ivec:complete_impression")[1],
      inputbin = xml.find(node, "ivec:inputbin")[1],
      inputbin_logical_name = xml.find(node, "ivec:inputbin_logical_name")[1],
      jobname = xml.find(node, "ivec:jobname")[1],
      username = xml.find(node, "ivec:username")[1],
      computername = xml.find(node, "ivec:computername")[1],
      job_description = xml.find(node, "ivec:job_description")[1],
      papersize = xml.find(node, "ivec:papersize")[1],
      papersize_custom_width = xml.find(node, "ivec:papersize_custom_width")[1],
      papersize_custom_height = xml.find(node, "ivec:papersize_custom_height")[1],
      papertype = xml.find(node, "ivec:papertype")[1],
      hostselected_papertype = xml.find(node, "ivec:hostselected_papertype")[1],
      impression_num = xml.find(node, "ivec:impression_num")[1],
   }
end

local function parse_status(text)
   local parsed = xml.load(text)
   local param_set = xml.find(parsed, "ivec:param_set")

   local input_bins = {}
   local i = 1
   while true do
      local bin = ("inputbin_p%d"):format(i)
      local currentpapertype = xml.find(param_set, "ivec:currentpapertype", "physicalinputbin", bin)
      local currentpapersize = xml.find(param_set, "ivec:currentpapersize", "physicalinputbin", bin)
      local current_papersize_width = xml.find(param_set, "ivec:current_papersize_width", "physicalinputbin", bin)
      local current_papersize_height = xml.find(param_set, "ivec:current_papersize_height", "physicalinputbin", bin)
      if not currentpapertype then
         break
      end
      input_bins[bin] = {
         currentpapertype = currentpapertype[1],
         currentpapersize = currentpapersize[1],
         current_papersize_width = current_papersize_width[1],
         current_papersize_height = current_papersize_height[1]
      }
      i = i + 1
   end

   local marker_info = {}
   local marker_info_node = xml.find(param_set, "ivec:marker_info")
   for _, node in ipairs(marker_info_node) do
      marker_info[#marker_info+1] = parse_ink(node)
   end

   return {
      response = xml.find(param_set, "ivec:response")[1],
      response_detail = xml.find(param_set, "ivec:response_detail")[1],
      status = xml.find(param_set, "ivec:status")[1],
      status_detail = xml.find(param_set, "ivec:status_detail")[1],
      current_support_code = xml.find(param_set, "ivec:current_support_code")[1],
      input_bins = input_bins,
      marker_info = marker_info,
      hri = xml.find(param_set, "vcn:hri")[1],
      pdr = xml.find(param_set, "vcn:pdr")[1],
      hrc = xml.find(param_set, "vcn:hrc")[1],
      isu = xml.find(param_set, "vcn:isu")[1],
      msi = parse_msi(xml.find(param_set, "vcn:msi")),
      jobinfo = parse_jobinfo(xml.find(param_set, "vcn:jobinfo"))
   }
end

function pixma:get_status()
   local status_xml = ivec.get_status()

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

   local ok, code, headers, status, text = assert(self:request(r))
   local parsed
   if code == 200 then
      parsed = parse_status(text)
   end
   return parsed, code
end

function pixma:get_status_maintenance()
   local status_xml = ivec.get_status("maintenance")

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

   local ok, code, headers, status, text = assert(self:request(r))
   local parsed
   if code == 200 then
      parsed = xml.load(text)
   end
   return parsed, code
end

local function read_file(file)
   local f = assert(io.open(file, "rb"))
   local content = f:read("*all")
   f:close()
   return content
end

function pixma:start_job(file, format, job_id)
   local file_data = read_file(file)

   local job_id = string.format("%08d", job_id)
   local dat = ""

   dat = dat .. ivec.start_job(job_id)
   dat = dat .. ivec.set_job_configuration(job_id)
   dat = dat .. ivec.set_configuration(job_id)
   dat = dat .. ivec.send_data(job_id, format, file_data:len())
   dat = dat .. file_data
   dat = dat .. ivec.end_job(job_id)

   -- Printers tend to have what is called "raw 9100" printing, where the all
   -- the data needed for printing something is blasted to the printer all at
   -- once over TCP port 9100. The actual data you send varies by manufacturer.
   -- In Canon's case, you send some XML configuration concatted with the image
   -- data. Then, you can use the separate HTTP interface on port 80 to check
   -- the progress of the print job.
   local c = assert(socket.connect(self.host, 9100))

   c:send(dat)
   c:close()
end

return pixma
