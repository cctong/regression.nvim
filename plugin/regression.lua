if vim.g.loaded_regression_nvim then
  return
end
vim.g.loaded_regression_nvim = true

vim.api.nvim_create_user_command("NvimBaseline", function(opts)
  require("regression").baseline({ force = opts.bang })
end, {
  bang = true,
  desc = "Record the current Neovim state as the known-good baseline",
})

vim.api.nvim_create_user_command("NvimRegression", function()
  require("regression").regression()
end, {
  desc = "Compare the current Neovim state with its baseline",
})

vim.api.nvim_create_user_command("NvimBisect", function()
  require("regression").bisect()
end, {
  desc = "Bisect changed lazy.nvim plugins to find a likely regression",
})

