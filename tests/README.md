# Tests

A headless test harness: it loads the addon's Lua files into a Lua 5.1 runtime
([lupa](https://pypi.org/project/lupa/)) with a mocked WoW API (including
"secret values") and runs `scenario.lua` against them. It checks the logic and
that the UI code runs without errors. It cannot check how anything looks or
that the real client behaves like the mocks.

```bash
pip install lupa
python tests/harness.py        # stock UI
python tests/harness.py eui    # with a mocked EllesmereUI (skin + settings page)
```

Prints `ALL PASSED` (exit 0) or the failing steps with tracebacks (exit 1).

When you add a Lua file, add it to `FILES` in `harness.py`. This folder is not
packaged into releases.
