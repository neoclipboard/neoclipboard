package.path = package.path .. ";./lua/?.lua"

upper = require("upper").transform

function trim(input)
   return input:gsub("%s+", "")
end

function trim_upper(input)
   return trim(upper(input))
end
