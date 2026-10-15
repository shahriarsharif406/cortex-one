"""Entry point used only by scripts/build-exe.ps1 (PyInstaller needs a plain script)."""
from agent.main import main

if __name__ == "__main__":
    raise SystemExit(main())
