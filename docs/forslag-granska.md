# Förslag: granska-läget

Prioriterat efter nytta/insats. [x] = gjort.

1. [x] HDR-bilden som standard, etikett "Exponering N av M", H-tangent (e69459b).
2. [x] Hoppa till nästa ogranskade grupp (Tab / U), med wrap-around.
3. [x] Framsteg i headern: "N av M granskade".
4. [x] Förhämta bilder för närliggande grupper (±2) inkl. HDR, så pil upp/ner är omedelbart.
5. [x] J/K som alternativ till pil upp/ner för gruppnavigering.
6. [x] Filter i gruppslistan: alla / ej granskade / flaggade eller avvisade / per adressmapp (J/K, Tab/U följer filtret).
7. [x] Zoom 100 % (Z, dra för att panorera) och lupp vid muspekaren (håll Shift).
8. [x] Jämförelse sida vid sida (X): slutbilden mot vald källexponering (pilar byter exponering), X igen: sammanslagen HDR mot förbättrad. Synkad zoom/panorering saknas.
9. [x] Badge med adressmappen gruppen hamnade i (från calendar_matches). Snabb flytt per grupp saknas medvetet: `correctAddress` flyttar en hel mappning, inte enskilda grupper.
10. [x] Histogram och klippvarning (C): röd = klippta högdagrar, blå = klippta skuggor, beräknat på nedskalad bild i bakgrunden.
11. [x] Stjärnbetyg per grupp (1-5, 0 tar bort; samma siffra igen växlar av) sparas i group_ratings.json i outputmappen och kan filtreras ("★ N+"). Förslag kvar: ta med betyget som xmp:Rating till Lightroom – ingen säker sidecar-skrivväg finns idag, så det är medvetet inte gjort.
12. [x] Ångra senaste beslut (Cmd+Z / Ångra-knapp), upp till 200 steg.
13. [x] Status för omsammanslagning i gruppslistan: spinner "Gör om…" per grupp och röd "Misslyckades" (felmeddelande som tooltip) om omgörningen inte gav någon ny HDR.
14. [ ] Window pull-panel (fas 4 i docs/plan-hdr-fonster.md) – hanteras separat.
