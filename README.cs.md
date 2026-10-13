# Adresní řádek pro Finder (macOS)

[English](README.md) · **Čeština**

**Editovatelný adresní řádek pro Finder v macOS**, jaký znáte z Průzkumníka ve Windows. Každé okno Finderu dostane pod panelem nástrojů řádek s celou cestou k aktuální složce. Kliknete do něj, napíšete nebo vložíte cestu, stisknete Enter a okno na ni přejde.

![Okno Finderu s adresním řádkem pod panelem nástrojů](docs/screenshot.png)

> ⭐ **Pokud vám to usnadnilo práci, budeme rádi za hvězdičku.** Jinak se nedozvíme, že to někomu k něčemu je.

## K čemu to je

Finder ukáže, kde jste, ale nedovolí jednoduše napsat, kam chcete. Vestavěné *Přejít do složky* (⇧⌘G) je dialog, který musíte pokaždé otevřít, a řádek cesty dole v okně se nedá upravovat. Kdo přešel z Windows nebo celý den kopíruje cesty z terminálu, chatu a dokumentace, tomu adresní řádek chybí.

## Co umí

- Celá cesta každého okna Finderu je pořád vidět a mění se podle toho, kam přejdete.
- Kliknutí označí celou cestu, napíšete nebo vložíte novou a **Enter** na ni přejde.
- **Tab** doplňuje názvy složek, **Esc** úpravu zruší.
- Rozumí `~`, relativním cestám (`..`, `podslozka`), adresám `file://`, cestám v uvozovkách i cestám zapsaným pro shell (`Moje\ složka`).
- Cesta k souboru otevře jeho složku a soubor označí.
- Každé okno má vlastní řádek, který se s oknem přesouvá a mění velikost.
- Ikona v řádku nabídek nabízí umístění (pod panelem nástrojů, nebo dole místo řádku cesty Finderu), jemný posun, spouštění po přihlášení a ukončení.
- Rozhraní je česky a anglicky.
- Žádná injektáž kódu, ochrana SIP zůstává zapnutá a není potřeba oprávnění Zpřístupnění ani Nahrávání obrazovky. Jediné oprávnění je *Automatizace → Finder*.

## Požadavky

- macOS 13 nebo novější. Vyvíjeno a zkoušeno jen na macOS 26 (Tahoe); na jiných verzích může řádek sedět o pár bodů vedle, viz [Doladění](#doladění).
- Xcode nebo Command Line Tools (`xcode-select --install`) pro sestavení.

## Instalace

```bash
git clone https://github.com/Thominho/finder-address-bar.git
cd finder-address-bar
./build.sh
open FinderPathBar.app
```

Při prvním spuštění se macOS zeptá, jestli smí FinderPathBar ovládat Finder. Povolte to, jinak aplikace nezjistí ani nezmění složku, kterou okno zobrazuje.

### Vyhrazení řádku ve Finderu (jednou)

Ve Finderu zvolte **Zobrazení → Zobrazit řádek panelů**. Finder pak pod panelem nástrojů drží prázdný řádek a adresní řádek leží přesně na něm, takže nic nezakrývá. Finder si volbu pamatuje pro nová okna; v oknech, která už jsou otevřená, je potřeba příkaz zvolit v každém zvlášť.

Bez tohoto kroku řádek funguje taky, jen v zobrazení seznamu leží přes záhlaví sloupců a v ostatních zobrazeních přes horní část první položky.

### Trvalé používání

Přesuňte `FinderPathBar.app` do složky Aplikace a v nabídce u ikony v řádku nabídek zapněte **Spouštět po přihlášení**.

## Jak to funguje

Finder nejde rozšířit o skutečný řádek v panelu nástrojů, takže jde o malou aplikaci na pozadí, která si řádek kreslí sama:

1. Přes AppleScript se Finderu ptá, která okna jsou otevřená a jakou složku zobrazují.
2. Polohu oken čte z window serveru.
3. Přes každé okno Finderu položí panel bez rámečku, zařazený hned nad něj, takže vypadá jako součást okna.
4. Po stisku Enteru řekne Finderu, aby dané okno přepnul na novou složku.

## Doladění

Volby **Posunout o bod výš** a **Posunout o bod níž** v nabídce řádek posunou, pokud nesedí.

Rozměry se dají změnit příkazem `defaults`, například:

```bash
defaults write local.finderpathbar toolbarHeight -float 52
```

| Klíč | Výchozí | Význam |
| --- | --- | --- |
| `toolbarHeight` | 52 | Výška panelu nástrojů Finderu |
| `titlebarHeight` | 28 | Výška záhlaví okna, když je panel nástrojů skrytý |
| `barHeight` | 28 | Výška adresního řádku |
| `tabBarHeight` | 28 | Výška řádku panelů Finderu |
| `sidebarGap` | 8 | Mezera mezi bočním panelem a oblastí se soubory |
| `pathBarHeight` | 30 | Výška řádku cesty Finderu (umístění dole) |
| `statusBarHeight` | 28 | Výška stavového řádku Finderu (umístění dole) |
| `windowCornerRadius` | 26 | Zaoblení rohu okna (umístění dole) |

## Omezení

- Je to překryv, takže se při tažení nebo změně velikosti okna o zlomek vteřiny opožďuje.
- Když má okno víc panelů, řádek se posune pod lištu panelů a zakryje řádek pod ní.
- Tlačítko **+** pro nový panel je pod řádkem schované. ⌘T funguje dál.
- Zkoušeno na macOS 26 s výchozím panelem nástrojů Finderu. Jiné verze a styly panelu můžou potřebovat doladění popsané výše.

## Odinstalace

Ukončete aplikaci přes ikonu v řádku nabídek a smažte ji. Pokud nechcete prázdný řádek, zvolte ve Finderu **Zobrazení → Skrýt řádek panelů**. Nastavení odstraníte takto:

```bash
defaults delete local.finderpathbar
```

## Licence

[MIT](LICENSE)

---

⭐ **Usnadnilo vám to práci? Hvězdička u tohoto repozitáře nás potěší.**
