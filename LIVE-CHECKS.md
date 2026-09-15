# S3 C2 — Finder cold-start en floating headers

## Voorwaarden

Gebruik de bestaande Finder-lijstweergave uit de review: pid **742**, Name **(809.5,105)**, Size **(1444.5,105)**, Kind **(1550.5,105)**. Pas geen gebruikersvensters aan. Bij gewijzigde layout moeten de actuele coördinaten eerst read-only worden vastgesteld.

## Exacte probe: eerste hit direct herhalen

Start een nieuw serverproces via de onderstaande probe. De **eerste twee toolcalls** raken hetzelfde Name-punt: eerst koud, dan direct nogmaals. Daarna volgen acht afwisselende runs voor Size en Kind. Voer geen AX-warmup in hetzelfde proces uit vóór die eerste Name-call.

```sh
SCRATCH=/private/tmp/claude-501/-Users-a-projects-mac-control-mcp/2765fa91-b43a-4938-a5e3-e71de9627f36/scratchpad
PROBE_MAX=300000 python3 "$SCRATCH/probe.py" .build/debug/mac-control-mcp '[
  ["element_at_point",{"pid":742,"x":809.5,"y":105}],
  ["element_at_point",{"pid":742,"x":809.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1444.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1550.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1444.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1550.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1444.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1550.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1444.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1550.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1444.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1550.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1444.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1550.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1444.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1550.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1444.5,"y":105}],
  ["element_at_point",{"pid":742,"x":1550.5,"y":105}]
]' | tee s3-evidence/round3-header-live.txt
```

De identieke 18 calls staan in [round3-header-calls.json](s3-evidence/round3-header-calls.json). Om het zeldzame cold-start-geval opnieuw te bemonsteren kan de hele opdracht herhaald worden: iedere probe start een nieuw proces. Bewaar elke uitvoer afzonderlijk.

## Acceptatie

- Name: eerste én herhaalde hit zijn de betreffende `AXButton`; controleer dat het gerapporteerde frame het punt bevat met maximaal **1 punt tolerantie**.
- Een afwijkend direct AX-frame mag nooit `hit_test_quality: direct` opleveren. Een gevonden vervanger meldt `geometric`; zonder vervanger blijft de oorspronkelijke hit gemarkeerd als `direct_out_of_frame`. Dat is een eerlijke foutmarkering, geen correcte Name-hit.
- Size en Kind: elk **8/8 AXButton** met juiste titel; geen overlappende inhoudsrij/-cel.
- Header-latencydoel **≤150 ms**; rapporteer p50 en min/max en houd de koude eerste Name-call afzonderlijk zichtbaar.
- `permission_missing`, onbereikbare doelen en gewijzigde layout leveren geen bruikbare precisie- of snelheidsclaim op.

## Gerichte suites

```sh
script -q /dev/null swift test --no-parallel --filter 'GeometricHitTestTests|ElementAtPointTests|Phase9ToolsTests'
```

In de beperkte uitvoeromgeving worden aanvullend `CLANG_MODULE_CACHE_PATH=/private/tmp/s3-clang-cache` en `--disable-sandbox` gebruikt. De volledige desktopsuite wordt niet gestart.
