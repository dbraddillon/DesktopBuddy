# DesktopBuddy — CLAUDE.md

Fork of `anthropics/claude-desktop-buddy`. M5StickC Plus firmware that connects
to Claude Code Desktop via BLE and shows the active Claude session state (busy,
attention, approve/deny prompt, etc.) as animated characters.

## Build

```
# Build only
C:\Users\local-admin\.platformio\penv\Scripts\pio.exe run -e m5stickc-plus

# Build + flash
C:\Users\local-admin\.platformio\penv\Scripts\pio.exe run -e m5stickc-plus -t upload

# Upload filesystem (GIF assets)
C:\Users\local-admin\.platformio\penv\Scripts\pio.exe run -e m5stickc-plus -t uploadfs
```

Serial monitor: 115200 baud. BLE device name: `Claude-XXXX` (last 2 MAC bytes).

## Key Libraries

| Library | Version | Notes |
|---------|---------|-------|
| M5Unified | 0.2.14 | Replaces old M5StickCPlus; use this, not M5Stack/M5StickCPlus |
| M5GFX | 0.2.20 | Pulled in by M5Unified; replaces TFT_eSPI |
| AnimatedGIF | 2.1.1 | GIF playback from LittleFS |
| ArduinoJson | 7.x | JSON parsing |
| platform | espressif32@6.8.1 | Pinned — Arduino ESP32 2.0.17 |

## Why M5Unified (not M5StickCPlus)

The old M5StickCPlus library crashes on espressif32@6.8.1:
- `TFT_eSPI` constructor calls GPIO at static init → `RTCWDT_RTC_RESET`
- AXP192 doesn't respond on Arduino `Wire1` → `TG1WDT_SYS_RESET` in `M5.begin()`

M5Unified uses its own I2C driver (not Wire1) and works correctly.

## Type System Notes

- `M5GFX` and `M5Canvas` are sibling types, both inheriting from `lgfx::LovyanGFX`
- Render target pointers (`_tgt`) must be `lgfx::LovyanGFX*`, not `M5GFX*`
- `M5Canvas*` (sprite) and `M5GFX*` (&M5.Display) are both assignable to it

## BLE Pairing

- IO capability: `ESP_IO_CAP_IO` (DisplayYesNo) → Numeric Comparison with Windows
- Windows shows a 6-digit code + Yes/No button — user clicks Yes, no typing needed
- Device auto-confirms via `onConfirmPIN` returning `true`
- Clear stale bonds: `{"cmd":"unpair"}` over serial, then power-cycle

## Source Layout

```
src/
  main.cpp          — main loop, UI, state machine
  ble_bridge.cpp/h  — BLE UART service, security, ring buffer
  character.cpp/h   — GIF character renderer (LittleFS)
  buddy.cpp/h       — ASCII species renderer (18 built-in)
  data.h            — JSON parsing, USB/BT line buffers
  xfer.h            — File transfer protocol (char_begin/file/chunk/char_end)
  stats.h           — Approval/denial stats, level system
  buddies/          — 18 species .cpp files
```

## API Commands (JSON over serial or BLE)

| Command | Effect |
|---------|--------|
| `{"cmd":"name","name":"Frogger"}` | Set pet name |
| `{"cmd":"owner","name":"Brad"}` | Set owner name |
| `{"cmd":"unpair"}` | Clear BLE bonds |
| `{"cmd":"status"}` | Dump battery/heap/stats JSON |
| `{"cmd":"species","idx":N}` | Switch ASCII species (0xFF = GIF mode) |
