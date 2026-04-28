# yaml-language-highlight

A Neovim plugin that adds syntax highlighting within YAML block-scalars powered by treesitter.

> **Note:** The treesitter parser for any language you want to highlight must already be installed, e.g. via [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter).

## Requirements

- Neovim 0.10+
- Treesitter.

## Installation

**lazy.nvim**

```lua
{
  "surgiie/yaml-language-highlight.nvim",
  config = function()
    require("yaml-language-highlight").setup()
  end,
}
```

## Usage

### Comment annotations

Place a `# lang: <language>` comment on the line immediately before a YAML block scalar key. The plugin will highlight the block scalar's content using that language's treesitter grammar.

```yaml
# lang: xml
schema: |
  <?xml version="1.0" encoding="UTF-8"?>
  <root>
    <item>value</item>
  </root>

# lang: python
script: |
  def hello():
      print("Hello, world!")

# lang: json
config: |
  {
    "key": "value",
    "enabled": true
  }
```

### Treesitter injections

You can also have the plugin generate treesitter injection queries that trigger automatically based on key names — no comment annotation required. Pass an `injections` table to `setup()` mapping language names to a list of key name patterns:

```lua
require("yaml-language-highlight").setup({
  injections = {
    bash   = { "run", "script", "command", "*.sh" },
    python = { "python", "py_script", "*.py" },
    php    = { "php", "php_script", "*.php" },
  },
})
```

Patterns support `*` as a wildcard (e.g. `*.php` matches `schema.php`). Plain strings are matched literally.

