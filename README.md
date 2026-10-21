# Finder Address Bar for macOS

**English** · [Čeština](README.cs.md)

A Windows Explorer–style **editable address bar for the macOS Finder**. Every Finder window gets a row under the toolbar that shows the full path of the current folder. Click it, type or paste a path, press Enter, and the window goes there.

![Finder window with the address bar under the toolbar](docs/screenshot.png)

> ⭐ **If this saves you some clicking, please give the repo a star.** It is the only way we find out that it is useful to someone.

## Why

Finder shows you where you are, but it does not let you simply type where you want to go. The built-in *Go to Folder* (⇧⌘G) is a dialog you have to open every time, and the path bar at the bottom of the window is read-only. If you come from Windows, or you copy paths from a terminal, a chat or documentation all day, you miss the address bar.

## Features

- The full path of every Finder window, always visible, updated as you navigate.
- Click the bar to select the whole path, type or paste a new one, press **Enter** to go.
- **Tab** completes folder names, **Esc** cancels.
- Understands `~`, relative paths (`..`, `subfolder`), `file://` URLs, quoted paths and paths escaped for the shell (`My\ Folder`).
- A path to a file opens its folder and selects the file.
- One bar per window. It follows the window when you move or resize it.
- Menu bar icon with placement (below the toolbar, or at the bottom over Finder's path bar), fine position adjustment, launch at login and quit.
- English and Czech interface.
- No code injection, System Integrity Protection stays on, and no Accessibility or Screen Recording permission is needed. The only permission is *Automation → Finder*.

## Requirements

- macOS 13 or later, Apple silicon or Intel. It was developed and tested on macOS 26 (Tahoe) only; on other versions the bar may sit a few points off, see [Tuning](#tuning).

## Install

### The easy way: one command

Open **Terminal** (press ⌘Space, type `Terminal`, press Enter), paste this line and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/Thominho/finder-address-bar/main/install.sh | bash
```

It downloads the app, puts it into your Applications folder and starts it. Nothing has to be built and Xcode is not needed.

### Download

1. Download **[FinderPathBar.zip](https://github.com/Thominho/finder-address-bar/releases/latest/download/FinderPathBar.zip)** and double-click it to unpack.
2. Drag `FinderPathBar` into the Applications folder and open it.
3. macOS refuses to open it the first time, because the app is not notarized by Apple (that needs a paid developer account). Open **System Settings → Privacy & Security**, scroll down to the message about FinderPathBar and click **Open Anyway**. This is needed only once.

The one-command install above does not run into this.

### Build from source

Needs Xcode or the Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Thominho/finder-address-bar.git
cd finder-address-bar
./build.sh
open FinderPathBar.app
```

### First launch

1. The app offers two settings, both ticked. Keep them and click **Continue**:
   - **Reserve a row in Finder**: Finder then keeps an empty row under the toolbar (its tab bar) and the address bar sits exactly on it, so it covers nothing. New Finder windows get the row automatically; in windows that are already open choose **View → Show Tab Bar** once.
   - **Start at login**: otherwise the bar disappears after a restart until you open the app again.
2. macOS asks whether FinderPathBar may **control Finder**. Allow it, otherwise the app cannot read or change the folder a window shows.
3. A folder icon appears in the menu bar. Everything else is in its menu.

Without the reserved row the bar still works, but it lies over the column headers in list view, or over the top of the first item in the other views.

## How it works

Finder cannot be extended with a real toolbar row, so this is a small background app that draws the bar itself:

1. It asks Finder over AppleScript which windows are open and which folder each one shows.
2. It reads the window positions from the window server.
3. It places a borderless panel over each Finder window, ordered directly above it, so the panel looks like part of the window.
4. When you press Enter it tells Finder to point that window at the new folder.

## Tuning

**Move Up 1 pt** and **Move Down 1 pt** in the menu shift the bar if it does not line up.

The layout numbers can be changed with `defaults`, for example:

```bash
defaults write local.finderpathbar toolbarHeight -float 52
```

| Key | Default | Meaning |
| --- | --- | --- |
| `toolbarHeight` | 52 | Height of the Finder toolbar |
| `titlebarHeight` | 28 | Height of the title bar when the toolbar is hidden |
| `barHeight` | 28 | Height of the address bar |
| `sidebarGap` | 8 | Gap between the sidebar and the file area |
| `pathBarHeight` | 30 | Height of Finder's path bar (bottom placement) |
| `statusBarHeight` | 28 | Height of Finder's status bar (bottom placement) |
| `windowCornerRadius` | 26 | Corner radius of the window (bottom placement) |

If something misbehaves, `defaults write local.finderpathbar debug -bool true` makes the app log what it does (see Console.app).

## Troubleshooting

- **The bar is gone after a restart.** The app is not running. Open FinderPathBar from Applications and turn on **Launch at Login** in its menu bar icon.
- **The bar is there but shows no path.** FinderPathBar is not allowed to control Finder. Allow it in **System Settings → Privacy & Security → Automation**.

## Limitations

- It is an overlay, so it trails a fraction of a second behind while you drag or resize a window.
- With more than one tab in a window, Finder's tab strip takes the reserved row. In that window the bar moves to the bottom, over Finder's path bar.
- The **+** button for a new tab is hidden under the bar. ⌘T still works.
- Tested on macOS 26 with the default Finder toolbar. Other versions and toolbar styles may need the tuning above.

## Uninstall

Quit from the menu bar icon and delete the app. In Finder choose **View → Hide Tab Bar** if you do not want the empty row. To remove the settings:

```bash
defaults delete local.finderpathbar
```

## License

[MIT](LICENSE)

---

⭐ **Did it make your work easier? A star on this repository would make us happy.**
