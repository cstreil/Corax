# Rabe app icon

Quelle ist `rabe-icon.svg` — alles selbst gezeichnet, keine fremden Assets.
Daraus entsteht der Master, daraus der Icon-Satz fürs Bundle:

```sh
# SVG -> rabe-icon-1024.png (RGBA, macOS-Komposition: Squircle 824x824,
# Radius 185, außen transparent, mit Schlagschatten und Lichtkante)
node <renderer>.js          # jeder SVG-Renderer geht; beim Anlegen lag er
                            # unter Work/Tasks/2026-11-18-rabe-icon/build.js
pnpm tauri icon design/icon/rabe-icon-1024.png
```

`pnpm tauri icon` schreibt nach `src-tauri/icons/`: `icon.icns`, `32x32.png`,
`128x128.png`, `128x128@2x.png`, `icon.ico`, die Windows-Logos und Android.
Das macOS-Bundle nutzt davon nur `icon.icns` (`CFBundleIconFile`).

Ein Liquid-Glass-`.icon` (Icon Composer) gibt es bewusst nicht: ohne Icon
Composer lässt es sich hier nicht bauen, und Upstreams Paket mit dem alten
Planeten wurde entfernt. `scripts/macos-app-icon.sh` überspringt den
`actool`-Schritt deshalb, solange kein `src-tauri/icons/Icon.icon` existiert.

`varianten/` hält die drei Entwürfe (A Rabenkopf — gewählt, B Rabe mit
Umschlag, C abstrakt) samt `pruefblatt.png` mit 256…16 px auf hellem und
dunklem Grund.
