# Förslag: granska-läget

Prioriterat efter nytta/insats. [x] = gjort.

1. [x] HDR-bilden som standard, etikett "Exponering N av M", H-tangent (e69459b).
2. [x] Hoppa till nästa ogranskade grupp (Tab / U), med wrap-around.
3. [x] Framsteg i headern: "N av M granskade".
4. [x] Förhämta bilder för närliggande grupper (±2) inkl. HDR, så pil upp/ner är omedelbart.
5. [x] J/K som alternativ till pil upp/ner för gruppnavigering.
6. [x] Filter i gruppslistan: alla / ej granskade / flaggade eller avvisade / per adressmapp (J/K, Tab/U följer filtret).
7. [x] Zoom 100 % (Z, dra för att panorera) och lupp vid muspekaren (håll Shift).
8. [ ] Jämförelse sida vid sida: HDR mot vald källexponering, eller två exponeringar.
9. [x] Badge med adressmappen gruppen hamnade i (från calendar_matches). Snabb flytt per grupp saknas medvetet: `correctAddress` flyttar en hel mappning, inte enskilda grupper.
10. [x] Histogram och klippvarning (C): röd = klippta högdagrar, blå = klippta skuggor, beräknat på nedskalad bild i bakgrunden.
11. [ ] Stjärnmärkning/flagga per grupp (1-5, X) och filter på dem.
12. [x] Ångra senaste beslut (Cmd+Z / Ångra-knapp), upp till 200 steg.
13. [ ] Tydligare status för pågående omsammanslagning i gruppslistan (spinner per grupp, inte bara i stora bilden).
14. [ ] Window pull-panel (fas 4 i docs/plan-hdr-fonster.md) – hanteras separat.
