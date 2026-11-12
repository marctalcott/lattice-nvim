-- LazyVim v16.0.0 (459a4c3b, 2026-06-02) <leader> keys, read from
-- lua/lazyvim/config/keymaps.lua, lua/lazyvim/plugins/*.lua and
-- lua/lazyvim/plugins/lsp/*.lua, for LATTICE_KEYBINDINGS_SPEC §8 items 14-15.
-- Several are which-key groups rather than mappings; mapping them all is a
-- stricter test. Update this list when checking a newer LazyVim.
local M = {}

M.version = "v16.0.0"

M.core = {
  "<leader>-", "<leader>?", "<leader>.", "<leader>`", "<leader><tab>", "<leader><tab>[", "<leader><tab>]", "<leader><tab><tab>",
  "<leader><tab>d", "<leader><tab>f", "<leader><tab>l", "<leader><tab>o", "<leader>|", "<leader>b", "<leader>bb", "<leader>bd",
  "<leader>bD", "<leader>bi", "<leader>bj", "<leader>bl", "<leader>bo", "<leader>bp", "<leader>bP", "<leader>br",
  "<leader>c", "<leader>ca", "<leader>cA", "<leader>cc", "<leader>cC", "<leader>cd", "<leader>cf", "<leader>cF",
  "<leader>cl", "<leader>cm", "<leader>co", "<leader>cr", "<leader>cR", "<leader>cs", "<leader>cS", "<leader>d",
  "<leader>dp", "<leader>dph", "<leader>dpp", "<leader>dps", "<leader>f", "<leader>fn", "<leader>ft", "<leader>fT",
  "<leader>g", "<leader>gb", "<leader>gB", "<leader>gf", "<leader>gg", "<leader>gG", "<leader>gh", "<leader>ghb",
  "<leader>ghB", "<leader>ghd", "<leader>ghD", "<leader>ghp", "<leader>ghr", "<leader>ghR", "<leader>ghs", "<leader>ghS",
  "<leader>ghu", "<leader>gl", "<leader>gL", "<leader>gY", "<leader>K", "<leader>l", "<leader>L", "<leader>n",
  "<leader>q", "<leader>qd", "<leader>ql", "<leader>qq", "<leader>qs", "<leader>qS", "<leader>s", "<leader>S",
  "<leader>sn", "<leader>sna", "<leader>snd", "<leader>snh", "<leader>snl", "<leader>snt", "<leader>sr", "<leader>st",
  "<leader>sT", "<leader>u", "<leader>ua", "<leader>uA", "<leader>ub", "<leader>uc", "<leader>ud", "<leader>uD",
  "<leader>uf", "<leader>uF", "<leader>ug", "<leader>uG", "<leader>uh", "<leader>ui", "<leader>uI", "<leader>ul",
  "<leader>uL", "<leader>un", "<leader>ur", "<leader>us", "<leader>uS", "<leader>uT", "<leader>uw", "<leader>uz",
  "<leader>uZ", "<leader>w", "<leader>wd", "<leader>wm", "<leader>x", "<leader>xl", "<leader>xL", "<leader>xq",
  "<leader>xQ", "<leader>xt", "<leader>xT", "<leader>xx", "<leader>xX",
}

-- lua/lazyvim/plugins/extras/editor/overseer.lua
M.overseer = { "<leader>ow", "<leader>oo", "<leader>ot" }

return M
