-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- This file is part of RuneReaderVoice.
--
-- Copyright (C) 2026 Michael Sutton
--
-- RuneReaderVoice is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- RuneReaderVoice is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with RuneReaderVoice. If not, see <https://www.gnu.org/licenses/>.

-- QR-safe Base45 for Lua 5.1
-- Alphabet is exactly the QR alphanumeric-safe set (45 chars)
-- 0-9 A-Z space $ % * + - . / :

RuneReaderVoice = RuneReaderVoice or {}

local BASE45_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"
local BASE45_MAP = {}

do
    for i = 1, #BASE45_ALPHABET do
        BASE45_MAP[string.sub(BASE45_ALPHABET, i, i)] = i - 1
    end
end

RuneReaderVoice.base45_encode = function(input)
    if input == nil then
        return nil
    end

    local out = {}
    local len = string.len(input)
    local i = 1

    while i <= len do
        local b1 = string.byte(input, i)
        local b2 = string.byte(input, i + 1)

        if b2 then
            local x = b1 * 256 + b2
            local e = x % 45
            x = math.floor(x / 45)
            local d = x % 45
            local c = math.floor(x / 45)

            out[#out + 1] = string.sub(BASE45_ALPHABET, e + 1, e + 1)
            out[#out + 1] = string.sub(BASE45_ALPHABET, d + 1, d + 1)
            out[#out + 1] = string.sub(BASE45_ALPHABET, c + 1, c + 1)

            i = i + 2
        else
            local x = b1
            local d = x % 45
            local c = math.floor(x / 45)

            out[#out + 1] = string.sub(BASE45_ALPHABET, d + 1, d + 1)
            out[#out + 1] = string.sub(BASE45_ALPHABET, c + 1, c + 1)

            i = i + 1
        end
    end

    return table.concat(out)

end

local function base45_decode(input)
    if input == nil then
        return nil
    end

    local out = {}
    local len = string.len(input)
    local i = 1

    while i <= len do
        local c1 = string.sub(input, i, i)
        local c2 = string.sub(input, i + 1, i + 1)
        local c3 = string.sub(input, i + 2, i + 2)

        local v1 = BASE45_MAP[c1]
        local v2 = BASE45_MAP[c2]

        if v1 == nil or v2 == nil then
            return nil, "invalid base45 character"
        end

        if c3 ~= nil and c3 ~= "" then
            local v3 = BASE45_MAP[c3]
            if v3 == nil then
                return nil, "invalid base45 character"
            end

            local x = v1 + v2 * 45 + v3 * 45 * 45
            if x > 65535 then
                return nil, "invalid base45 triplet"
            end

            local b1 = math.floor(x / 256)
            local b2 = x % 256

            out[#out + 1] = string.char(b1, b2)
            i = i + 3
        else
            local x = v1 + v2 * 45
            if x > 255 then
                return nil, "invalid base45 pair"
            end

            out[#out + 1] = string.char(x)
            i = i + 2
        end
    end

    return table.concat(out)
end

-- Example:
-- local encoded = base45_encode("Hello world")
-- print(encoded)
-- local decoded = base45_decode(encoded)
-- print(decoded)