local xml = require("xml")

local ivec = {}

function ivec.get_status(servicetype)
   return ivec.make("GetStatus", nil, nil, nil, servicetype)
end

function ivec.get_capability()
   return ivec.make("GetCapability")
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

function ivec.make(operation, job_id, params, ns)
   local param_set = { xml = "ivec:param_set", servicetype = "print",
   }

   if job_id then
      param_set[#param_set+1] = { xml = "ivec:jobID", job_id }
   end

   params = params or {}
   for _, elem in ipairs(params) do
      param_set[#param_set+1] = elem
   end

   param_set[1] = param_set[1] or ""

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
      { xml = "ivec:papersize", opts.papersize },
      { xml = "ivec:papertype", opts.papertype },
      { xml = "ivec:borderlessprint", on_off(opts.borderlessprint) },
      { xml = "ivec:printcolormode", opts.printcolormode },
      { xml = "ivec:printcolormode_intent", opts.printcolormode_intent },
      { xml = "ivec:duplexprint", on_off(opts.duplexprint) },
      { xml = "ivec:printquality", opts.printquality },
      { xml = "ivec:inputbin", opts.inputbin },
   }
   return ivec.make("SetConfiguration", job_id, params)
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

return ivec
